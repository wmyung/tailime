import AppKit
import ApplicationServices
import Foundation
import TailIMECore

/// Event-driven watcher that tracks the frontmost app, focused window title (via AXObserver),
/// and remote client outgoing Tailscale sockets (via background libproc scan) so the CGEventTap
/// hot path ONLY ever reads a cached `ActiveRemoteContext` snapshot.
final class RemoteSessionWatcher {
    private let bgQueue = DispatchQueue(label: "com.tailime.session-watcher", qos: .userInitiated)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var axObservedPID: pid_t = 0
    private var socketPollTimer: Timer?
    private var refreshGeneration: UInt64 = 0

    private var settingsProvider: () -> AppSettings
    private var snapshotProvider: () -> TailscaleStatusSnapshot
    private(set) var currentContext = ActiveRemoteContext()

    var onContextChanged: ((ActiveRemoteContext) -> Void)?

    init(
        settingsProvider: @escaping () -> AppSettings,
        snapshotProvider: @escaping () -> TailscaleStatusSnapshot
    ) {
        self.settingsProvider = settingsProvider
        self.snapshotProvider = snapshotProvider
    }

    deinit {
        stop()
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let activateObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNow(reattachAX: true)
        }
        workspaceObservers.append(activateObs)

        // Lightweight periodic refresh ONLY when a remote viewer app is frontmost
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.currentContext.isRemoteAppFocused else { return }
            self.refreshNow(reattachAX: false)
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        socketPollTimer = timer

        refreshNow(reattachAX: true)
    }

    func stop() {
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        socketPollTimer?.invalidate()
        socketPollTimer = nil
        detachAXObserver()
    }

    func refreshNow(reattachAX: Bool = false) {
        refreshGeneration &+= 1
        let gen = refreshGeneration

        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier ?? ""
        let pid = front?.processIdentifier ?? 0
        let bundlePath = front?.bundleURL?.path
        let settings = settingsProvider()

        let isRemote = RemoteTargetResolver.isRemoteViewerBundle(
            bundleID,
            allowedPrefixes: settings.allRemoteBundlePrefixes
        )

        if !isRemote {
            detachAXObserver()
            let ctx = ActiveRemoteContext(isRemoteAppFocused: false, bundleID: bundleID, frontmostPID: pid)
            publish(ctx)
            return
        }

        if reattachAX || axObservedPID != pid {
            attachAXObserver(for: pid)
        }

        let snapshot = snapshotProvider()
        bgQueue.async { [weak self] in
            guard let self else { return }
            let windowTitle = Self.readFocusedWindowTitle(pid: pid) ?? ""
            var selfIPs: Set<String> = []
            if let v4 = snapshot.selfNode?.ipv4 { selfIPs.insert(v4) }
            if let v6 = snapshot.selfNode?.ipv6 { selfIPs.insert(v6) }

            let rawSockets = SocketInspector.inspectClientSockets(frontmostPID: pid, bundlePath: bundlePath)
            let clientIPs = SocketInspector.filterClientTailscalePeerIPs(sockets: rawSockets, selfIPs: selfIPs)

            let resolved = RemoteTargetResolver.resolve(
                bundleID: bundleID,
                frontmostPID: pid,
                windowTitle: windowTitle,
                activeClientSocketIPs: clientIPs,
                snapshot: snapshot,
                settings: settings
            )

            DispatchQueue.main.async { [weak self] in
                // Drop stale async scan results if focus/window changed while inspecting sockets!
                guard let self, self.refreshGeneration == gen else { return }
                let liveFront = NSWorkspace.shared.frontmostApplication
                guard liveFront?.processIdentifier == pid else { return }
                self.publish(resolved)
            }
        }
    }

    private func publish(_ next: ActiveRemoteContext) {
        guard next != currentContext else { return }
        currentContext = next
        onContextChanged?(next)
    }

    // MARK: - Accessibility Window Title & Observer

    private func attachAXObserver(for pid: pid_t) {
        detachAXObserver()
        guard pid > 0, AXIsProcessTrusted() else { return }

        var observer: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<RemoteSessionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                watcher.refreshNow(reattachAX: false)
            }
        }, &observer)

        guard status == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXTitleChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXMainWindowChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.axObserver = observer
        self.axObservedPID = pid
    }

    private func detachAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        axObservedPID = 0
    }

    private static func readFocusedWindowTitle(pid: pid_t) -> String? {
        guard pid > 0, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)

        var focusedWin: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWin) == .success,
           let winRef = focusedWin, CFGetTypeID(winRef) == AXUIElementGetTypeID() {
            let win = winRef as! AXUIElement
            AXUIElementSetMessagingTimeout(win, 0.08)
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.isEmpty {
                return title
            }
        }

        // Fallback: CGWindowListCopyWindowInfo frontmost normal layer window of that PID
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                      (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
                if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                    return name
                }
            }
        }
        return nil
    }
}

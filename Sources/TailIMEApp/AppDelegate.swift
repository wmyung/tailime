import AppKit
import ApplicationServices
import Carbon
import CSystemBridge
import Foundation
import ServiceManagement
import TailIMECore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let syntheticMarker = Int64.random(in: 1...Int64.max)
    private let settingsStore = SettingsStore()
    private let hidRemapper = HIDRemapper()
    private let hudController = HUDPanelController()
    private let statusBarController = StatusBarController()

    private lazy var identity: CryptoIdentity = {
        CryptoIdentity.loadOrCreateFromKeychain() ?? CryptoIdentity.generateEphemeral()
    }()
    private lazy var localEngine = LocalSwitchEngine(syntheticMarker: syntheticMarker)
    private lazy var tapController = EventTapController(syntheticMarker: syntheticMarker)
    private lazy var udpEndpoint = TailscaleUDPEndpoint(port: settingsStore.settings.udpPort)
    private lazy var remoteCoordinator = RemoteCoordinator(
        identity: identity,
        settingsStore: settingsStore,
        localEngine: localEngine,
        tapController: tapController,
        udpEndpoint: udpEndpoint
    )
    private lazy var sessionWatcher = RemoteSessionWatcher(
        settingsProvider: { [weak self] in self?.settingsStore.settings ?? AppSettings() },
        snapshotProvider: { [weak self] in self?.remoteCoordinator.currentTailscaleSnapshot ?? TailscaleStatusSnapshot(selfNode: nil, peers: []) }
    )
    private lazy var settingsWindow = SettingsWindowController()
    private var controlServer: LocalControlServer?

    private var paused = false
    private var hidTapActive = false
    private var sessionTapActive = false
    private var boundUDPAddresses: [String] = []
    private var secureInputAppName: String?
    private var karabinerDiscovery = KarabinerDiscoveryResult(profileName: nil, detectedTriggers: [])
    private var activeTriggers: [TriggerSpec] = []
    private var currentLocalHoldGen: UInt64 = 0
    private var currentSessionHoldGen: UInt64 = 0

    private var tailscaleTimer: Timer?
    private var healthTimer: Timer?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another TailIME instance is already serving our CLI port, exit cleanly.
        if CFMessagePortCreateRemote(kCFAllocatorDefault, LocalControlServer.portName as CFString) != nil {
            NSApp.terminate(nil)
            return
        }

        setupSignalHandlers()
        wireEverything()

        settingsStore.startWatchingKarabinerDirectory()
        localEngine.startObservingInputSourceNotifications()
        reloadTriggersAndKarabiner()

        startLocalControlServer()
        udpEndpoint.start()
        sessionWatcher.start()
        refreshTailscaleAsync(probePaired: true)

        if AXIsProcessTrusted() {
            tapController.start()
        }

        setupSystemNotifications()
        startTimers()
        reconcileHIDRemapper()
        refreshAllUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tapController.stop()
        udpEndpoint.stop()
        sessionWatcher.stop()
        controlServer?.stop()
        hidRemapper.restoreAll()
    }

    // MARK: - Wiring

    private func wireEverything() {
        settingsStore.onSettingsChanged = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.udpEndpoint.updatePort(self.settingsStore.settings.udpPort)
                self.reloadTriggersAndKarabiner()
                self.reconcileHIDRemapper()
                self.sessionWatcher.refreshNow(reattachAX: false)
                self.refreshAllUI()
            }
        }

        settingsStore.onTrustedPeersChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.remoteCoordinator.syncKeysToEndpoint()
                self?.refreshAllUI()
            }
        }

        settingsStore.onKarabinerConfigChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.reloadTriggersAndKarabiner()
                self?.refreshAllUI()
            }
        }

        localEngine.onInputSourceChanged = { [weak self] info in
            guard let self else { return }
            self.tapController.updateSnapshot { $0.localIsKorean = (info.language == .korean) }
            if self.currentLocalHoldGen != 0 {
                let gen = self.currentLocalHoldGen
                self.currentLocalHoldGen = 0
                self.tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: gen)
            }
            if self.currentSessionHoldGen != 0 {
                let sgen = self.currentSessionHoldGen
                self.currentSessionHoldGen = 0
                self.tapController.flushSessionHoldGateAsync(reason: .completed, expectedGeneration: sgen)
            }
            self.remoteCoordinator.handleLocalSourceChangedWhileRemoteFocused(info)
            self.remoteCoordinator.broadcastLocalStateChange(info)
            self.refreshAllUI()
        }

        tapController.onTapStatusChanged = { [weak self] hidOK, sessOK in
            guard let self else { return }
            self.hidTapActive = hidOK
            self.sessionTapActive = sessOK
            self.refreshAllUI()
        }

        tapController.onLocalTriggerFired = { [weak self] spec, _, holdGen, fromSessionTap in
            DispatchQueue.main.async {
                self?.handleLocalTrigger(spec: spec, holdGen: holdGen, fromSessionTap: fromSessionTap)
            }
        }

        tapController.onRemoteTriggerFired = { [weak self] spec, isOwned, context, holdGen, injectedCarrier in
            DispatchQueue.main.async {
                self?.remoteCoordinator.handleRemoteTrigger(
                    spec: spec,
                    isOwned: isOwned,
                    context: context,
                    holdGen: holdGen,
                    alreadyInjectedCarrierKeyCode: injectedCarrier
                )
            }
        }

        tapController.onEscapeToEnglish = { [weak self] in
            DispatchQueue.main.async {
                self?.localEngine.switchTo(language: .english, allowHotkeyPulse: true)
            }
        }

        tapController.onRecordedTrigger = { [weak self] spec in
            guard let self else { return }
            self.settingsWindow.updateRecordingState(false)
            self.settingsStore.updateSettings { s in
                if !s.userTriggers.contains(where: { $0.id == spec.id }) {
                    s.userTriggers.append(spec)
                }
            }
        }

        tapController.onDiagnosticEvent = { [weak self] line in
            self?.settingsWindow.appendDiagnosticLine(line)
        }

        sessionWatcher.onContextChanged = { [weak self] context in
            guard let self else { return }
            self.tapController.updateSnapshot { $0.remoteContext = context }
            self.remoteCoordinator.handleRemoteContextChanged(context)
            self.refreshAllUI()
        }

        udpEndpoint.onBindStatusChanged = { [weak self] addrs in
            self?.boundUDPAddresses = addrs
            self?.refreshAllUI()
        }

        remoteCoordinator.onStateUpdated = { [weak self] in
            self?.refreshAllUI()
        }

        remoteCoordinator.onRemoteSwitchedHUD = { [weak self] host, lang, rtt, isFallback in
            self?.hudController.showRemoteSwitch(hostName: host, language: lang, rttMs: rtt, isFallback: isFallback)
        }

        // Menu Bar callbacks
        statusBarController.onToggleLocalLanguage = { [weak self] in
            self?.handleLocalTrigger()
        }
        statusBarController.onTogglePause = { [weak self] in
            guard let self else { return }
            self.paused.toggle()
            self.tapController.updateSnapshot { $0.paused = self.paused }
            self.refreshAllUI()
        }
        statusBarController.onSelectPinnedPeer = { [weak self] peerID in
            self?.settingsStore.updateSettings { $0.pinnedPeerID = peerID }
        }
        statusBarController.onOpenSettings = { [weak self] tab in
            self?.refreshAllUI()
            self?.settingsWindow.show(tab: tab)
        }
        statusBarController.onRequestAccessibility = { [weak self] in
            self?.requestAccessibilityPermission()
        }
        statusBarController.onRefreshTailscale = { [weak self] in
            self?.refreshTailscaleAsync(probePaired: true)
        }
        statusBarController.onQuit = {
            NSApp.terminate(nil)
        }

        // Settings Window callbacks
        settingsWindow.onSettingsMutate = { [weak self] mutate in
            self?.settingsStore.updateSettings(mutate)
        }
        settingsWindow.onToggleLoginItem = { [weak self] enable in
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "로그인 시 자동 실행 설정을 변경하지 못했습니다."
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            self?.refreshAllUI()
        }
        settingsWindow.onRequestAccessibility = { [weak self] in
            self?.requestAccessibilityPermission()
        }
        settingsWindow.onStartRecordingTrigger = { [weak self] in
            self?.tapController.updateSnapshot { $0.isRecordingTrigger = true }
        }
        settingsWindow.onInitiatePairing = { [weak self] ip in
            self?.remoteCoordinator.initiatePairing(withPeerIP: ip)
        }
        settingsWindow.onPingPeer = { [weak self] ip, done in
            self?.remoteCoordinator.pingPeer(ip: ip) { result in
                switch result {
                case .success(let info):
                    done(String(format: "✓ %@ 연결 성공 (RTT %.1fms · 현재 입력기: %@)", info.host, info.rttMs, info.lang.displayName))
                case .failure(let err):
                    done("✗ \(err.localizedDescription)")
                }
            }
        }
        settingsWindow.onCopyMyPairingToken = { [weak self] in
            guard let self else { return nil }
            let ip = self.remoteCoordinator.currentTailscaleSnapshot.selfNode?.ipv4
            return self.identity.exportPairingToken(
                hostName: self.remoteCoordinator.hostDisplayName,
                tailscaleIP: ip,
                port: self.settingsStore.settings.udpPort
            )
        }
        settingsWindow.onImportPairingToken = { [weak self] token in
            guard let self else { return "오류" }
            if let rec = self.remoteCoordinator.importPairingToken(token) {
                return "✓ '\(rec.name)' 등록 완료! 이제 양쪽 Mac이 자동으로 암호화 연결됩니다."
            }
            return "✗ 올바른 TKP1 페어링 토큰이 아니거나 자기 자신의 토큰입니다."
        }
        settingsWindow.onClearTrustedPeers = { [weak self] in
            guard let self else { return }
            for rec in self.settingsStore.trustedPeers {
                self.settingsStore.removeTrustedPeer(deviceID: rec.deviceID)
            }
        }
        settingsWindow.onRefreshTailscale = { [weak self] in
            self?.refreshTailscaleAsync(probePaired: true)
        }
        settingsWindow.onWakeTextInputSwitcher = { [weak self] in
            self?.localEngine.switcherWaker.checkAndWarmAsync(force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.refreshAllUI()
            }
        }
        settingsWindow.onDiagnosticsVisibleChanged = { [weak self] visible in
            self?.tapController.updateSnapshot { $0.diagnosticsMonitorOpen = visible }
        }
    }

    // MARK: - Local Fast Switch

    private func handleLocalTrigger(spec: TriggerSpec? = nil, holdGen: UInt64 = 0, fromSessionTap: Bool = false) {
        let settings = settingsStore.settings
        if holdGen != 0 {
            if fromSessionTap {
                currentSessionHoldGen = holdGen
            } else {
                currentLocalHoldGen = holdGen
            }
        }

        let finishHold: (InputSourceInfo?) -> Void = { [weak self] info in
            guard let self else { return }
            if self.currentLocalHoldGen != 0 {
                let gen = self.currentLocalHoldGen
                self.currentLocalHoldGen = 0
                self.tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: gen)
            }
            if self.currentSessionHoldGen != 0 {
                let sgen = self.currentSessionHoldGen
                self.currentSessionHoldGen = 0
                self.tapController.flushSessionHoldGateAsync(reason: .completed, expectedGeneration: sgen)
            }
            if let info, self.settingsStore.settings.showLocalHUD {
                self.hudController.showLocalSwitch(language: info.language)
            }
        }

        // Preserve macOS's native "previous input source" semantics when 3+ input sources are enabled
        // and the trigger came from macOS's own Symbolic Hotkey 60!
        if spec?.origin == .systemHotkey && localEngine.enabledKeyboardSources().count > 2 {
            localEngine.pulseNativePreviousSource(completion: finishHold)
            return
        }

        let targetLang = localEngine.toggleKoreanEnglish(allowHotkeyPulse: true, completion: finishHold)
        if settings.showLocalHUD {
            hudController.showLocalSwitch(language: targetLang)
        }
    }

    // MARK: - Reload & Health Checks

    private func reloadTriggersAndKarabiner() {
        let settings = settingsStore.settings
        let hotkeys = localEngine.reloadSystemHotkeys()
        karabinerDiscovery = KarabinerConfigParser.loadDefault()

        activeTriggers = TriggerResolver.resolveActiveTriggers(
            settings: settings,
            systemHotkeys: hotkeys,
            karabiner: karabinerDiscovery
        )
        let safeCarrier = TriggerResolver.safeCarrierPair(
            preferred: settings.carrierPair,
            avoidingTriggers: activeTriggers,
            systemHotkeys: hotkeys
        )
        let isKo = (localEngine.currentInputSource()?.language == .korean)

        tapController.updateSnapshot { snap in
            snap.enabled = settings.enabled
            snap.paused = self.paused
            snap.activeTriggers = self.activeTriggers
            snap.carrierPair = safeCarrier
            snap.localIsKorean = isKo
            snap.localHoldGateEnabled = settings.localHoldGateEnabled
            snap.swapBackquoteInKorean = settings.swapBackquoteInKorean
            snap.escapeToEnglish = settings.escapeToEnglish
        }
        remoteCoordinator.syncTapRemoteHintSnapshot()
    }

    private func reconcileHIDRemapper() {
        let s = settingsStore.settings
        _ = hidRemapper.reconcile(
            enabled: s.enabled && !paused && s.optionalHIDRemapEnabled,
            sourceUsage: s.optionalHIDSourceUsage,
            targetKeyCode: s.optionalHIDTargetKeyCode
        )
    }

    private func refreshTailscaleAsync(probePaired: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let snap = TailscaleDiscovery.fetchStatusSync() else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteCoordinator.updateTailscaleSnapshot(snap)
                if probePaired {
                    self.remoteCoordinator.probeAllPairedMacPeers()
                }
                self.sessionWatcher.refreshNow(reattachAX: false)
                self.refreshAllUI()
            }
        }
    }

    private func setupSystemNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.localEngine.switcherWaker.checkAndWarmAsync(force: true)
            self?.refreshTailscaleAsync(probePaired: true)
        }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tapController.flushHoldGateAsync(reason: .systemSleep, discard: false)
            self?.tapController.flushSessionHoldGateAsync(reason: .systemSleep, discard: false)
        }
        nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tapController.flushHoldGateAsync(reason: .systemSleep, discard: false)
            self?.tapController.flushSessionHoldGateAsync(reason: .systemSleep, discard: false)
            self?.udpEndpoint.setConsoleSessionActive(false)
        }
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.udpEndpoint.setConsoleSessionActive(true)
            self?.localEngine.switcherWaker.checkAndWarmAsync(force: true)
        }
    }

    private func startTimers() {
        let tsTimer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshTailscaleAsync(probePaired: false)
        }
        tsTimer.tolerance = 5.0
        RunLoop.main.add(tsTimer, forMode: .common)
        tailscaleTimer = tsTimer

        let hTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.runHealthCheck()
        }
        hTimer.tolerance = 0.5
        RunLoop.main.add(hTimer, forMode: .common)
        healthTimer = hTimer
    }

    private func runHealthCheck() {
        let trusted = AXIsProcessTrusted()
        if trusted && !hidTapActive {
            tapController.start()
        }

        // Console session ownership check
        let onConsole: Bool
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let val = dict[kCGSessionOnConsoleKey as String] as? Bool {
            onConsole = val
        } else {
            onConsole = true
        }
        udpEndpoint.setConsoleSessionActive(onConsole)

        // Secure Input check (per Opus #1: surface clearly + flush HoldGate immediately!)
        let secureOn = IsSecureEventInputEnabled()
        let prevSecure = secureInputAppName
        if secureOn {
            tapController.flushHoldGateAsync(reason: .secureInput, discard: false)
            tapController.flushSessionHoldGateAsync(reason: .secureInput, discard: false)
            let pid = tailime_secure_input_pid()
            if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
                secureInputAppName = app.localizedName ?? "PID \(pid)"
            } else {
                secureInputAppName = "시스템 암호 입력"
            }
        } else {
            secureInputAppName = nil
        }

        if prevSecure != secureInputAppName {
            refreshAllUI()
        }
    }

    private func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setupSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            NSApp.terminate(nil)
        }
        src.resume()
        sigtermSource = src
    }

    // MARK: - Local CLI IPC Server

    private func startLocalControlServer() {
        let server = LocalControlServer { [weak self] req in
            guard let self else { return ["ok": false, "error": "shutting down"] }
            let cmd = (req["cmd"] as? String) ?? ""
            switch cmd {
            case "status":
                let cur = self.localEngine.currentInputSource()
                let ctx = self.sessionWatcher.currentContext
                return [
                    "ok": true,
                    "version": "1.0.0",
                    "enabled": self.settingsStore.settings.enabled,
                    "paused": self.paused,
                    "accessibility": AXIsProcessTrusted(),
                    "hidTap": self.hidTapActive,
                    "sessionTap": self.sessionTapActive,
                    "localSource": cur?.id ?? "",
                    "localLang": cur?.language.rawValue ?? "unknown",
                    "triggers": self.activeTriggers.map(\.label),
                    "boundUDP": self.boundUDPAddresses,
                    "remoteFocused": ctx.hasActiveRemoteSession,
                    "remotePeer": ctx.resolvedPeer?.hostName ?? "",
                    "trustedPeerCount": self.settingsStore.trustedPeers.count,
                ]
            case "toggle":
                self.handleLocalTrigger()
                return ["ok": true]
            case "set":
                guard let langStr = req["lang"] as? String,
                      let lang = InputLanguage(rawValue: langStr) else {
                    return ["ok": false, "error": "lang must be 'ko' or 'en'"]
                }
                self.localEngine.switchTo(language: lang, allowHotkeyPulse: true)
                return ["ok": true, "target": lang.rawValue]
            case "pause":
                self.paused = true
                self.tapController.updateSnapshot { $0.paused = true }
                self.refreshAllUI()
                return ["ok": true, "paused": true]
            case "resume":
                self.paused = false
                self.tapController.updateSnapshot { $0.paused = false }
                self.refreshAllUI()
                return ["ok": true, "paused": false]
            case "peers":
                let list = self.remoteCoordinator.currentTailscaleSnapshot.peers.map { p -> [String: Any] in
                    let ip = p.preferredIP ?? ""
                    let st = self.remoteCoordinator.peerStates[ip]
                    return [
                        "hostName": p.hostName,
                        "os": p.os,
                        "ip": ip,
                        "online": p.online,
                        "direct": p.isDirectPath,
                        "daemonReachable": st?.daemonReachable ?? false,
                        "lang": st?.currentLanguage.rawValue ?? "unknown",
                    ]
                }
                return ["ok": true, "peers": list]
            case "pair-export":
                let ip = self.remoteCoordinator.currentTailscaleSnapshot.selfNode?.ipv4
                if let token = self.identity.exportPairingToken(
                    hostName: self.remoteCoordinator.hostDisplayName,
                    tailscaleIP: ip,
                    port: self.settingsStore.settings.udpPort
                ) {
                    return ["ok": true, "token": token]
                }
                return ["ok": false, "error": "failed to export token"]
            case "pair-import":
                guard let token = req["token"] as? String,
                      let rec = self.remoteCoordinator.importPairingToken(token) else {
                    return ["ok": false, "error": "invalid pairing token"]
                }
                return ["ok": true, "peer": rec.name, "deviceID": rec.deviceID]
            case "remote-set":
                guard let targetIP = req["ip"] as? String,
                      let langStr = req["lang"] as? String,
                      let lang = InputLanguage(rawValue: langStr) else {
                    return ["ok": false, "error": "ip and lang ('ko'|'en') required"]
                }
                guard let rec = self.settingsStore.trustedPeer(matchingIP: targetIP)
                    ?? self.settingsStore.trustedPeers.first(where: { $0.name.caseInsensitiveCompare(targetIP) == .orderedSame }),
                      let liveIP = rec.lastKnownIP ?? (TailscaleIPValidator.isTailscaleIP(targetIP) ? targetIP : nil),
                      let key = self.identity.derivePeerHMACKey(peerPublicKeyBase64: rec.publicKeyBase64) else {
                    return ["ok": false, "error": "peer not paired"]
                }
                let msg = WireMessage(
                    cmd: .set,
                    senderDeviceID: self.identity.deviceID,
                    senderName: self.remoteCoordinator.hostDisplayName,
                    bootSessionID: self.remoteCoordinator.bootSessionID,
                    seq: UInt64(Date().timeIntervalSince1970 * 1000),
                    targetLanguage: lang
                )
                self.udpEndpoint.send(message: msg, toIP: liveIP, key: key)
                return ["ok": true, "peer": rec.name, "ip": liveIP, "target": lang.rawValue]
            case "quit":
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return ["ok": true]
            default:
                return ["ok": false, "error": "unknown command: \(cmd)"]
            }
        }
        server.start()
        controlServer = server
    }

    // MARK: - UI Refresh

    private func refreshAllUI() {
        let settings = settingsStore.settings
        let curSource = localEngine.currentInputSource()
        let remoteCtx = sessionWatcher.currentContext
        let remoteIP = remoteCtx.resolvedPeer?.preferredIP ?? ""
        let remoteState = remoteCoordinator.peerStates[remoteIP]

        let triggersSummary = activeTriggers.isEmpty
            ? "없음"
            : activeTriggers.prefix(4).map(\.label).joined(separator: ", ")

        statusBarController.update(StatusBarPresentation(
            localLanguage: curSource?.language ?? .english,
            localSourceName: curSource?.localizedName ?? "알 수 없음",
            enabled: settings.enabled,
            paused: paused,
            accessibilityGranted: AXIsProcessTrusted(),
            secureInputAppName: secureInputAppName,
            remoteContext: remoteCtx,
            remotePeerState: remoteState,
            tailscalePeers: remoteCoordinator.currentTailscaleSnapshot.peers,
            pinnedPeerID: settings.pinnedPeerID,
            activeTriggersSummary: triggersSummary
        ))

        let hotkeys = localEngine.currentHotkeys
        let hkDesc: String
        if let p = hotkeys.preferredPulseHotkey {
            hkDesc = "\(p.asTriggerSpec.label) (단축키 \(p.id))"
        } else {
            hkDesc = "비활성 (TSM/TIS 직접 전환 폴백)"
        }

        let karDesc: String
        if let prof = karabinerDiscovery.profileName {
            let keys = karabinerDiscovery.detectedTriggers.map(\.label).joined(separator: ", ")
            karDesc = "프로필 '\(prof)' 감지 (\(keys.isEmpty ? "한영 매핑 없음" : keys))"
        } else {
            karDesc = "미설치 또는 설정 없음"
        }

        let carrier = tapController.currentSnapshot().carrierPair
        let carrierDesc = "한=\(VirtualKeyCode.displayName(for: carrier.koreanKeyCode)), 영=\(VirtualKeyCode.displayName(for: carrier.englishKeyCode)), 프로브=\(VirtualKeyCode.displayName(for: carrier.probeKeyCode))"

        let remoteDesc: String
        if remoteCtx.hasActiveRemoteSession {
            remoteDesc = "\(remoteCtx.bundleID) → \(remoteCtx.resolvedPeer?.hostName ?? "미확정") (\(remoteCtx.resolutionSource))"
        } else if remoteCtx.isRemoteAppFocused {
            remoteDesc = "\(remoteCtx.bundleID) (로비 창)"
        } else {
            remoteDesc = "로컬 앱 포커스"
        }

        let diag = DiagnosticsSummary(
            hidTapActive: hidTapActive,
            sessionTapActive: sessionTapActive,
            accessibilityGranted: AXIsProcessTrusted(),
            postEventAccessGranted: CGPreflightPostEventAccess(),
            textInputSwitcherRunning: localEngine.switcherWaker.isRunning,
            secureInputAppName: secureInputAppName,
            boundUDPAddresses: boundUDPAddresses,
            systemHotkeyDescription: hkDesc,
            karabinerSummary: karDesc,
            carrierDescription: carrierDesc,
            activeRemoteDescription: remoteDesc
        )

        settingsWindow.refresh(
            settings: settings,
            activeTriggers: activeTriggers,
            trustedPeers: settingsStore.trustedPeers,
            tailscaleSnapshot: remoteCoordinator.currentTailscaleSnapshot,
            peerStates: remoteCoordinator.peerStates,
            diagnostics: diag
        )
    }
}

import AppKit
import TailIMECore

struct StatusBarPresentation {
    let localLanguage: InputLanguage
    let localSourceName: String
    let enabled: Bool
    let paused: Bool
    let accessibilityGranted: Bool
    let keychainErrorStatus: OSStatus?
    let secureInputAppName: String?
    let conflictingApps: [String]
    let remoteContext: ActiveRemoteContext
    let remotePeerState: RemotePeerRuntimeState?
    let tailscalePeers: [TailscalePeer]
    let pinnedPeerID: String?
    let activeTriggersSummary: String
}

/// Manages the macOS menu bar item (`NSStatusItem`) with crisp language + remote indicator badge.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var latestPresentation: StatusBarPresentation?

    var onToggleLocalLanguage: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onSelectPinnedPeer: ((String?) -> Void)?
    var onOpenSettings: ((Int) -> Void)? // tab index
    var onRequestAccessibility: (() -> Void)?
    var onRetryKeychain: (() -> Void)?
    var onRefreshTailscale: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateButtonTitle("한", remoteActive: false, warning: false, paused: false)
    }

    func update(_ presentation: StatusBarPresentation) {
        latestPresentation = presentation

        let warning = !presentation.accessibilityGranted
            || presentation.keychainErrorStatus != nil
            || presentation.secureInputAppName != nil
            || !presentation.conflictingApps.isEmpty
        let remoteActive = presentation.remoteContext.hasActiveRemoteSession

        let badgeText: String
        if !presentation.enabled || presentation.paused {
            badgeText = "⏸"
        } else if remoteActive {
            if let peerState = presentation.remotePeerState, peerState.daemonReachable {
                badgeText = "⚡\(peerState.currentLanguage.shortBadge)"
            } else {
                badgeText = "↗\(presentation.localLanguage.shortBadge)"
            }
        } else {
            badgeText = presentation.localLanguage.shortBadge
        }

        updateButtonTitle(badgeText, remoteActive: remoteActive, warning: warning, paused: presentation.paused || !presentation.enabled)
    }

    private func updateButtonTitle(_ text: String, remoteActive: Bool, warning: Bool, paused: Bool) {
        guard let button = statusItem.button else { return }
        let suffix = warning ? "!" : ""
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let color: NSColor
        if paused {
            color = .secondaryLabelColor
        } else if warning {
            color = .systemOrange
        } else if remoteActive {
            color = .systemBlue
        } else {
            color = .labelColor
        }
        button.attributedTitle = NSAttributedString(
            string: text + suffix,
            attributes: [.font: font, .foregroundColor: color]
        )
        button.toolTip = "TailIME — 빠릿한 로컬·원격 Tailscale 한영 전환"
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let p = latestPresentation else { return }

        // 1. Accessibility / Keychain / Conflict / Secure Input Warnings
        if !p.accessibilityGranted {
            let item = makeMenuItem(
                title: "손쉬운 사용(접근성) 권한 필요 — 클릭하여 열기",
                symbol: "exclamationmark.triangle.fill",
                action: #selector(handleRequestAccessibility)
            )
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if p.keychainErrorStatus != nil {
            let item = makeMenuItem(
                title: "키체인 기기 키 접근 거부됨 — 클릭하여 다시 읽기",
                symbol: "key.fill",
                action: #selector(handleRetryKeychain)
            )
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if !p.conflictingApps.isEmpty {
            let list = p.conflictingApps.joined(separator: ", ")
            let item = makeMenuItem(
                title: "충돌 가능 앱 실행 중: \(list) (종료 권장)",
                symbol: "exclamationmark.circle.fill",
                action: #selector(handleOpenDiagnostics)
            )
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if let secureApp = p.secureInputAppName {
            let item = makeMenuItem(
                title: "Secure Input 활성 (\(secureApp)) — 암호 입력 중",
                symbol: "lock.fill",
                action: nil
            )
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // 2. Local Status & Quick Toggle
        let localTitle = "로컬 입력기: \(p.localSourceName) (\(p.localLanguage.shortBadge))"
        let localItem = makeMenuItem(title: localTitle, symbol: "globe", action: #selector(handleToggleLocal))
        menu.addItem(localItem)

        // 3. Active Remote Status
        if p.remoteContext.hasActiveRemoteSession {
            let host = p.remoteContext.resolvedPeer?.hostName ?? p.remoteContext.windowTitle
            let detail: String
            let sym: String
            if let st = p.remotePeerState, st.daemonReachable {
                let rtt = st.lastRTTMs.map { String(format: " · %.1fms", $0) } ?? ""
                detail = "원격 활성: \(host) [\(st.currentLanguage.shortBadge)]\(rtt)"
                sym = "bolt.horizontal.fill"
            } else {
                detail = "원격 폴백: \(host) (TailIME 미연결)"
                sym = "arrow.up.right.circle"
            }
            let rItem = makeMenuItem(title: detail, symbol: sym, action: nil)
            rItem.isEnabled = false
            menu.addItem(rItem)
        } else {
            let idle = makeMenuItem(title: "원격 세션: 대기 중", symbol: "desktopcomputer", action: nil)
            idle.isEnabled = false
            menu.addItem(idle)
        }

        // 4. Remote Target Selector Submenu
        let targetMenu = NSMenu()
        let autoItem = makeMenuItem(title: "자동 감지 (포커스 창·소켓 기반)", symbol: "sparkles", action: #selector(handleSelectPeer(_:)))
        autoItem.representedObject = nil
        autoItem.state = (p.pinnedPeerID == nil) ? .on : .off
        targetMenu.addItem(autoItem)
        targetMenu.addItem(.separator())

        let macPeers = p.tailscalePeers.filter(\.isMacOS)
        if macPeers.isEmpty {
            let none = NSMenuItem(title: "감지된 Tailscale Mac 피어 없음", action: nil, keyEquivalent: "")
            none.isEnabled = false
            targetMenu.addItem(none)
        } else {
            for peer in macPeers {
                let dot = peer.online ? "●" : "○"
                let ip = peer.preferredIP ?? "-"
                let item = NSMenuItem(title: "\(dot) \(peer.hostName) (\(ip))", action: #selector(handleSelectPeer(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.id
                item.state = (p.pinnedPeerID == peer.id) ? .on : .off
                targetMenu.addItem(item)
            }
        }
        targetMenu.addItem(.separator())
        let refreshPeers = makeMenuItem(title: "Tailscale 피어 새로고침", symbol: "arrow.clockwise", action: #selector(handleRefreshTailscale))
        targetMenu.addItem(refreshPeers)

        let targetRoot = makeMenuItem(title: "원격 대상 Mac 선택", symbol: "macbook.and.iphone", action: nil)
        targetRoot.submenu = targetMenu
        menu.addItem(targetRoot)

        // 5. Active Triggers Summary
        let triggerItem = makeMenuItem(title: "한영키: \(p.activeTriggersSummary)", symbol: "keyboard", action: #selector(handleOpenTriggerSettings))
        menu.addItem(triggerItem)

        menu.addItem(.separator())

        // 6. Controls
        let pauseItem = makeMenuItem(
            title: p.paused ? "재개하기" : "일시정지",
            symbol: p.paused ? "play.circle" : "pause.circle",
            action: #selector(handleTogglePause)
        )
        menu.addItem(pauseItem)

        let settingsItem = makeMenuItem(title: "설정...", symbol: "gearshape", action: #selector(handleOpenGeneralSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)

        let diagItem = makeMenuItem(title: "진단 및 실시간 키 테스트...", symbol: "stethoscope", action: #selector(handleOpenDiagnostics))
        menu.addItem(diagItem)

        menu.addItem(.separator())

        let quitItem = makeMenuItem(title: "TailIME 종료", symbol: "power", action: #selector(handleQuit), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func makeMenuItem(
        title: String,
        symbol: String,
        action: Selector?,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = (action != nil) ? self : nil
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            img.isTemplate = true
            item.image = img
        }
        return item
    }

    @objc private func handleToggleLocal() { onToggleLocalLanguage?() }
    @objc private func handleTogglePause() { onTogglePause?() }
    @objc private func handleRequestAccessibility() { onRequestAccessibility?() }
    @objc private func handleRetryKeychain() { onRetryKeychain?() }
    @objc private func handleRefreshTailscale() { onRefreshTailscale?() }
    @objc private func handleOpenGeneralSettings() { onOpenSettings?(0) }
    @objc private func handleOpenTriggerSettings() { onOpenSettings?(1) }
    @objc private func handleOpenDiagnostics() { onOpenSettings?(3) }
    @objc private func handleQuit() { onQuit?() }

    @objc private func handleSelectPeer(_ sender: NSMenuItem) {
        onSelectPinnedPeer?(sender.representedObject as? String)
    }
}

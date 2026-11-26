import AppKit
import TailIMECore

struct StatusBarPresentation {
    let localLanguage: InputLanguage
    let localSourceName: String
    let enabled: Bool
    let paused: Bool
    let accessibilityGranted: Bool
    let secureInputAppName: String?
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

        let warning = !presentation.accessibilityGranted || presentation.secureInputAppName != nil
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

        // 1. Accessibility / Secure Input Warnings
        if !p.accessibilityGranted {
            let item = NSMenuItem(
                title: "⚠ 손쉬운 사용(접근성) 권한 필요 — 클릭하여 열기",
                action: #selector(handleRequestAccessibility),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if let secureApp = p.secureInputAppName {
            let item = NSMenuItem(
                title: "🔒 Secure Input 활성 (\(secureApp)) — 암호 입력 중",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // 2. Local Status & Quick Toggle
        let localTitle = "로컬 입력기: \(p.localSourceName) (\(p.localLanguage.shortBadge))"
        let localItem = NSMenuItem(title: localTitle, action: #selector(handleToggleLocal), keyEquivalent: "")
        localItem.target = self
        menu.addItem(localItem)

        // 3. Active Remote Status
        if p.remoteContext.hasActiveRemoteSession {
            let host = p.remoteContext.resolvedPeer?.hostName ?? p.remoteContext.windowTitle
            let detail: String
            if let st = p.remotePeerState, st.daemonReachable {
                let rtt = st.lastRTTMs.map { String(format: " · %.1fms", $0) } ?? ""
                detail = "⚡ 원격 활성: \(host) [\(st.currentLanguage.shortBadge)]\(rtt)"
            } else {
                detail = "↗ 원격 폴백: \(host) (TailIME 미연결)"
            }
            let rItem = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            rItem.isEnabled = false
            menu.addItem(rItem)
        } else {
            let idle = NSMenuItem(title: "원격 세션: 대기 중", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(idle)
        }

        // 4. Remote Target Selector Submenu
        let targetMenu = NSMenu()
        let autoItem = NSMenuItem(title: "자동 감지 (포커스 창·소켓 기반)", action: #selector(handleSelectPeer(_:)), keyEquivalent: "")
        autoItem.target = self
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
        let refreshPeers = NSMenuItem(title: "Tailscale 피어 새로고침", action: #selector(handleRefreshTailscale), keyEquivalent: "")
        refreshPeers.target = self
        targetMenu.addItem(refreshPeers)

        let targetRoot = NSMenuItem(title: "원격 대상 Mac 선택", action: nil, keyEquivalent: "")
        targetRoot.submenu = targetMenu
        menu.addItem(targetRoot)

        // 5. Active Triggers Summary
        let triggerItem = NSMenuItem(title: "감지된 한영키: \(p.activeTriggersSummary)", action: #selector(handleOpenTriggerSettings), keyEquivalent: "")
        triggerItem.target = self
        menu.addItem(triggerItem)

        menu.addItem(.separator())

        // 6. Controls
        let pauseItem = NSMenuItem(title: p.paused ? "재개하기" : "일시정지", action: #selector(handleTogglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let settingsItem = NSMenuItem(title: "설정...", action: #selector(handleOpenGeneralSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let diagItem = NSMenuItem(title: "진단 및 실시간 키 테스트...", action: #selector(handleOpenDiagnostics), keyEquivalent: "")
        diagItem.target = self
        menu.addItem(diagItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "TailIME 종료", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleToggleLocal() { onToggleLocalLanguage?() }
    @objc private func handleTogglePause() { onTogglePause?() }
    @objc private func handleRequestAccessibility() { onRequestAccessibility?() }
    @objc private func handleRefreshTailscale() { onRefreshTailscale?() }
    @objc private func handleOpenGeneralSettings() { onOpenSettings?(0) }
    @objc private func handleOpenTriggerSettings() { onOpenSettings?(1) }
    @objc private func handleOpenDiagnostics() { onOpenSettings?(3) }
    @objc private func handleQuit() { onQuit?() }

    @objc private func handleSelectPeer(_ sender: NSMenuItem) {
        onSelectPinnedPeer?(sender.representedObject as? String)
    }
}

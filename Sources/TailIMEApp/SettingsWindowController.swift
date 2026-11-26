import AppKit
import ServiceManagement
import TailIMECore

struct DiagnosticsSummary {
    let version: String
    let enabled: Bool
    let paused: Bool
    let hidTapActive: Bool
    let sessionTapActive: Bool
    let accessibilityGranted: Bool
    let postEventAccessGranted: Bool
    let keychainErrorStatus: OSStatus?
    let textInputSwitcherRunning: Bool
    let secureInputAppName: String?
    let conflictingApps: [String]
    let boundUDPAddresses: [String]
    let systemHotkeyDescription: String
    let karabinerSummary: String
    let carrierDescription: String
    let activeRemoteDescription: String
}

/// Modern native 4-tab macOS Settings & Diagnostics window for TailIME (Apple HIG card layout).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let segmentedTabs = NSSegmentedControl()
    private let tabView = NSTabView()

    // Header
    private let headerVersionLabel = NSTextField(labelWithString: "v1.0.2")
    private let statusPillContainer = NSView()
    private let statusPillLabel = NSTextField(labelWithString: "")

    // Tab 0: General
    private let enabledCheck = NSButton(checkboxWithTitle: "TailIME 활성화", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "로그인 시 자동 실행", target: nil, action: nil)
    private let accessibilityStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let requestAccessibilityBtn = NSButton(title: "손쉬운 사용 권한 열기", target: nil, action: nil)
    private let keychainBannerCard = NSBox()
    private let keychainBannerLabel = NSTextField(wrappingLabelWithString: "")
    private let retryKeychainBtn = NSButton(title: "키체인 다시 읽기", target: nil, action: nil)
    private let conflictBannerCard = NSBox()
    private let conflictBannerLabel = NSTextField(wrappingLabelWithString: "")
    private let envSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let testInputField = NSTextField()

    // Tab 1: Triggers
    private let autoSystemCheck = NSButton(checkboxWithTitle: "macOS 입력 소스 단축키(60/61번 · Caps Lock 한/A) 자동 감지", target: nil, action: nil)
    private let autoKarabinerCheck = NSButton(checkboxWithTitle: "Karabiner-Elements 설정 자동 감지 (읽기 전용 · 모든 컨트롤/모디파이어 키 지원)", target: nil, action: nil)
    private let autoHangulCheck = NSButton(checkboxWithTitle: "하드웨어 한/영 키(Lang1) 자동 감지", target: nil, action: nil)
    private let recordBtn = NSButton(title: "한영키 직접 녹화...", target: nil, action: nil)
    private let clearUserTriggersBtn = NSButton(title: "사용자 키 초기화", target: nil, action: nil)
    private let presetPopup = NSPopUpButton()
    private let addPresetBtn = NSButton(title: "추가", target: nil, action: nil)
    private let activeTriggersText = NSTextField(wrappingLabelWithString: "")
    private let swapBackquoteCheck = NSButton(checkboxWithTitle: "한글 상태에서 ₩ 대신 ` 입력", target: nil, action: nil)
    private let escapeEnglishCheck = NSButton(checkboxWithTitle: "ESC 누를 시 영문 전환", target: nil, action: nil)
    private let localHUDCheck = NSButton(checkboxWithTitle: "로컬 한영 전환 시에도 미니 HUD 표시", target: nil, action: nil)
    private let optionalHIDCheck = NSButton(checkboxWithTitle: "(Karabiner 미사용자 전용) 우측 Command → F19 내장 HID 리매핑", target: nil, action: nil)
    private let optionalHIDNote = NSTextField(wrappingLabelWithString: "")

    // Tab 2: Remote Tailscale
    private let remoteEnabledCheck = NSButton(checkboxWithTitle: "Tailscale 원격 Mac 한영 전환 활성화", target: nil, action: nil)
    private let autoEnglishCheck = NSButton(checkboxWithTitle: "원격 창 포커스 시 로컬 Mac 자동 영문(ABC) 고정", target: nil, action: nil)
    private let restoreBlurCheck = NSButton(checkboxWithTitle: "원격 창 벗어날 때 이전 로컬 입력기 복원", target: nil, action: nil)
    private let remoteHUDCheck = NSButton(checkboxWithTitle: "원격 전환 시 미니 HUD 알림 표시", target: nil, action: nil)
    private let transportPopup = NSPopUpButton()
    private let fallbackPopup = NSPopUpButton()
    private let tailscaleStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let peerPopup = NSPopUpButton()
    private let pairDirectBtn = NSButton(title: "직접 페어링 요청", target: nil, action: nil)
    private let pingPeerBtn = NSButton(title: "연결 테스트", target: nil, action: nil)
    private let copyTokenBtn = NSButton(title: "내 토큰 복사", target: nil, action: nil)
    private let pasteTokenBtn = NSButton(title: "토큰 붙여넣기", target: nil, action: nil)
    private let refreshPeersBtn = NSButton(title: "새로고침", target: nil, action: nil)
    private let trustedPeersLabel = NSTextField(wrappingLabelWithString: "")
    private let clearTrustedBtn = NSButton(title: "신뢰 기기 초기화", target: nil, action: nil)
    private let remoteActionStatusLabel = NSTextField(wrappingLabelWithString: "")

    // Tab 3: Diagnostics
    private let diagSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let wakeTISBtn = NSButton(title: "TextInputSwitcher 깨우기", target: nil, action: nil)
    private let copyDiagBtn = NSButton(title: "진단 요약 복사", target: nil, action: nil)
    private let clearLogBtn = NSButton(title: "로그 지우기", target: nil, action: nil)
    private let diagTextView = NSTextView()

    // State & callbacks
    private var displayedMacPeers: [TailscalePeer] = []
    private var latestDiagnostics: DiagnosticsSummary?
    private let presetOptions: [(String, TriggerSpec)] = [
        ("F18", TriggerSpec(keyCode: VirtualKeyCode.f18, origin: .userPreset)),
        ("F19", TriggerSpec(keyCode: VirtualKeyCode.f19, origin: .userPreset)),
        ("Control + Space", TriggerSpec(keyCode: VirtualKeyCode.space, modifiers: [.control], origin: .userPreset)),
        ("Command + Space", TriggerSpec(keyCode: VirtualKeyCode.space, modifiers: [.command], origin: .userPreset)),
        ("Option + Space", TriggerSpec(keyCode: VirtualKeyCode.space, modifiers: [.option], origin: .userPreset)),
        ("Shift + Space", TriggerSpec(keyCode: VirtualKeyCode.space, modifiers: [.shift], origin: .userPreset)),
        ("우측 Command ⌘ (단독 탭)", TriggerSpec(keyCode: VirtualKeyCode.rightCommand, kind: .modifierTap, origin: .userPreset)),
        ("우측 Option ⌥ (단독 탭)", TriggerSpec(keyCode: VirtualKeyCode.rightOption, kind: .modifierTap, origin: .userPreset)),
        ("우측 Control ⌃ (단독 탭)", TriggerSpec(keyCode: VirtualKeyCode.rightControl, kind: .modifierTap, origin: .userPreset)),
        ("우측 Shift ⇧ (단독 탭)", TriggerSpec(keyCode: VirtualKeyCode.rightShift, kind: .modifierTap, origin: .userPreset)),
        ("좌측 Control ⌃ (단독 탭)", TriggerSpec(keyCode: VirtualKeyCode.leftControl, kind: .modifierTap, origin: .userPreset)),
        ("좌측 Option ⌥ (단독 탭)", TriggerSpec(keyCode: VirtualKeyCode.leftOption, kind: .modifierTap, origin: .userPreset)),
    ]

    var onSettingsMutate: (((inout AppSettings) -> Void) -> Void)?
    var onToggleLoginItem: ((Bool) -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRetryKeychain: (() -> Void)?
    var onStartRecordingTrigger: (() -> Void)?
    var onInitiatePairing: ((String) -> String)?
    var onPingPeer: ((String, @escaping (String) -> Void) -> Void)?
    var onCopyMyPairingToken: (() -> String?)?
    var onImportPairingToken: ((String) -> String)?
    var onClearTrustedPeers: (() -> Void)?
    var onRefreshTailscale: (() -> Void)?
    var onWakeTextInputSwitcher: (() -> Void)?
    var onDiagnosticsVisibleChanged: ((Bool) -> Void)?

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 690, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TailIME 설정"
        win.titlebarAppearsTransparent = false
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show(tab index: Int = 0) {
        let clamped = max(0, min(index, tabView.numberOfTabViewItems - 1))
        selectTab(clamped)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        notifyDiagnosticsVisibility()
    }

    private func selectTab(_ index: Int) {
        segmentedTabs.selectedSegment = index
        tabView.selectTabViewItem(at: index)
        notifyDiagnosticsVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        onDiagnosticsVisibleChanged?(false)
    }

    private func notifyDiagnosticsVisibility() {
        let isOpen = window?.isVisible == true
        let isDiagTab = tabView.selectedTabViewItem.map { tabView.indexOfTabViewItem($0) == 3 } ?? false
        onDiagnosticsVisibleChanged?(isOpen && isDiagTab)
    }

    func appendDiagnosticLine(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ts = Self.timeFormatter.string(from: Date())
            let entry = "[\(ts)] \(line)\n"
            let storage = self.diagTextView.textStorage
            storage?.append(NSAttributedString(
                string: entry,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]
            ))
            if let len = storage?.length, len > 24_000 {
                storage?.deleteCharacters(in: NSRange(location: 0, length: len - 18_000))
            }
            self.diagTextView.scrollToEndOfDocument(nil)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func updateRecordingState(_ recording: Bool) {
        recordBtn.title = recording ? "원하는 한영키를 누르세요 (ESC 취소)..." : "한영키 직접 녹화..."
        recordBtn.isEnabled = !recording
    }

    func refresh(
        settings: AppSettings,
        activeTriggers: [TriggerSpec],
        trustedPeers: [TrustedPeerRecord],
        tailscaleSnapshot: TailscaleStatusSnapshot,
        peerStates: [String: RemotePeerRuntimeState],
        diagnostics: DiagnosticsSummary
    ) {
        latestDiagnostics = diagnostics
        headerVersionLabel.stringValue = "v\(diagnostics.version)"

        // Header Status Pill
        if !diagnostics.enabled || diagnostics.paused {
            applyStatusPill(text: "⏸ 일시정지", bg: NSColor.systemGray.withAlphaComponent(0.18), fg: .secondaryLabelColor)
        } else if !diagnostics.accessibilityGranted {
            applyStatusPill(text: "⚠ 손쉬운 사용 권한 필요", bg: NSColor.systemOrange.withAlphaComponent(0.18), fg: .systemOrange)
        } else if diagnostics.keychainErrorStatus != nil {
            applyStatusPill(text: "⚠ 키체인 접근 필요", bg: NSColor.systemOrange.withAlphaComponent(0.18), fg: .systemOrange)
        } else if !diagnostics.conflictingApps.isEmpty {
            applyStatusPill(text: "⚠ 충돌 앱 감지", bg: NSColor.systemOrange.withAlphaComponent(0.18), fg: .systemOrange)
        } else if diagnostics.secureInputAppName != nil {
            applyStatusPill(text: "🔒 암호 입력 보호 중", bg: NSColor.systemYellow.withAlphaComponent(0.20), fg: .systemOrange)
        } else {
            applyStatusPill(text: "● 정상 작동 중", bg: NSColor.systemGreen.withAlphaComponent(0.16), fg: .systemGreen)
        }

        // Tab 0: General
        enabledCheck.state = settings.enabled ? .on : .off
        loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        accessibilityStatusLabel.stringValue = diagnostics.accessibilityGranted
            ? "✓ 손쉬운 사용(Accessibility) 권한이 허용되어 초저지연 이벤트 탭이 활성 상태입니다."
            : "⚠ 손쉬운 사용 권한이 필요합니다. 허용 즉시 재시작 없이 자동으로 활성화됩니다."
        accessibilityStatusLabel.textColor = diagnostics.accessibilityGranted ? .systemGreen : .systemOrange
        requestAccessibilityBtn.isHidden = diagnostics.accessibilityGranted

        if let kcErr = diagnostics.keychainErrorStatus {
            keychainBannerCard.isHidden = false
            keychainBannerLabel.stringValue = "⚠ 키체인 기기 키(com.tailime.app.identity) 접근이 거부되었습니다 (OSStatus \(kcErr)).\n기존 페어링 키를 보호하기 위해 덮어쓰지 않았습니다. 아래 버튼을 눌러 「항상 허용」을 선택하면 재페어링 없이 즉시 복구됩니다."
        } else {
            keychainBannerCard.isHidden = true
        }

        if diagnostics.conflictingApps.isEmpty {
            conflictBannerCard.isHidden = true
        } else {
            conflictBannerCard.isHidden = false
            let names = diagnostics.conflictingApps.joined(separator: ", ")
            conflictBannerLabel.stringValue = "⚠ 충돌 가능 한영 전환 앱 실행 중: \(names)\n같은 키보드 이벤트 탭을 가로채 한영 전환이 꼬일 수 있으므로 위 앱을 종료한 뒤 사용하세요."
        }

        envSummaryLabel.stringValue = """
        • 시스템 입력 소스 단축키 : \(diagnostics.systemHotkeyDescription)
        • Karabiner-Elements     : \(diagnostics.karabinerSummary)
        • TextInputSwitcher      : \(diagnostics.textInputSwitcherRunning ? "실행 중 (즉시 응답 준비됨)" : "대기/절전 (자동 백그라운드 웜업)")
        • 현재 원격 컨텍스트      : \(diagnostics.activeRemoteDescription)
        """

        // Tab 1: Triggers
        autoSystemCheck.state = settings.autoDetectSystemHotkey ? .on : .off
        autoKarabinerCheck.state = settings.autoDetectKarabiner ? .on : .off
        autoHangulCheck.state = settings.autoDetectHardwareHangul ? .on : .off
        swapBackquoteCheck.state = settings.swapBackquoteInKorean ? .on : .off
        escapeEnglishCheck.state = settings.escapeToEnglish ? .on : .off
        localHUDCheck.state = settings.showLocalHUD ? .on : .off

        let karabinerRunning = HIDRemapper.isKarabinerRunning()
        optionalHIDCheck.state = (settings.optionalHIDRemapEnabled && !karabinerRunning) ? .on : .off
        optionalHIDCheck.isEnabled = !karabinerRunning
        optionalHIDNote.stringValue = karabinerRunning
            ? "Karabiner-Elements 실행 중이므로 충돌 방지를 위해 내장 HID 리매핑이 자동 잠금되었습니다."
            : "Karabiner 없이 우측 Command를 즉시 전환(keyDown)으로 쓰고 싶을 때만 켜세요."

        let trigLines = activeTriggers.map { "  • \($0.label)  [\($0.origin.rawValue)]" }.joined(separator: "\n")
        activeTriggersText.stringValue = trigLines.isEmpty ? "등록된 트리거 없음" : trigLines

        // Tab 2: Remote Tailscale
        remoteEnabledCheck.state = settings.remoteSyncEnabled ? .on : .off
        autoEnglishCheck.state = settings.autoEnglishOnRemoteFocus ? .on : .off
        restoreBlurCheck.state = settings.restoreLocalSourceOnRemoteBlur ? .on : .off
        remoteHUDCheck.state = settings.showRemoteHUD ? .on : .off

        if let idx = RemoteTransportMode.allCases.firstIndex(of: settings.transportMode) {
            transportPopup.selectItem(at: idx)
        }
        if let idx = FallbackKeyMode.allCases.firstIndex(of: settings.fallbackKeyMode) {
            fallbackPopup.selectItem(at: idx)
        }

        let selfIP = tailscaleSnapshot.selfNode?.ipv4 ?? "감지 안 됨"
        let selfHost = tailscaleSnapshot.selfNode?.hostName ?? Host.current().localizedName ?? "Mac"
        let binds = diagnostics.boundUDPAddresses.isEmpty ? "미바인딩" : diagnostics.boundUDPAddresses.joined(separator: ", ")
        tailscaleStatusLabel.stringValue = "내 기기: \(selfHost) (\(selfIP))\nUDP 바인딩: \(binds)"

        let prevSelectedIP = selectedPeerIP()
        displayedMacPeers = tailscaleSnapshot.peers.filter(\.isMacOS)
        peerPopup.removeAllItems()
        if displayedMacPeers.isEmpty {
            peerPopup.addItem(withTitle: "감지된 Tailscale Mac 피어 없음")
            pairDirectBtn.isEnabled = false
            pingPeerBtn.isEnabled = false
        } else {
            for peer in displayedMacPeers {
                let ip = peer.preferredIP ?? "-"
                let st = peerStates[ip]
                let extra: String
                if let st, st.daemonReachable {
                    let rtt = st.lastRTTMs.map { String(format: "%.1fms", $0) } ?? "OK"
                    extra = " [TailIME 연결됨 · \(st.currentLanguage.shortBadge) · \(rtt)]"
                } else {
                    extra = peer.online ? " [온라인]" : " [오프라인]"
                }
                peerPopup.addItem(withTitle: "\(peer.hostName) (\(ip))\(extra)")
            }
            if let prev = prevSelectedIP,
               let matchIdx = displayedMacPeers.firstIndex(where: { $0.preferredIP == prev }) {
                peerPopup.selectItem(at: matchIdx)
            }
            pairDirectBtn.isEnabled = true
            pingPeerBtn.isEnabled = true
        }

        if trustedPeers.isEmpty {
            trustedPeersLabel.stringValue = "신뢰된 원격 Mac 없음 — 위에서 피어를 선택해 페어링하거나 토큰을 교환하세요."
        } else {
            trustedPeersLabel.stringValue = trustedPeers.map { rec in
                let ip = rec.lastKnownIP ?? "IP 대기"
                let st = peerStates[ip]
                let status = (st?.daemonReachable == true) ? "● 연결됨" : "○ 대기"
                return "• \(rec.name) (\(ip))  \(status)"
            }.joined(separator: "\n")
        }

        // Tab 3: Diagnostics
        let conflictText = diagnostics.conflictingApps.isEmpty
            ? "없음 (정상)"
            : "⚠ \(diagnostics.conflictingApps.joined(separator: ", ")) (종료 권장)"
        let keychainText = diagnostics.keychainErrorStatus.map { "⚠ 접근 거부됨 (OSStatus \($0) · 재읽기 필요)" }
            ?? "정상 (영구 기기 키 로드됨)"
        diagSummaryLabel.stringValue = """
        • 버전 / EventTap    : v\(diagnostics.version)  |  HID=\(diagnostics.hidTapActive ? "활성" : "비활성")  ·  Session=\(diagnostics.sessionTapActive ? "활성" : "비활성")
        • 권한 상태          : 접근성=\(diagnostics.accessibilityGranted ? "허용" : "거부")  ·  이벤트 포스팅=\(diagnostics.postEventAccessGranted ? "허용" : "거부")
        • 키체인 기기 키     : \(keychainText)
        • Secure Input       : \(diagnostics.secureInputAppName ?? "비활성 (정상)")
        • 충돌 가능 앱       : \(conflictText)
        • 현재 원격 컨텍스트 : \(diagnostics.activeRemoteDescription)
        • In-Band 캐리어     : \(diagnostics.carrierDescription)
        """
    }

    private func applyStatusPill(text: String, bg: NSColor, fg: NSColor) {
        statusPillLabel.stringValue = text
        statusPillLabel.textColor = fg
        statusPillContainer.layer?.backgroundColor = bg.cgColor
    }

    private func selectedPeerIP() -> String? {
        let idx = peerPopup.indexOfSelectedItem
        guard idx >= 0 && idx < displayedMacPeers.count else { return nil }
        return displayedMacPeers[idx].preferredIP
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // 1. Header Banner
        let header = buildHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false

        // 2. Segmented Tab Bar
        segmentedTabs.segmentCount = 4
        segmentedTabs.segmentStyle = .texturedRounded
        segmentedTabs.trackingMode = .selectOne
        segmentedTabs.target = self
        segmentedTabs.action = #selector(segmentChanged)
        let tabDefs: [(String, String)] = [
            ("일반", "gearshape"),
            ("한영키", "keyboard"),
            ("원격 Tailscale", "bolt.horizontal.fill"),
            ("진단", "stethoscope"),
        ]
        for (idx, def) in tabDefs.enumerated() {
            segmentedTabs.setLabel(def.0, forSegment: idx)
            if let img = NSImage(systemSymbolName: def.1, accessibilityDescription: def.0) {
                segmentedTabs.setImage(img, forSegment: idx)
                segmentedTabs.setImageScaling(.scaleProportionallyDown, forSegment: idx)
            }
            segmentedTabs.setWidth(idx == 2 ? 148 : 112, forSegment: idx)
        }
        segmentedTabs.selectedSegment = 0
        segmentedTabs.translatesAutoresizingMaskIntoConstraints = false

        // 3. Borderless Tab Content View
        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeTab(title: "일반", view: buildGeneralTab()))
        tabView.addTabViewItem(makeTab(title: "한영키", view: buildTriggersTab()))
        tabView.addTabViewItem(makeTab(title: "원격 Tailscale", view: buildRemoteTab()))
        tabView.addTabViewItem(makeTab(title: "진단", view: buildDiagnosticsTab()))

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(header)
        contentView.addSubview(segmentedTabs)
        contentView.addSubview(divider)
        contentView.addSubview(tabView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),

            segmentedTabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            segmentedTabs.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            divider.topAnchor.constraint(equalTo: segmentedTabs.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            tabView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    private func buildHeaderView() -> NSView {
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
        ])

        let appTitle = NSTextField(labelWithString: "TailIME")
        appTitle.font = .systemFont(ofSize: 17, weight: .bold)

        headerVersionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        headerVersionLabel.textColor = .secondaryLabelColor

        let titleRow = NSStackView(views: [appTitle, headerVersionLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6

        let subtitle = NSTextField(labelWithString: "초저지연 로컬 · Tailscale 원격 Mac 한영 전환")
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor

        let titleCol = NSStackView(views: [titleRow, subtitle])
        titleCol.orientation = .vertical
        titleCol.alignment = .leading
        titleCol.spacing = 1

        statusPillContainer.wantsLayer = true
        statusPillContainer.layer?.cornerRadius = 11
        statusPillContainer.translatesAutoresizingMaskIntoConstraints = false
        statusPillLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusPillLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPillContainer.addSubview(statusPillLabel)
        NSLayoutConstraint.activate([
            statusPillLabel.topAnchor.constraint(equalTo: statusPillContainer.topAnchor, constant: 4),
            statusPillLabel.bottomAnchor.constraint(equalTo: statusPillContainer.bottomAnchor, constant: -4),
            statusPillLabel.leadingAnchor.constraint(equalTo: statusPillContainer.leadingAnchor, constant: 10),
            statusPillLabel.trailingAnchor.constraint(equalTo: statusPillContainer.trailingAnchor, constant: -10),
        ])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [iconView, titleCol, spacer, statusPillContainer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func makeTab(title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func makeCard(title: String? = nil, views: [NSView], tint: NSColor? = nil) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = tint?.withAlphaComponent(0.45) ?? NSColor.separatorColor.withAlphaComponent(0.5)
        box.fillColor = tint?.withAlphaComponent(0.08) ?? NSColor.controlBackgroundColor
        box.contentViewMargins = NSSize(width: 14, height: 11)
        box.translatesAutoresizingMaskIntoConstraints = false

        var allViews: [NSView] = []
        if let title {
            let lbl = NSTextField(labelWithString: title)
            lbl.font = .systemFont(ofSize: 12.5, weight: .semibold)
            lbl.textColor = .labelColor
            allViews.append(lbl)
        }
        allViews.append(contentsOf: views)

        let stack = NSStackView(views: allViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)

        if let content = box.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        return box
    }

    private func buildGeneralTab() -> NSView {
        enabledCheck.target = self; enabledCheck.action = #selector(toggleEnabled)
        loginCheck.target = self; loginCheck.action = #selector(toggleLogin)
        requestAccessibilityBtn.target = self; requestAccessibilityBtn.action = #selector(tapRequestAccessibility)
        requestAccessibilityBtn.bezelColor = .controlAccentColor

        accessibilityStatusLabel.font = .systemFont(ofSize: 12)
        envSummaryLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        envSummaryLabel.textColor = .secondaryLabelColor

        keychainBannerLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        keychainBannerLabel.textColor = .systemOrange
        retryKeychainBtn.target = self; retryKeychainBtn.action = #selector(tapRetryKeychain)
        retryKeychainBtn.bezelColor = .controlAccentColor
        keychainBannerCard.boxType = .custom
        keychainBannerCard.cornerRadius = 10
        keychainBannerCard.borderWidth = 1
        keychainBannerCard.borderColor = NSColor.systemOrange.withAlphaComponent(0.55)
        keychainBannerCard.fillColor = NSColor.systemOrange.withAlphaComponent(0.10)
        keychainBannerCard.contentViewMargins = NSSize(width: 14, height: 10)
        keychainBannerCard.translatesAutoresizingMaskIntoConstraints = false
        let kcStack = NSStackView(views: [keychainBannerLabel, retryKeychainBtn])
        kcStack.orientation = .vertical
        kcStack.alignment = .leading
        kcStack.spacing = 6
        kcStack.translatesAutoresizingMaskIntoConstraints = false
        keychainBannerCard.contentView?.addSubview(kcStack)
        if let c = keychainBannerCard.contentView {
            NSLayoutConstraint.activate([
                kcStack.topAnchor.constraint(equalTo: c.topAnchor),
                kcStack.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                kcStack.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                kcStack.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            ])
        }
        keychainBannerCard.isHidden = true

        conflictBannerLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        conflictBannerLabel.textColor = .systemOrange
        conflictBannerCard.boxType = .custom
        conflictBannerCard.cornerRadius = 10
        conflictBannerCard.borderWidth = 1
        conflictBannerCard.borderColor = NSColor.systemOrange.withAlphaComponent(0.55)
        conflictBannerCard.fillColor = NSColor.systemOrange.withAlphaComponent(0.10)
        conflictBannerCard.contentViewMargins = NSSize(width: 14, height: 10)
        conflictBannerCard.translatesAutoresizingMaskIntoConstraints = false
        conflictBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        conflictBannerCard.contentView?.addSubview(conflictBannerLabel)
        if let c = conflictBannerCard.contentView {
            NSLayoutConstraint.activate([
                conflictBannerLabel.topAnchor.constraint(equalTo: c.topAnchor),
                conflictBannerLabel.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                conflictBannerLabel.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                conflictBannerLabel.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            ])
        }
        conflictBannerCard.isHidden = true

        testInputField.placeholderString = "예: 한dud한dud — 여기에 한글과 영어를 빠르게 번갈아 입력해 보세요..."
        testInputField.bezelStyle = .roundedBezel
        testInputField.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [enabledCheck, loginCheck])
        topRow.orientation = .horizontal
        topRow.spacing = 24

        let coreCard = makeCard(
            title: "기본 동작 및 권한",
            views: [topRow, accessibilityStatusLabel, requestAccessibilityBtn]
        )
        let envCard = makeCard(
            title: "자동 감지된 시스템 환경",
            views: [envSummaryLabel]
        )
        let testCard = makeCard(
            title: "즉시 전환 테스트",
            views: [testInputField]
        )

        let stack = NSStackView(views: [coreCard, keychainBannerCard, conflictBannerCard, envCard, testCard])
        NSLayoutConstraint.activate([
            testInputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 580),
        ])
        return wrapStack(stack)
    }

    private func buildTriggersTab() -> NSView {
        autoSystemCheck.target = self; autoSystemCheck.action = #selector(toggleAutoDetect)
        autoKarabinerCheck.target = self; autoKarabinerCheck.action = #selector(toggleAutoDetect)
        autoHangulCheck.target = self; autoHangulCheck.action = #selector(toggleAutoDetect)
        recordBtn.target = self; recordBtn.action = #selector(tapRecordTrigger)
        recordBtn.bezelColor = .controlAccentColor
        clearUserTriggersBtn.target = self; clearUserTriggersBtn.action = #selector(tapClearUserTriggers)
        addPresetBtn.target = self; addPresetBtn.action = #selector(tapAddPreset)
        swapBackquoteCheck.target = self; swapBackquoteCheck.action = #selector(toggleLocalOptions)
        escapeEnglishCheck.target = self; escapeEnglishCheck.action = #selector(toggleLocalOptions)
        localHUDCheck.target = self; localHUDCheck.action = #selector(toggleLocalOptions)
        optionalHIDCheck.target = self; optionalHIDCheck.action = #selector(toggleOptionalHID)

        presetPopup.removeAllItems()
        for (label, _) in presetOptions { presetPopup.addItem(withTitle: label) }

        let recordRow = NSStackView(views: [recordBtn, clearUserTriggersBtn])
        recordRow.orientation = .horizontal
        recordRow.spacing = 8

        let presetRow = NSStackView(views: [NSTextField(labelWithString: "프리셋 추가:"), presetPopup, addPresetBtn])
        presetRow.orientation = .horizontal
        presetRow.spacing = 8

        activeTriggersText.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        activeTriggersText.textColor = .secondaryLabelColor
        optionalHIDNote.font = .systemFont(ofSize: 11)
        optionalHIDNote.textColor = .secondaryLabelColor

        let autoCard = makeCard(
            title: "자동 호환 감지 (기존 Karabiner · macOS 단축키 설정 불변)",
            views: [autoSystemCheck, autoKarabinerCheck, autoHangulCheck]
        )
        let customCard = makeCard(
            title: "추가 한영키 등록 및 현재 활성 트리거",
            views: [recordRow, presetRow, activeTriggersText]
        )
        let localCard = makeCard(
            title: "로컬 입력 편의 기능",
            views: [swapBackquoteCheck, escapeEnglishCheck, localHUDCheck, optionalHIDCheck, optionalHIDNote]
        )

        return wrapStack(NSStackView(views: [autoCard, customCard, localCard]))
    }

    private func buildRemoteTab() -> NSView {
        remoteEnabledCheck.target = self; remoteEnabledCheck.action = #selector(toggleRemoteOptions)
        autoEnglishCheck.target = self; autoEnglishCheck.action = #selector(toggleRemoteOptions)
        restoreBlurCheck.target = self; restoreBlurCheck.action = #selector(toggleRemoteOptions)
        remoteHUDCheck.target = self; remoteHUDCheck.action = #selector(toggleRemoteOptions)

        transportPopup.removeAllItems()
        for m in RemoteTransportMode.allCases { transportPopup.addItem(withTitle: m.displayName) }
        transportPopup.target = self; transportPopup.action = #selector(changeTransportMode)

        fallbackPopup.removeAllItems()
        for m in FallbackKeyMode.allCases { fallbackPopup.addItem(withTitle: m.displayName) }
        fallbackPopup.target = self; fallbackPopup.action = #selector(changeFallbackMode)

        pairDirectBtn.target = self; pairDirectBtn.action = #selector(tapPairDirect)
        pairDirectBtn.bezelColor = .controlAccentColor
        pingPeerBtn.target = self; pingPeerBtn.action = #selector(tapPingPeer)
        copyTokenBtn.target = self; copyTokenBtn.action = #selector(tapCopyToken)
        pasteTokenBtn.target = self; pasteTokenBtn.action = #selector(tapPasteToken)
        refreshPeersBtn.target = self; refreshPeersBtn.action = #selector(tapRefreshPeers)
        clearTrustedBtn.target = self; clearTrustedBtn.action = #selector(tapClearTrusted)

        tailscaleStatusLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tailscaleStatusLabel.textColor = .secondaryLabelColor
        trustedPeersLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        trustedPeersLabel.textColor = .secondaryLabelColor
        remoteActionStatusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        remoteActionStatusLabel.textColor = .systemBlue

        let transportRow = NSStackView(views: [NSTextField(labelWithString: "전송 방식:"), transportPopup])
        transportRow.orientation = .horizontal; transportRow.spacing = 8

        let fallbackRow = NSStackView(views: [NSTextField(labelWithString: "미설치 원격지 폴백:"), fallbackPopup])
        fallbackRow.orientation = .horizontal; fallbackRow.spacing = 8

        let peerRow = NSStackView(views: [peerPopup, refreshPeersBtn])
        peerRow.orientation = .horizontal; peerRow.spacing = 8

        let actionRow = NSStackView(views: [pairDirectBtn, pingPeerBtn, copyTokenBtn, pasteTokenBtn])
        actionRow.orientation = .horizontal; actionRow.spacing = 6

        let behaviorCard = makeCard(
            title: "원격 동기화 동작",
            views: [remoteEnabledCheck, autoEnglishCheck, restoreBlurCheck, remoteHUDCheck, transportRow, fallbackRow]
        )
        let pairCard = makeCard(
            title: "Tailscale Mac 피어 및 암호화 페어링 (X25519 + 6자리 SAS)",
            views: [tailscaleStatusLabel, peerRow, actionRow, remoteActionStatusLabel, trustedPeersLabel, clearTrustedBtn]
        )

        return wrapStack(NSStackView(views: [behaviorCard, pairCard]))
    }

    private func buildDiagnosticsTab() -> NSView {
        diagSummaryLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        wakeTISBtn.target = self; wakeTISBtn.action = #selector(tapWakeTIS)
        copyDiagBtn.target = self; copyDiagBtn.action = #selector(tapCopyDiag)
        clearLogBtn.target = self; clearLogBtn.action = #selector(tapClearDiagLog)

        let btnRow = NSStackView(views: [wakeTISBtn, copyDiagBtn, clearLogBtn])
        btnRow.orientation = .horizontal; btnRow.spacing = 8

        diagTextView.isEditable = false
        diagTextView.isRichText = false
        diagTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagTextView.backgroundColor = .textBackgroundColor

        let scroll = NSScrollView()
        scroll.documentView = diagTextView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 215).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true

        let note = NSTextField(wrappingLabelWithString: "※ 이 탭이 열려 있는 동안만 키 코드/플래그 메타데이터가 화면에 표시되며, 입력 내용은 디스크에 저장되지 않습니다.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let statusCard = makeCard(
            title: "시스템 · 권한 · 충돌 진단",
            views: [diagSummaryLabel, btnRow]
        )
        let logCard = makeCard(
            title: "실시간 키 이벤트 모니터",
            views: [note, scroll]
        )

        return wrapStack(NSStackView(views: [statusCard, logCard]))
    }

    private func wrapStack(_ stack: NSStackView) -> NSView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6),
        ])
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return container
    }

    // MARK: - Actions

    @objc private func segmentChanged() {
        selectTab(segmentedTabs.selectedSegment)
    }

    @objc private func toggleEnabled() {
        let on = enabledCheck.state == .on
        onSettingsMutate? { $0.enabled = on }
    }

    @objc private func toggleLogin() {
        onToggleLoginItem?(loginCheck.state == .on)
    }

    @objc private func tapRequestAccessibility() {
        onRequestAccessibility?()
    }

    @objc private func tapRetryKeychain() {
        onRetryKeychain?()
    }

    @objc private func toggleAutoDetect() {
        let sys = autoSystemCheck.state == .on
        let kar = autoKarabinerCheck.state == .on
        let han = autoHangulCheck.state == .on
        onSettingsMutate? {
            $0.autoDetectSystemHotkey = sys
            $0.autoDetectKarabiner = kar
            $0.autoDetectHardwareHangul = han
        }
    }

    @objc private func tapRecordTrigger() {
        updateRecordingState(true)
        onStartRecordingTrigger?()
    }

    @objc private func tapClearUserTriggers() {
        onSettingsMutate? { $0.userTriggers = [] }
    }

    @objc private func tapAddPreset() {
        let idx = presetPopup.indexOfSelectedItem
        guard idx >= 0 && idx < presetOptions.count else { return }
        let spec = presetOptions[idx].1
        onSettingsMutate? { settings in
            if !settings.userTriggers.contains(where: { $0.id == spec.id }) {
                settings.userTriggers.append(spec)
            }
        }
    }

    @objc private func toggleLocalOptions() {
        let backquote = swapBackquoteCheck.state == .on
        let esc = escapeEnglishCheck.state == .on
        let hud = localHUDCheck.state == .on
        onSettingsMutate? {
            $0.swapBackquoteInKorean = backquote
            $0.escapeToEnglish = esc
            $0.showLocalHUD = hud
        }
    }

    @objc private func toggleOptionalHID() {
        let on = optionalHIDCheck.state == .on
        onSettingsMutate? { $0.optionalHIDRemapEnabled = on }
    }

    @objc private func toggleRemoteOptions() {
        let rem = remoteEnabledCheck.state == .on
        let abc = autoEnglishCheck.state == .on
        let restore = restoreBlurCheck.state == .on
        let hud = remoteHUDCheck.state == .on
        onSettingsMutate? {
            $0.remoteSyncEnabled = rem
            $0.autoEnglishOnRemoteFocus = abc
            $0.restoreLocalSourceOnRemoteBlur = restore
            $0.showRemoteHUD = hud
        }
    }

    @objc private func changeTransportMode() {
        let idx = transportPopup.indexOfSelectedItem
        guard idx >= 0 && idx < RemoteTransportMode.allCases.count else { return }
        let mode = RemoteTransportMode.allCases[idx]
        onSettingsMutate? { $0.transportMode = mode }
    }

    @objc private func changeFallbackMode() {
        let idx = fallbackPopup.indexOfSelectedItem
        guard idx >= 0 && idx < FallbackKeyMode.allCases.count else { return }
        let mode = FallbackKeyMode.allCases[idx]
        onSettingsMutate? { $0.fallbackKeyMode = mode }
    }

    @objc private func tapPairDirect() {
        guard let ip = selectedPeerIP() else { return }
        let msg = onInitiatePairing?(ip) ?? "\(ip)로 페어링 요청을 보냈습니다. 상대 Mac 화면에서 6자리 코드를 승인하세요."
        remoteActionStatusLabel.stringValue = msg
    }

    @objc private func tapPingPeer() {
        guard let ip = selectedPeerIP() else { return }
        remoteActionStatusLabel.stringValue = "\(ip)에 Ping 전송 중..."
        onPingPeer?(ip) { [weak self] message in
            DispatchQueue.main.async {
                self?.remoteActionStatusLabel.stringValue = message
            }
        }
    }

    @objc private func tapCopyToken() {
        guard let token = onCopyMyPairingToken?() else {
            if latestDiagnostics?.keychainErrorStatus != nil {
                remoteActionStatusLabel.stringValue = "⚠ 키체인 기기 키 접근이 거부되어 토큰을 생성할 수 없습니다. '키체인 다시 읽기'에서 허용해 주세요."
            } else {
                remoteActionStatusLabel.stringValue = "페어링 토큰 생성 실패"
            }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        remoteActionStatusLabel.stringValue = "내 페어링 토큰이 클립보드에 복사되었습니다. 다른 Mac에서 '토큰 붙여넣기'를 누르세요."
    }

    @objc private func tapPasteToken() {
        let paste = NSPasteboard.general.string(forType: .string) ?? ""
        let alert = NSAlert()
        alert.messageText = "상대 Mac 페어링 토큰 입력"
        alert.informativeText = "상대 Mac에서 복사한 TKP1:... 토큰을 붙여넣으세요."
        alert.addButton(withTitle: "등록")
        alert.addButton(withTitle: "취소")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        input.stringValue = paste.hasPrefix("TKP1:") ? paste : ""
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let msg = onImportPairingToken?(input.stringValue) ?? "토큰 등록 실패"
        remoteActionStatusLabel.stringValue = msg
    }

    @objc private func tapRefreshPeers() {
        remoteActionStatusLabel.stringValue = "Tailscale 피어 목록 새로고침 중..."
        onRefreshTailscale?()
    }

    @objc private func tapClearTrusted() {
        let alert = NSAlert()
        alert.messageText = "신뢰된 원격 Mac 목록을 초기화할까요?"
        alert.informativeText = "다시 연결하려면 페어링을 새로 진행해야 합니다."
        alert.addButton(withTitle: "초기화")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            onClearTrustedPeers?()
            remoteActionStatusLabel.stringValue = "신뢰 기기 목록이 초기화되었습니다."
        }
    }

    @objc private func tapWakeTIS() {
        onWakeTextInputSwitcher?()
    }

    @objc private func tapCopyDiag() {
        guard let d = latestDiagnostics else { return }
        let kcDiag = d.keychainErrorStatus.map { "locked (OSStatus \($0))" } ?? "persistent"
        let summary = """
        TailIME v\(d.version) Diagnostics
        - Enabled: \(d.enabled), Paused: \(d.paused)
        - EventTap: HID=\(d.hidTapActive), Session=\(d.sessionTapActive)
        - Permissions: Accessibility=\(d.accessibilityGranted), PostEvent=\(d.postEventAccessGranted)
        - Keychain: \(kcDiag)
        - TextInputSwitcher: \(d.textInputSwitcherRunning ? "running" : "idle")
        - SecureInput: \(d.secureInputAppName ?? "none")
        - ConflictingApps: \(d.conflictingApps.isEmpty ? "none" : d.conflictingApps.joined(separator: ", "))
        - RemoteContext: \(d.activeRemoteDescription)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        appendDiagnosticLine("진단 요약이 클립보드에 복사되었습니다 (민감정보 미포함).")
    }

    @objc private func tapClearDiagLog() {
        diagTextView.string = ""
    }
}

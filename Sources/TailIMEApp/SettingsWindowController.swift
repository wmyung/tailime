import AppKit
import ServiceManagement
import TailIMECore

struct DiagnosticsSummary {
    let hidTapActive: Bool
    let sessionTapActive: Bool
    let accessibilityGranted: Bool
    let postEventAccessGranted: Bool
    let textInputSwitcherRunning: Bool
    let secureInputAppName: String?
    let boundUDPAddresses: [String]
    let systemHotkeyDescription: String
    let karabinerSummary: String
    let carrierDescription: String
    let activeRemoteDescription: String
}

/// Native 4-tab macOS Settings & Diagnostics window for TailIME.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    private let tabView = NSTabView()

    // Tab 0: General
    private let enabledCheck = NSButton(checkboxWithTitle: "TailIME 활성화", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "로그인 시 자동 실행", target: nil, action: nil)
    private let accessibilityStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let requestAccessibilityBtn = NSButton(title: "손쉬운 사용 권한 요청", target: nil, action: nil)
    private let envSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let testInputField = NSTextField()

    // Tab 1: Triggers
    private let autoSystemCheck = NSButton(checkboxWithTitle: "macOS 입력 소스 단축키(60/61번) 자동 감지", target: nil, action: nil)
    private let autoKarabinerCheck = NSButton(checkboxWithTitle: "Karabiner-Elements 설정 자동 감지 (읽기 전용)", target: nil, action: nil)
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
    private let pingPeerBtn = NSButton(title: "연결 테스트(Ping)", target: nil, action: nil)
    private let copyTokenBtn = NSButton(title: "내 페어링 토큰 복사", target: nil, action: nil)
    private let pasteTokenBtn = NSButton(title: "상대 토큰 붙여넣기", target: nil, action: nil)
    private let refreshPeersBtn = NSButton(title: "새로고침", target: nil, action: nil)
    private let trustedPeersLabel = NSTextField(wrappingLabelWithString: "")
    private let clearTrustedBtn = NSButton(title: "신뢰 기기 초기화", target: nil, action: nil)
    private let remoteActionStatusLabel = NSTextField(wrappingLabelWithString: "")

    // Tab 3: Diagnostics
    private let diagSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let wakeTISBtn = NSButton(title: "TextInputSwitcher 깨우기", target: nil, action: nil)
    private let clearLogBtn = NSButton(title: "로그 지우기", target: nil, action: nil)
    private let diagTextView = NSTextView()

    // State & callbacks
    private var displayedMacPeers: [TailscalePeer] = []
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
    ]

    var onSettingsMutate: (((inout AppSettings) -> Void) -> Void)?
    var onToggleLoginItem: ((Bool) -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onStartRecordingTrigger: (() -> Void)?
    var onInitiatePairing: ((String) -> Void)?
    var onPingPeer: ((String, @escaping (String) -> Void) -> Void)?
    var onCopyMyPairingToken: (() -> String?)?
    var onImportPairingToken: ((String) -> String)?
    var onClearTrustedPeers: (() -> Void)?
    var onRefreshTailscale: (() -> Void)?
    var onWakeTextInputSwitcher: (() -> Void)?
    var onDiagnosticsVisibleChanged: ((Bool) -> Void)?

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 530),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TailIME 설정"
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show(tab index: Int = 0) {
        if (0..<tabView.numberOfTabViewItems).contains(index) {
            tabView.selectTabViewItem(at: index)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        notifyDiagnosticsVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        onDiagnosticsVisibleChanged?(false)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        notifyDiagnosticsVisibility()
    }

    private func notifyDiagnosticsVisibility() {
        let visible = (window?.isVisible == true) && (tabView.indexOfTabViewItem(tabView.selectedTabViewItem!) == 3)
        onDiagnosticsVisibleChanged?(visible)
    }

    func appendDiagnosticLine(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let storage = self.diagTextView.textStorage
            let attr = NSAttributedString(
                string: line + "\n",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            storage?.append(attr)
            if (storage?.length ?? 0) > 20_000 {
                storage?.deleteCharacters(in: NSRange(location: 0, length: 4_000))
            }
            self.diagTextView.scrollToEndOfDocument(nil)
        }
    }

    func updateRecordingState(_ recording: Bool) {
        recordBtn.title = recording ? "녹화 중... 한영키를 누르세요 (ESC 취소)" : "한영키 직접 녹화..."
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
        // Tab 0
        enabledCheck.state = settings.enabled ? .on : .off
        loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        accessibilityStatusLabel.stringValue = diagnostics.accessibilityGranted
            ? "✓ 손쉬운 사용(접근성) 권한이 허용되어 있습니다."
            : "⚠ 손쉬운 사용(접근성) 권한이 필요합니다. 허용 후 앱이 자동으로 키 가로채기를 시작합니다."
        accessibilityStatusLabel.textColor = diagnostics.accessibilityGranted ? .systemGreen : .systemOrange
        requestAccessibilityBtn.isHidden = diagnostics.accessibilityGranted

        envSummaryLabel.stringValue = """
        • 시스템 단축키: \(diagnostics.systemHotkeyDescription)
        • Karabiner: \(diagnostics.karabinerSummary)
        • macOS TextInputSwitcher: \(diagnostics.textInputSwitcherRunning ? "실행 중 (준비됨)" : "대기/절전 (자동 웜업 활성)")
        • In-Band 캐리어 키: \(diagnostics.carrierDescription)
        """

        // Tab 1
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
            ? "Karabiner-Elements 실행 중이므로 충돌 방지를 위해 내장 HID 리매핑이 잠겨 있습니다."
            : "Karabiner 없이 우측 Command를 즉시 전환(keyDown)으로 쓰고 싶을 때만 켜세요."

        let trigLines = activeTriggers.map { "• \($0.label) [\($0.origin.rawValue)]" }.joined(separator: "\n")
        activeTriggersText.stringValue = trigLines.isEmpty ? "등록된 트리거 없음" : trigLines

        // Tab 2
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
        tailscaleStatusLabel.stringValue = "내 기기: \(selfHost) (\(selfIP)) · UDP 바인딩: \(binds)"

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
                return "• \(rec.name) (\(ip)) \(status)"
            }.joined(separator: "\n")
        }

        // Tab 3
        diagSummaryLabel.stringValue = """
        • HID EventTap: \(diagnostics.hidTapActive ? "활성" : "비활성")  |  Session EventTap: \(diagnostics.sessionTapActive ? "활성" : "비활성")
        • 접근성 권한: \(diagnostics.accessibilityGranted ? "허용" : "거부")  |  이벤트 포스팅 권한: \(diagnostics.postEventAccessGranted ? "허용" : "거부")
        • Secure Input: \(diagnostics.secureInputAppName ?? "비활성 (정상)")
        • 현재 원격 컨텍스트: \(diagnostics.activeRemoteDescription)
        """
    }

    private func selectedPeerIP() -> String? {
        let idx = peerPopup.indexOfSelectedItem
        guard idx >= 0 && idx < displayedMacPeers.count else { return nil }
        return displayedMacPeers[idx].preferredIP
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        tabView.addTabViewItem(makeTab(title: "일반", view: buildGeneralTab()))
        tabView.addTabViewItem(makeTab(title: "한영키", view: buildTriggersTab()))
        tabView.addTabViewItem(makeTab(title: "원격 Tailscale", view: buildRemoteTab()))
        tabView.addTabViewItem(makeTab(title: "진단", view: buildDiagnosticsTab()))
    }

    private func makeTab(title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func buildGeneralTab() -> NSView {
        enabledCheck.target = self; enabledCheck.action = #selector(toggleEnabled)
        loginCheck.target = self; loginCheck.action = #selector(toggleLogin)
        requestAccessibilityBtn.target = self; requestAccessibilityBtn.action = #selector(tapRequestAccessibility)

        envSummaryLabel.font = .systemFont(ofSize: 12)
        envSummaryLabel.textColor = .secondaryLabelColor

        let testHeader = NSTextField(labelWithString: "빠릿한 한영 전환 테스트 입력창 (예: 한dud한dud 빠르게 입력)")
        testHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        testInputField.placeholderString = "여기에 한글과 영어를 번갈아 빠르게 입력해 보세요..."

        let stack = NSStackView(views: [
            enabledCheck,
            loginCheck,
            accessibilityStatusLabel,
            requestAccessibilityBtn,
            makeSeparator(),
            sectionTitle("자동 감지된 환경 요약"),
            envSummaryLabel,
            makeSeparator(),
            testHeader,
            testInputField,
        ])
        return wrapStack(stack)
    }

    private func buildTriggersTab() -> NSView {
        autoSystemCheck.target = self; autoSystemCheck.action = #selector(toggleAutoDetect)
        autoKarabinerCheck.target = self; autoKarabinerCheck.action = #selector(toggleAutoDetect)
        autoHangulCheck.target = self; autoHangulCheck.action = #selector(toggleAutoDetect)
        recordBtn.target = self; recordBtn.action = #selector(tapRecordTrigger)
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

        activeTriggersText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        activeTriggersText.textColor = .secondaryLabelColor
        optionalHIDNote.font = .systemFont(ofSize: 11)
        optionalHIDNote.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            sectionTitle("자동 호환 감지 (기존 설정을 건드리지 않음)"),
            autoSystemCheck,
            autoKarabinerCheck,
            autoHangulCheck,
            makeSeparator(),
            sectionTitle("추가 한영키 등록"),
            recordRow,
            presetRow,
            activeTriggersText,
            makeSeparator(),
            sectionTitle("로컬 편의 기능"),
            swapBackquoteCheck,
            escapeEnglishCheck,
            localHUDCheck,
            optionalHIDCheck,
            optionalHIDNote,
        ])
        return wrapStack(stack)
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
        pingPeerBtn.target = self; pingPeerBtn.action = #selector(tapPingPeer)
        copyTokenBtn.target = self; copyTokenBtn.action = #selector(tapCopyToken)
        pasteTokenBtn.target = self; pasteTokenBtn.action = #selector(tapPasteToken)
        refreshPeersBtn.target = self; refreshPeersBtn.action = #selector(tapRefreshPeers)
        clearTrustedBtn.target = self; clearTrustedBtn.action = #selector(tapClearTrusted)

        tailscaleStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        trustedPeersLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        trustedPeersLabel.textColor = .secondaryLabelColor
        remoteActionStatusLabel.font = .systemFont(ofSize: 11)
        remoteActionStatusLabel.textColor = .systemBlue

        let transportRow = NSStackView(views: [NSTextField(labelWithString: "전송 방식:"), transportPopup])
        transportRow.orientation = .horizontal; transportRow.spacing = 8

        let fallbackRow = NSStackView(views: [NSTextField(labelWithString: "미설치 원격지 폴백:"), fallbackPopup])
        fallbackRow.orientation = .horizontal; fallbackRow.spacing = 8

        let peerRow = NSStackView(views: [peerPopup, refreshPeersBtn])
        peerRow.orientation = .horizontal; peerRow.spacing = 8

        let actionRow = NSStackView(views: [pairDirectBtn, pingPeerBtn, copyTokenBtn, pasteTokenBtn])
        actionRow.orientation = .horizontal; actionRow.spacing = 6

        let stack = NSStackView(views: [
            tailscaleStatusLabel,
            remoteEnabledCheck,
            autoEnglishCheck,
            restoreBlurCheck,
            remoteHUDCheck,
            transportRow,
            fallbackRow,
            makeSeparator(),
            sectionTitle("Tailscale Mac 피어 및 암호화 페어링 (X25519 + 6자리 SAS)"),
            peerRow,
            actionRow,
            remoteActionStatusLabel,
            trustedPeersLabel,
            clearTrustedBtn,
        ])
        return wrapStack(stack)
    }

    private func buildDiagnosticsTab() -> NSView {
        diagSummaryLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        wakeTISBtn.target = self; wakeTISBtn.action = #selector(tapWakeTIS)
        clearLogBtn.target = self; clearLogBtn.action = #selector(tapClearDiagLog)

        let btnRow = NSStackView(views: [wakeTISBtn, clearLogBtn])
        btnRow.orientation = .horizontal; btnRow.spacing = 8

        diagTextView.isEditable = false
        diagTextView.isRichText = false
        diagTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let scroll = NSScrollView()
        scroll.documentView = diagTextView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let note = NSTextField(wrappingLabelWithString: "※ 이 탭이 열려 있는 동안만 키 코드/플래그 메타데이터가 화면에 표시되며, 입력 내용은 디스크에 저장되지 않습니다.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            sectionTitle("시스템 및 탭 상태"),
            diagSummaryLabel,
            btnRow,
            note,
            scroll,
        ])
        return wrapStack(stack)
    }

    private func wrapStack(_ stack: NSStackView) -> NSView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
        ])
        return container
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 12.5, weight: .semibold)
        return lbl
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 575).isActive = true
        return box
    }

    // MARK: - Actions

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
        remoteActionStatusLabel.stringValue = "\(ip)로 페어링 요청을 보냈습니다. 상대 Mac 화면에서 6자리 코드를 승인하세요."
        onInitiatePairing?(ip)
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
            remoteActionStatusLabel.stringValue = "페어링 토큰 생성 실패"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        remoteActionStatusLabel.stringValue = "내 페어링 토큰이 클립보드에 복사되었습니다. 다른 Mac에서 '상대 토큰 붙여넣기'를 누르세요."
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

    @objc private func tapClearDiagLog() {
        diagTextView.string = ""
    }
}

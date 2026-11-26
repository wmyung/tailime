import AppKit
import TailIMECore

/// Non-activating floating mini HUD panel shown briefly when switching languages on a remote Mac
/// (or optionally locally). Never steals keyboard focus from RustDesk or any active window.
final class HUDPanelController {
    private var panel: NSPanel?
    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    func showRemoteSwitch(hostName: String, language: InputLanguage?, rttMs: Double?, isFallback: Bool) {
        let badge: String
        let accent: NSColor
        if let language {
            badge = language.shortBadge
            accent = (language == .korean) ? NSColor.systemBlue : NSColor.systemGreen
        } else {
            badge = "⇄"
            accent = NSColor.systemOrange
        }

        let detail: String
        if isFallback {
            detail = "폴백 전송 (상태 미확인)"
        } else if let rttMs {
            detail = String(format: "원격 · %.1fms", rttMs)
        } else {
            detail = "원격"
        }

        present(badge: badge, title: hostName, detail: detail, badgeColor: accent)
    }

    func showLocalSwitch(language: InputLanguage) {
        let accent: NSColor = (language == .korean) ? .systemBlue : .systemGreen
        present(badge: language.shortBadge, title: language.displayName, detail: "로컬", badgeColor: accent)
    }

    private func present(badge: String, title: String, detail: String, badgeColor: NSColor) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let panel = self.ensurePanel()

            self.badgeLabel.stringValue = badge
            self.badgeLabel.textColor = .white
            self.badgeLabel.layer?.backgroundColor = badgeColor.cgColor

            self.titleLabel.stringValue = title
            self.detailLabel.stringValue = detail

            self.positionPanel(panel)
            self.hideWork?.cancel()

            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0.96
            }

            let work = DispatchWorkItem { [weak self] in
                guard let self, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.22
                    panel.animator().alphaValue = 0.0
                }, completionHandler: {
                    if panel.alphaValue < 0.05 {
                        panel.orderOut(nil)
                    }
                })
            }
            self.hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let width: CGFloat = 236
        let height: CGFloat = 54
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        badgeLabel.font = .systemFont(ofSize: 16, weight: .bold)
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 9
        badgeLabel.layer?.masksToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(badgeLabel)
        effect.addSubview(textStack)

        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            badgeLabel.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            badgeLabel.widthAnchor.constraint(equalToConstant: 42),
            badgeLabel.heightAnchor.constraint(equalToConstant: 32),

            textStack.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            textStack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])

        panel.contentView = effect
        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - panel.frame.width / 2.0
        let y = visible.maxY - panel.frame.height - 28.0
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

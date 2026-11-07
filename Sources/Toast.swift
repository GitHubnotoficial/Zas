import AppKit

/// Aviso breve al pie de la pantalla. No roba el foco ni hay que cerrarlo,
/// a diferencia de una alerta: quien está trabajando sigue en lo suyo.
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, seconds: Double = 2.8, large: Bool = false) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = large ? .systemFont(ofSize: 44) : .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = Palette.text
        label.alignment = .center
        label.sizeToFit()

        label.frame.size.width = min(label.frame.width, 480)
        let size = large ? CGSize(width: 96, height: 96) : CGSize(width: ceil(label.frame.width) + 36, height: 38)
        let visible = NSScreen.underMouse.visibleFrame
        let frame = CGRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: visible.minY + 76,
            width: size.width,
            height: size.height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = GlassView(frame: CGRect(origin: .zero, size: size), radius: large ? Design.radiusLarge : Design.radiusMedium)
        label.frame.origin = CGPoint(
            x: ((size.width - label.frame.width) / 2).rounded(),
            y: ((size.height - label.frame.height) / 2).rounded()
        )
        background.addSubview(label)
        panel.contentView = background

        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])

        // Sube un poco desde abajo, con el mismo resorte que el resto de la app.
        let target = frame
        let start = frame.offsetBy(dx: 0, dy: -14)
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        fade(panel, to: 1)
        Spring.run(step: { progress in
            panel.setFrame(start.moved(to: target, by: progress), display: true)
        })
        self.panel = panel

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fade(panel, to: 0)
            try? await Task.sleep(nanoseconds: UInt64((Design.fadeDuration + 0.02) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            if self?.panel === panel {
                self?.panel = nil
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = Design.fadeDuration
        panel.animator().alphaValue = alpha
        NSAnimationContext.endGrouping()
    }
}

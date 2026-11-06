import AppKit

/// Aviso breve al pie de la pantalla. No roba el foco ni hay que cerrarlo,
/// a diferencia de una alerta: quien está trabajando sigue en lo suyo.
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, seconds: Double = 2.8) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.sizeToFit()

        let size = CGSize(width: ceil(label.frame.width) + 36, height: 38)
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

        let background = GlassView(frame: CGRect(origin: .zero, size: size), radius: size.height / 2)
        label.frame.origin = CGPoint(x: 18, y: ((size.height - label.frame.height) / 2).rounded())
        background.addSubview(label)
        panel.contentView = background

        // Sube un poco desde abajo, con el mismo resorte que el resto de la app.
        let target = frame
        let start = frame.offsetBy(dx: 0, dy: -14)
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        fade(panel, to: 1, duration: 0.14)
        Spring.run(response: 0.32, damping: 0.8, step: { progress in
            panel.setFrame(start.moved(to: target, by: progress), display: true)
        })
        self.panel = panel

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fade(panel, to: 0, duration: 0.2)
            try? await Task.sleep(nanoseconds: 220_000_000)
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

    private func fade(_ panel: NSPanel, to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = duration
        panel.animator().alphaValue = alpha
        NSAnimationContext.endGrouping()
    }
}

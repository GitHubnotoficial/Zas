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
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let size = CGSize(width: ceil(label.frame.width) + 36, height: ceil(label.frame.height) + 20)
        let visible = NSScreen.underMouse.visibleFrame
        let frame = CGRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: visible.minY + 56,
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
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSView(frame: CGRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        background.layer?.cornerRadius = size.height / 2
        label.frame.origin = CGPoint(x: 18, y: ((size.height - label.frame.height) / 2).rounded())
        background.addSubview(label)
        panel.contentView = background

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            if self?.panel === panel {
                self?.panel = nil
            }
        }
    }
}

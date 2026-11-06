import AppKit

/// Capturas fijadas: flotan sobre todo, se mueven arrastrando y se cierran con la ×.
@MainActor
final class PinController: NSObject {
    private var panels: [NSPanel] = []

    func pin(_ image: NSImage) {
        let visible = NSScreen.underMouse.visibleFrame
        let ratio = min(
            1,
            visible.width * 0.5 / max(image.size.width, 1),
            visible.height * 0.5 / max(image.size.height, 1)
        )
        // La misma escala en ambos lados: una captura delgada no se deforma.
        let size = CGSize(
            width: max((image.size.width * ratio).rounded(), 1),
            height: max((image.size.height * ratio).rounded(), 1)
        )
        // Cada nueva se corre un poco para que no tape exacto a la anterior.
        let offset = CGFloat(panels.count % 6) * 24
        let frame = CGRect(
            x: visible.midX - size.width / 2 + offset,
            y: visible.midY - size.height / 2 - offset,
            width: size.width,
            height: size.height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.contentAspectRatio = size
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = PinView(frame: CGRect(origin: .zero, size: size), image: image)
        view.autoresizingMask = [.width, .height]

        let close = PinCloseButton(target: self, action: #selector(closePin(_:)))
        let circle = Design.Card.circleSize
        close.frame = CGRect(
            origin: CGPoint(x: Design.Card.gap, y: size.height - Design.Card.gap - circle.height),
            size: circle
        )
        close.autoresizingMask = [.maxXMargin, .minYMargin]
        close.isHidden = true
        view.addSubview(close)
        view.closeButton = close

        panel.contentView = view
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        panels.append(panel)
    }

    @objc private func closePin(_ sender: NSButton) {
        guard let window = sender.window else { return }
        window.orderOut(nil)
        panels.removeAll { $0 === window }
    }

    #if ZAS_TEST
    func closeAll() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    func simulateHover() {
        panels.compactMap { $0.contentView as? PinView }.forEach { $0.closeButton?.isHidden = false }
    }
    #endif
}

private final class PinCloseButton: NSButton {
    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cerrar")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Design.Card.symbolSize, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = Design.Card.ink
        toolTip = "Cerrar"
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = Design.Card.circleSize.height / 2
        layer?.backgroundColor = Design.Card.controlFill.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }
}

private final class PinView: NSView {
    private let image: NSImage
    weak var closeButton: NSButton?
    private var trackingArea: NSTrackingArea?

    init(frame: CGRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Design.Card.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        refreshBorder()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Captura fijada")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBorder()
    }

    private func refreshBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = Palette.hairline.cgColor
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton?.isHidden = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copiar", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Cerrar", action: #selector(closeButtonPressed), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    @objc private func closeButtonPressed() {
        closeButton?.performClick(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
    }
}

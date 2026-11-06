import AppKit

enum ThumbnailKind {
    case screenshot
    case video
    case text
}

/// Pila de miniaturas en la esquina. Cada captura nueva entra abajo y empuja a las demás,
/// para poder sacar varias seguidas y arrastrarlas o editarlas después.
@MainActor
final class ThumbnailController {
    var onAnnotate: ((NSImage, URL) -> Void)?
    var onPin: ((NSImage) -> Void)?

    private final class Item: @unchecked Sendable {
        let panel: NSPanel
        let view: ThumbnailView
        var timer: Timer?

        init(panel: NSPanel, view: ThumbnailView) {
            self.panel = panel
            self.view = view
        }
    }

    private let width: CGFloat = 224
    private let spacing: CGFloat = 10
    private let maximumItems = 4

    private var items: [Item] = []
    private var isSuspended = false
    private var screen: NSScreen?

    func show(image: NSImage, file: URL, kind: ThumbnailKind) {
        screen = NSScreen.underMouse

        let imageSize = image.size
        let aspect = max(imageSize.width, 1) / max(imageSize.height, 1)
        let height = min(max((width / aspect).rounded(), 96), 168)
        let size = CGSize(width: width, height: height)

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = ThumbnailView(
            frame: CGRect(origin: .zero, size: size),
            image: image,
            file: file,
            kind: kind
        )
        panel.contentView = view

        let item = Item(panel: panel, view: view)
        view.onClose = { [weak self, weak item] in
            guard let item else { return }
            self?.dismiss(item)
        }
        view.onAnnotate = { [weak self, weak item] in
            guard let self, let item else { return }
            self.dismiss(item)
            self.onAnnotate?(image, file)
        }
        view.onPin = { [weak self, weak item] in
            guard let self, let item else { return }
            self.dismiss(item)
            self.onPin?(image)
        }
        view.onHoldChanged = { [weak self, weak item] holding in
            guard let self, let item else { return }
            if holding {
                self.stopTimer(item)
            } else {
                self.startTimer(item)
            }
        }

        items.insert(item, at: 0)
        while items.count > maximumItems, let oldest = items.last {
            dismiss(oldest, animated: false)
        }

        let frame = frames()[0]
        panel.setFrame(frame.offsetBy(dx: 44, dy: 0), display: false)
        panel.alphaValue = 0
        if !isSuspended {
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        }
        layoutItems()
        startTimer(item)
    }

    /// Esconde la pila para que no salga en una captura.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for item in items {
            stopTimer(item)
            item.panel.orderOut(nil)
        }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for item in items {
            item.panel.orderFrontRegardless()
            startTimer(item)
        }
        layoutItems()
    }

    func dismissAll() {
        for item in items {
            dismiss(item, animated: false)
        }
    }

    private func dismiss(_ item: Item, animated: Bool = true) {
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        stopTimer(item)
        items.remove(at: index)

        let panel = item.panel
        if animated && !isSuspended {
            animate { panel.animator().alphaValue = 0 }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                panel.orderOut(nil)
            }
        } else {
            panel.orderOut(nil)
        }
        layoutItems()
    }

    private func frames() -> [CGRect] {
        let visible = (screen ?? NSScreen.underMouse).visibleFrame
        var y = visible.minY + 16
        return items.map { item in
            let size = item.panel.frame.size
            let frame = CGRect(x: visible.maxX - size.width - 16, y: y, width: size.width, height: size.height)
            y += size.height + spacing
            return frame
        }
    }

    private func layoutItems() {
        guard !isSuspended else { return }
        let targets = frames()
        animate {
            for (item, frame) in zip(items, targets) {
                item.panel.animator().setFrame(frame, display: true)
                item.panel.animator().alphaValue = 1
            }
        }
    }

    private func animate(_ changes: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.2
        NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeOut)
        changes()
        NSAnimationContext.endGrouping()
    }

    private func startTimer(_ item: Item) {
        stopTimer(item)
        let seconds = Settings.shared.thumbnailSeconds
        item.timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item else { return }
                self.dismiss(item)
            }
        }
    }

    private func stopTimer(_ item: Item) {
        item.timer?.invalidate()
        item.timer = nil
    }

    #if ZAS_TEST
    func simulateHover(index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].view.setHovering(true)
    }

    var visibleCount: Int { items.count }
    #endif
}

/// Botón redondo con un símbolo, para las acciones sobre la miniatura.
private final class OverlayIconButton: NSButton {
    init(symbol: String, tooltip: String, target: AnyObject, action: Selector) {
        super.init(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(configuration)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .white
        toolTip = tooltip
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    var onClose: (() -> Void)?
    var onHoldChanged: ((Bool) -> Void)?
    var onAnnotate: (() -> Void)?
    var onPin: (() -> Void)?

    private let image: NSImage
    private let file: URL
    private let kind: ThumbnailKind

    private var hovering = false
    private var mouseDownPoint: NSPoint?
    private var dragged = false
    private var trackingArea: NSTrackingArea?
    private var actionButtons: [NSButton] = []
    private var closeButton: NSButton?

    init(frame: CGRect, image: NSImage, file: URL, kind: ThumbnailKind) {
        self.image = image
        self.file = file
        self.kind = kind
        super.init(frame: frame)
        buildButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildButtons() {
        var buttons: [NSButton] = []
        switch kind {
        case .screenshot:
            buttons.append(OverlayIconButton(symbol: "pencil.tip", tooltip: "Anotar", target: self, action: #selector(annotate)))
            buttons.append(OverlayIconButton(symbol: "pin.fill", tooltip: "Fijar en pantalla", target: self, action: #selector(pin)))
            buttons.append(OverlayIconButton(symbol: "folder", tooltip: "Mostrar en Finder", target: self, action: #selector(reveal)))
        case .video:
            buttons.append(OverlayIconButton(symbol: "play.fill", tooltip: "Reproducir", target: self, action: #selector(open)))
            buttons.append(OverlayIconButton(symbol: "folder", tooltip: "Mostrar en Finder", target: self, action: #selector(reveal)))
        case .text:
            break
        }

        let gap: CGFloat = 8
        let total = CGFloat(buttons.count) * 34 + CGFloat(max(buttons.count - 1, 0)) * gap
        var x = (bounds.width - total) / 2
        for button in buttons {
            button.frame.origin = CGPoint(x: x.rounded(), y: ((bounds.height - 34) / 2).rounded())
            button.isHidden = true
            addSubview(button)
            x += 34 + gap
        }
        actionButtons = buttons

        let close = OverlayIconButton(symbol: "xmark", tooltip: "Cerrar", target: self, action: #selector(closeThumbnail))
        close.frame = CGRect(x: bounds.maxX - 28, y: bounds.maxY - 28, width: 22, height: 22)
        close.layer?.cornerRadius = 11
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cerrar")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        close.isHidden = true
        addSubview(close)
        closeButton = close
    }

    @objc private func annotate() { onAnnotate?() }
    @objc private func pin() { onPin?() }
    @objc private func closeThumbnail() { onClose?() }

    @objc private func open() {
        NSWorkspace.shared.open(file)
        onClose?()
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([file])
        onClose?()
    }

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
        setHovering(true)
        onHoldChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
        onHoldChanged?(false)
    }

    func setHovering(_ value: Bool) {
        hovering = value
        actionButtons.forEach { $0.isHidden = !value }
        closeButton?.isHidden = !value
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }

        dragged = true
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragged else { return }

        switch kind {
        case .screenshot: onAnnotate?()
        case .video: open()
        case .text: onClose?()
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        if operation != [] {
            onClose?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        NSColor(white: 0.09, alpha: 1).setFill()
        bounds.fill()

        // La imagen entra completa, sin deformarse.
        let imageSize = image.size
        let ratio = min(bounds.width / max(imageSize.width, 1), bounds.height / max(imageSize.height, 1))
        let drawn = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        image.draw(in: CGRect(
            x: (bounds.width - drawn.width) / 2,
            y: (bounds.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))

        if hovering {
            NSColor.black.withAlphaComponent(0.42).setFill()
            bounds.fill(using: .sourceOver)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.2).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        border.lineWidth = 1
        border.stroke()

        drawBadge(badgeText)
    }

    private var badgeText: String {
        switch kind {
        case .screenshot: return hovering ? "Clic para anotar" : "Copiado"
        case .video: return "Video copiado"
        case .text: return "Texto copiado"
        }
    }

    private func drawBadge(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let rect = CGRect(x: 8, y: 8, width: size.width + 16, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        string.draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 3), withAttributes: attributes)
    }
}

import AppKit

enum ThumbnailKind {
    case screenshot
    case video
    case text
}

/// Miniatura flotante en la esquina: confirma que se copió y se puede arrastrar a otra app.
/// Clic en una captura abre el editor; clic en un video lo reproduce.
@MainActor
final class ThumbnailController {
    var onAnnotate: ((NSImage, URL) -> Void)?
    var onPin: ((NSImage) -> Void)?

    private var panel: NSPanel?
    private var timer: Timer?
    private let visibleSeconds: TimeInterval = 6

    func show(image: NSImage, file: URL, kind: ThumbnailKind) {
        hide()

        let maxWidth: CGFloat = 260
        let maxHeight: CGFloat = 180
        let imageSize = image.size
        let ratio = min(maxWidth / max(imageSize.width, 1), maxHeight / max(imageSize.height, 1), 1)
        let size = CGSize(
            width: max((imageSize.width * ratio).rounded(), 130),
            height: max((imageSize.height * ratio).rounded(), 72)
        )

        let visible = NSScreen.underMouse.visibleFrame
        let frame = CGRect(
            x: visible.maxX - size.width - 16,
            y: visible.minY + 16,
            width: size.width,
            height: size.height
        )

        let panel = NSPanel(
            contentRect: frame,
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = ThumbnailView(
            frame: CGRect(origin: .zero, size: size),
            image: image,
            file: file,
            kind: kind
        )
        view.onClose = { [weak self] in self?.hide() }
        view.onAnnotate = { [weak self] in
            self?.hide()
            self?.onAnnotate?(image, file)
        }
        view.onPin = { [weak self] in
            self?.hide()
            self?.onPin?(image)
        }
        view.onHoldChanged = { [weak self] holding in
            if holding {
                self?.stopTimer()
            } else {
                self?.startTimer()
            }
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        self.panel = panel
        startTimer()
    }

    func hide() {
        stopTimer()
        panel?.orderOut(nil)
        panel = nil
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: visibleSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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

    init(frame: CGRect, image: NSImage, file: URL, kind: ThumbnailKind) {
        self.image = image
        self.file = file
        self.kind = kind
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var closeRect: CGRect {
        CGRect(x: bounds.maxX - 28, y: bounds.maxY - 28, width: 22, height: 22)
    }

    private var pinRect: CGRect {
        CGRect(x: 6, y: bounds.maxY - 28, width: 48, height: 22)
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
        hovering = true
        needsDisplay = true
        onHoldChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        onHoldChanged?(false)
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

        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point) {
            onClose?()
            return
        }
        switch kind {
        case .screenshot:
            if pinRect.contains(point) {
                onPin?()
            } else {
                onAnnotate?()
            }
        case .video:
            NSWorkspace.shared.open(file)
            onClose?()
        case .text:
            onClose?()
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
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.black.setFill()
        bounds.fill()
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.25).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        drawBadge(badgeText)

        if hovering {
            if kind == .screenshot {
                NSColor.black.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: pinRect, xRadius: 11, yRadius: 11).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let label = "Fijar" as NSString
                let labelSize = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(
                        x: pinRect.midX - labelSize.width / 2,
                        y: pinRect.midY - labelSize.height / 2
                    ),
                    withAttributes: attributes
                )
            }

            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(ovalIn: closeRect).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let mark = "×" as NSString
            let size = mark.size(withAttributes: attributes)
            mark.draw(
                at: NSPoint(
                    x: closeRect.midX - size.width / 2,
                    y: closeRect.midY - size.height / 2
                ),
                withAttributes: attributes
            )
        }
    }

    private var badgeText: String {
        switch kind {
        case .screenshot: return hovering ? "Clic para anotar" : "✓ Copiado"
        case .video: return "▶︎ Video copiado"
        case .text: return "✓ Texto copiado"
        }
    }

    private func drawBadge(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let rect = CGRect(x: 8, y: 8, width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        string.draw(at: NSPoint(x: rect.minX + 7, y: rect.minY + 3), withAttributes: attributes)
    }
}

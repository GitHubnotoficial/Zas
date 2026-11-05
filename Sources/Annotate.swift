import AppKit
import CoreImage

enum AnnotationTool: Int, CaseIterable {
    case arrow, rectangle, highlight, pencil, text, pixelate

    var label: String {
        switch self {
        case .arrow: return "Flecha"
        case .rectangle: return "Cuadro"
        case .highlight: return "Resaltar"
        case .pencil: return "Lápiz"
        case .text: return "Texto"
        case .pixelate: return "Pixelar"
        }
    }
}

/// Una marca sobre la imagen. Los puntos están en coordenadas de la imagen.
struct Annotation {
    var tool: AnnotationTool
    var color: NSColor
    var points: [CGPoint]
    var text: String = ""

    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
    }
}

/// Ventana de anotación. "Copiar" reemplaza el portapapeles y guarda una copia aparte.
@MainActor
final class AnnotationEditor: NSObject, NSWindowDelegate {
    var onFinish: ((NSImage, URL) -> Void)?
    var onClose: (() -> Void)?

    private let image: NSImage
    private let file: URL
    private let canvas: AnnotationCanvas
    private let window: NSWindow
    private let colorWell = NSColorWell(frame: .zero)
    private let previousApp = NSWorkspace.shared.frontmostApplication

    init(image: NSImage, file: URL) {
        self.image = image
        self.file = file

        let toolbarHeight: CGFloat = 48
        let minWidth: CGFloat = 720
        let visible = (NSScreen.underMouse.visibleFrame).insetBy(dx: 40, dy: 40)
        let fit = min(
            1,
            visible.width / max(image.size.width, 1),
            (visible.height - toolbarHeight - 30) / max(image.size.height, 1)
        )
        let canvasSize = CGSize(
            width: (image.size.width * fit).rounded(),
            height: (image.size.height * fit).rounded()
        )
        let contentSize = CGSize(
            width: max(canvasSize.width, minWidth),
            height: canvasSize.height + toolbarHeight
        )

        canvas = AnnotationCanvas(
            frame: CGRect(
                x: ((contentSize.width - canvasSize.width) / 2).rounded(),
                y: 0,
                width: canvasSize.width,
                height: canvasSize.height
            ),
            image: image
        )
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Anotar captura"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        let content = NSView(frame: CGRect(origin: .zero, size: contentSize))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(canvas)
        buildToolbar(in: content, y: canvasSize.height, height: toolbarHeight)
        window.contentView = content
    }

    private func buildToolbar(in content: NSView, y: CGFloat, height: CGFloat) {
        let tools = NSSegmentedControl(
            labels: AnnotationTool.allCases.map(\.label),
            trackingMode: .selectOne,
            target: self,
            action: #selector(toolChanged(_:))
        )
        tools.selectedSegment = 0
        tools.sizeToFit()
        tools.frame.origin = CGPoint(x: 12, y: y + (height - tools.frame.height) / 2)
        content.addSubview(tools)

        colorWell.color = .systemRed
        colorWell.colorWellStyle = .minimal
        colorWell.frame = CGRect(x: tools.frame.maxX + 10, y: y + (height - 26) / 2, width: 38, height: 26)
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        content.addSubview(colorWell)

        let copy = NSButton(title: "Copiar", target: self, action: #selector(copyAndClose))
        copy.keyEquivalent = "\r"
        copy.sizeToFit()
        copy.frame.origin = CGPoint(
            x: content.bounds.maxX - copy.frame.width - 12,
            y: y + (height - copy.frame.height) / 2
        )
        content.addSubview(copy)

        let undo = NSButton(title: "Deshacer", target: self, action: #selector(undoLast))
        undo.keyEquivalent = "z"
        undo.keyEquivalentModifierMask = [.command]
        undo.sizeToFit()
        undo.frame.origin = CGPoint(
            x: copy.frame.minX - undo.frame.width - 6,
            y: y + (height - undo.frame.height) / 2
        )
        content.addSubview(undo)
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        canvas.commitText()
        canvas.tool = AnnotationTool(rawValue: sender.selectedSegment) ?? .arrow
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.color = sender.color
    }

    @objc private func undoLast() {
        canvas.undo()
    }

    @objc private func copyAndClose() {
        canvas.commitText()
        guard let data = canvas.exportPNG() else { return }

        let name = file.deletingPathExtension().lastPathComponent + " anotada.png"
        let output = Capture.folder.appendingPathComponent(name)
        guard (try? data.write(to: output)) != nil,
              let copied = Capture.copyImage(at: output)
        else { return }

        window.close()
        previousApp?.activate(options: [])
        onFinish?(copied, output)
    }

    func windowWillClose(_ notification: Notification) {
        NSColorPanel.shared.orderOut(nil)
        onClose?()
    }
}

private final class AnnotationCanvas: NSView {
    var tool: AnnotationTool = .arrow
    var color: NSColor = .systemRed

    private let image: NSImage
    private lazy var pixelated: NSImage? = AnnotationCanvas.makePixelated(image)
    private var annotations: [Annotation] = []
    private var current: Annotation?
    private var textField: NSTextField?
    private var textPoint: CGPoint = .zero

    init(frame: CGRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    private var displayScale: CGFloat {
        bounds.width / max(image.size.width, 1)
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / displayScale, y: point.y / displayScale)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        let point = imagePoint(for: event)
        if tool == .text {
            beginText(at: point)
        } else {
            current = Annotation(tool: tool, color: color, points: [point])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var annotation = current, let first = annotation.points.first else { return }
        let point = imagePoint(for: event)
        annotation.points = tool == .pencil ? annotation.points + [point] : [first, point]
        current = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let annotation = current else { return }
        current = nil
        if annotation.points.count > 1 {
            annotations.append(annotation)
        }
        needsDisplay = true
    }

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    private func beginText(at point: CGPoint) {
        textPoint = point
        let scale = displayScale
        let field = NSTextField(frame: CGRect(
            x: min(point.x * scale, bounds.maxX - 240),
            y: min(point.y * scale, bounds.maxY - 32),
            width: 240,
            height: 30
        ))
        field.font = .boldSystemFont(ofSize: 18)
        field.placeholderString = "Escribe y pulsa Enter"
        field.target = self
        field.action = #selector(textEntered)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    @objc private func textEntered() {
        commitText()
    }

    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !text.isEmpty {
            annotations.append(Annotation(tool: .text, color: color, points: [textPoint], text: text))
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: displayScale, y: displayScale)
        renderContents()
        context.restoreGState()
    }

    /// Dibuja en coordenadas de la imagen. Se usa tanto en pantalla como al exportar.
    private func renderContents() {
        image.draw(in: CGRect(origin: .zero, size: image.size))
        for annotation in annotations {
            render(annotation)
        }
        if let current {
            render(current)
        }
    }

    private func render(_ annotation: Annotation) {
        switch annotation.tool {
        case .arrow:
            renderArrow(annotation)
        case .rectangle:
            annotation.color.setStroke()
            let path = NSBezierPath(roundedRect: annotation.rect, xRadius: 4, yRadius: 4)
            path.lineWidth = 4
            path.stroke()
        case .highlight:
            NSColor.systemYellow.withAlphaComponent(0.4).setFill()
            NSBezierPath(rect: annotation.rect).fill()
        case .pencil:
            renderPencil(annotation)
        case .text:
            renderText(annotation)
        case .pixelate:
            guard let pixelated else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: annotation.rect).addClip()
            pixelated.draw(in: CGRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func renderArrow(_ annotation: Annotation) {
        guard annotation.points.count > 1 else { return }
        let start = annotation.points[0]
        let end = annotation.points[1]
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 20
        let headAngle: CGFloat = 0.45

        annotation.color.set()

        let line = NSBezierPath()
        line.lineWidth = 4
        line.lineCapStyle = .round
        line.move(to: start)
        line.line(to: CGPoint(
            x: end.x - cos(angle) * headLength * 0.8,
            y: end.y - sin(angle) * headLength * 0.8
        ))
        line.stroke()

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(
            x: end.x - cos(angle - headAngle) * headLength,
            y: end.y - sin(angle - headAngle) * headLength
        ))
        head.line(to: CGPoint(
            x: end.x - cos(angle + headAngle) * headLength,
            y: end.y - sin(angle + headAngle) * headLength
        ))
        head.close()
        head.fill()
    }

    private func renderPencil(_ annotation: Annotation) {
        guard let first = annotation.points.first else { return }
        annotation.color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        annotation.points.dropFirst().forEach { path.line(to: $0) }
        path.stroke()
    }

    private func renderText(_ annotation: Annotation) {
        guard let point = annotation.points.first else { return }
        // Borde blanco para que el texto se lea sobre cualquier fondo.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: annotation.color,
            .strokeColor: NSColor.white,
            .strokeWidth: -3,
        ]
        (annotation.text as NSString).draw(at: point, withAttributes: attributes)
    }

    func exportPNG() -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: cgImage.width,
                  pixelsHigh: cgImage.height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(
            x: CGFloat(cgImage.width) / image.size.width,
            y: CGFloat(cgImage.height) / image.size.height
        )
        renderContents()
        NSGraphicsContext.restoreGraphicsState()

        // Se asigna al final para no alterar la escala del dibujo de arriba.
        bitmap.size = image.size
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func makePixelated(_ image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let source = CIImage(cgImage: cgImage)
        let blockSize = max(CGFloat(cgImage.width) / image.size.width, 1) * 12
        guard let filter = CIFilter(
            name: "CIPixellate",
            parameters: [kCIInputImageKey: source, kCIInputScaleKey: blockSize]
        ),
            let output = filter.outputImage?.cropped(to: source.extent),
            let result = CIContext().createCGImage(output, from: source.extent)
        else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }
}

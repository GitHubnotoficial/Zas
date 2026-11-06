import AppKit

/// Lienzo del editor: muestra la imagen, recibe el dibujo y exporta el resultado.
final class AnnotationCanvas: NSView {
    var tool: AnnotationTool = .arrow {
        didSet {
            selectedIndex = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var color: NSColor = .systemRed {
        didSet { applyToSelection { $0.color = color } }
    }

    var lineWidth: CGFloat = 5 {
        didSet { applyToSelection { $0.lineWidth = lineWidth } }
    }

    var onHistoryChanged: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onRequestCopy: (() -> Void)?
    var onToolShortcut: ((AnnotationTool) -> Void)?

    private let image: NSImage
    private lazy var pixelated: NSImage? = AnnotationRenderer.makePixelated(image)

    private(set) var document = AnnotationDocument()
    private var undoStack: [AnnotationDocument] = []
    private var redoStack: [AnnotationDocument] = []

    private var current: Annotation?
    private var cropDraft: CGRect?
    private var selectedIndex: Int?
    private var dragOrigin: CGPoint?
    private var dragStartDocument: AnnotationDocument?
    private var dragStartPoint: CGPoint?

    private var textField: NSTextField?
    private var textPoint: CGPoint = .zero

    init(frame: CGRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Parte de la imagen visible, en coordenadas de la imagen.
    private var contentRect: CGRect {
        document.crop ?? CGRect(origin: .zero, size: image.size)
    }

    private var displayScale: CGFloat {
        let content = contentRect
        return min(bounds.width / max(content.width, 1), bounds.height / max(content.height, 1), 1)
    }

    /// Dónde se dibuja el contenido dentro del lienzo.
    private var displayRect: CGRect {
        let content = contentRect
        let scale = displayScale
        let width = content.width * scale
        let height = content.height * scale
        return CGRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: ((bounds.height - height) / 2).rounded(),
            width: width,
            height: height
        )
    }

    private func imagePoint(fromView point: CGPoint) -> CGPoint {
        let content = contentRect
        let display = displayRect
        let scale = displayScale
        return CGPoint(
            x: content.minX + (point.x - display.minX) / scale,
            y: content.minY + (point.y - display.minY) / scale
        )
    }

    private func viewPoint(fromImage point: CGPoint) -> CGPoint {
        let content = contentRect
        let display = displayRect
        let scale = displayScale
        return CGPoint(
            x: display.minX + (point.x - content.minX) * scale,
            y: display.minY + (point.y - content.minY) * scale
        )
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        imagePoint(fromView: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        addCursorRect(displayRect, cursor: tool == .select ? .arrow : .crosshair)
    }

    // MARK: - Historial

    private func pushUndo(_ state: AnnotationDocument) {
        undoStack.append(state)
        redoStack.removeAll()
        onHistoryChanged?()
    }

    private func mutate(_ change: (inout AnnotationDocument) -> Void) {
        let before = document
        change(&document)
        if document != before {
            pushUndo(before)
        }
        needsDisplay = true
    }

    private func applyToSelection(_ change: (inout Annotation) -> Void) {
        guard let selectedIndex, document.annotations.indices.contains(selectedIndex) else { return }
        pushUndo(document)
        change(&document.annotations[selectedIndex])
        needsDisplay = true
    }

    @objc func undo(_ sender: Any?) {
        // Con texto a medio escribir, deshacer solo descarta ese texto.
        if let field = textField {
            textField = nil
            field.removeFromSuperview()
            window?.makeFirstResponder(self)
            return
        }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        selectedIndex = nil
        documentGeometryChanged()
    }

    @objc func redo(_ sender: Any?) {
        commitText()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        selectedIndex = nil
        documentGeometryChanged()
    }

    private func documentGeometryChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onHistoryChanged?()
    }

    @objc func copy(_ sender: Any?) {
        onRequestCopy?()
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection()
    }

    private func deleteSelection() {
        guard let index = selectedIndex, document.annotations.indices.contains(index) else { return }
        selectedIndex = nil
        mutate { $0.annotations.remove(at: index) }
    }

    func add(_ annotation: Annotation) {
        mutate { $0.annotations.append(annotation) }
    }

    func applyCrop(_ rect: CGRect) {
        mutate { $0.crop = rect }
        documentGeometryChanged()
    }

    // MARK: - Ratón

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let point = imagePoint(for: event)

        switch tool {
        case .select:
            selectedIndex = document.annotations.indices.last { document.annotations[$0].hitTest(point) }
            dragOrigin = point
            dragStartPoint = point
            dragStartDocument = document
            needsDisplay = true
        case .text:
            beginText(at: point)
        case .counter:
            add(Annotation(
                tool: .counter,
                color: color,
                lineWidth: lineWidth,
                points: [point],
                number: document.nextCounter
            ))
        case .crop:
            cropDraft = CGRect(origin: point, size: .zero)
            dragOrigin = point
        default:
            current = Annotation(tool: tool, color: color, lineWidth: lineWidth, points: [point])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var point = imagePoint(for: event)

        if tool == .select {
            guard let selectedIndex, let origin = dragOrigin else { return }
            document.annotations[selectedIndex].translate(dx: point.x - origin.x, dy: point.y - origin.y)
            dragOrigin = point
            needsDisplay = true
            return
        }

        if tool == .crop {
            guard let origin = dragOrigin else { return }
            cropDraft = CGRect(
                x: min(origin.x, point.x),
                y: min(origin.y, point.y),
                width: abs(point.x - origin.x),
                height: abs(point.y - origin.y)
            ).intersection(contentRect)
            needsDisplay = true
            return
        }

        guard var annotation = current, let first = annotation.points.first else { return }
        if event.modifierFlags.contains(.shift), annotation.tool != .pencil {
            point = Self.constrained(point, from: first, tool: annotation.tool)
        }
        annotation.points = annotation.tool == .pencil ? annotation.points + [point] : [first, point]
        current = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .select {
            if let before = dragStartDocument, let start = dragStartPoint,
               imagePoint(for: event) != start, document != before {
                pushUndo(before)
            }
            dragStartDocument = nil
            dragStartPoint = nil
            dragOrigin = nil
            return
        }

        if tool == .crop {
            defer {
                cropDraft = nil
                dragOrigin = nil
                needsDisplay = true
            }
            if let draft = cropDraft, draft.width >= 8, draft.height >= 8 {
                applyCrop(draft.integral)
            }
            return
        }

        guard let annotation = current else { return }
        current = nil
        let isMeaningful: Bool
        switch annotation.tool {
        case .pencil:
            isMeaningful = annotation.points.count > 1
        default:
            let rect = annotation.rect
            isMeaningful = annotation.points.count > 1 && max(rect.width, rect.height) >= 3
        }
        if isMeaningful {
            add(annotation)
        } else {
            needsDisplay = true
        }
    }

    /// Mayúsculas: flechas a múltiplos de 45° y figuras con lados iguales.
    private static func constrained(_ point: CGPoint, from origin: CGPoint, tool: AnnotationTool) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        if tool == .arrow {
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: origin.x + (dx < 0 ? -side : side), y: origin.y + (dy < 0 ? -side : side))
    }

    // MARK: - Teclado

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty

        if plain, event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection()
            return
        }
        if plain, event.keyCode == 53 {
            if selectedIndex != nil {
                selectedIndex = nil
                needsDisplay = true
            } else {
                onRequestClose?()
            }
            return
        }
        if plain, let characters = event.charactersIgnoringModifiers?.uppercased(),
           let match = AnnotationTool.allCases.first(where: { $0.key == characters }) {
            onToolShortcut?(match)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Texto

    private func beginText(at point: CGPoint) {
        textPoint = point
        let origin = viewPoint(fromImage: point)
        let fontSize = (12 + lineWidth * 2.4) * displayScale

        let field = NSTextField(frame: CGRect(
            x: max(0, min(origin.x, bounds.maxX - 260)),
            y: max(0, min(origin.y, bounds.maxY - fontSize - 12)),
            width: 260,
            height: fontSize + 12
        ))
        field.font = .systemFont(ofSize: fontSize, weight: .bold)
        field.textColor = color
        field.placeholderString = "Escribe y pulsa Enter"
        field.isBordered = true
        field.focusRingType = .none
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
        // Devuelve el teclado al lienzo: si no, ⌘Z, Supr y las teclas de herramienta dejan de responder.
        window?.makeFirstResponder(self)
        if !text.isEmpty {
            add(Annotation(tool: .text, color: color, lineWidth: lineWidth, points: [textPoint], text: text))
        }
    }

    // MARK: - Dibujo

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let display = displayRect
        let content = contentRect
        let scale = displayScale

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: display, xRadius: 6, yRadius: 6).addClip()
        context.translateBy(x: display.minX, y: display.minY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -content.minX, y: -content.minY)

        renderContents()
        if let current {
            AnnotationRenderer.draw(current, pixelated: pixelated, imageSize: image.size)
        }
        if let selectedIndex, document.annotations.indices.contains(selectedIndex) {
            drawSelection(document.annotations[selectedIndex], scale: scale)
        }
        if let cropDraft {
            drawCropDraft(cropDraft, content: content, scale: scale)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func renderContents() {
        image.draw(in: CGRect(origin: .zero, size: image.size))
        for annotation in document.annotations {
            AnnotationRenderer.draw(annotation, pixelated: pixelated, imageSize: image.size)
        }
    }

    private func drawSelection(_ annotation: Annotation, scale: CGFloat) {
        let path = NSBezierPath(rect: annotation.bounds.insetBy(dx: -6, dy: -6))
        path.lineWidth = 1.5 / scale
        path.setLineDash([5 / scale, 4 / scale], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawCropDraft(_ draft: CGRect, content: CGRect, scale: CGFloat) {
        let dim = NSBezierPath(rect: content)
        dim.append(NSBezierPath(rect: draft))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: draft)
        border.lineWidth = 1.5 / scale
        border.stroke()
    }

    // MARK: - Exportar

    func exportPNG() -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let content = contentRect
        let pixelsPerPoint = CGFloat(cgImage.width) / max(image.size.width, 1)
        let width = Int((content.width * pixelsPerPoint).rounded())
        let height = Int((content.height * pixelsPerPoint).rounded())

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
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
        context.cgContext.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        context.cgContext.translateBy(x: -content.minX, y: -content.minY)
        renderContents()
        NSGraphicsContext.restoreGraphicsState()

        // Se asigna al final para no alterar la escala del dibujo de arriba.
        bitmap.size = content.size
        return bitmap.representation(using: .png, properties: [:])
    }
}

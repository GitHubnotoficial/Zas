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
    var onRequestSave: (() -> Void)?
    var onRequestZoom: ((Int) -> Void)?
    var onToolShortcut: ((AnnotationTool) -> Void)?

    private let original: NSImage
    private var image: NSImage { document.base ?? original }
    /// Una versión pixelada por cada intensidad usada.
    private var pixelatedVersions: [String: NSImage] = [:]

    private func pixelated(block: CGFloat, smooth: Bool) -> NSImage? {
        let key = "\(ObjectIdentifier(image).hashValue)-\(block)-\(smooth)"
        if let cached = pixelatedVersions[key] {
            return cached
        }
        let version = AnnotationRenderer.makePixelated(image, block: block, smooth: smooth)
        pixelatedVersions[key] = version
        return version
    }

    var filled = false
    var plainLine = false
    var smoothBlur = false

    private enum DragMode {
        case none
        case move(last: CGPoint)
        case resize(anchor: CGPoint, original: Annotation, start: CGPoint)
    }

    var pixelBrush = false
    var blockSize: CGFloat = 14 {
        didSet { applyToSelection { $0.blockSize = blockSize } }
    }
    private var dragMode = DragMode.none

    private(set) var document = AnnotationDocument()
    private var undoStack: [AnnotationDocument] = []
    private var redoStack: [AnnotationDocument] = []

    private var current: Annotation?
    private var cropDraft: CGRect?
    private var selectedIndex: Int?
    private var dragOrigin: CGPoint?
    private var dragStartDocument: AnnotationDocument?

    private var textField: NSTextField?
    private var textPoint: CGPoint = .zero

    init(frame: CGRect, image: NSImage) {
        original = image
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var historyCount: Int { undoStack.count }

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
        var updated = document
        change(&updated.annotations[selectedIndex])
        // Volver a pulsar el mismo color no debe ocupar un paso de deshacer.
        guard updated != document else { return }
        pushUndo(document)
        document = updated
        needsDisplay = true
    }

    /// Hay algo que se perdería al cerrar sin copiar.
    var hasUnsavedMarks: Bool {
        if canUndo {
            return true
        }
        let pending = textField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !pending.isEmpty
    }

    func cancelTextEntry() {
        discardText()
    }

    private func discardText() {
        guard let field = textField else { return }
        textField = nil
        field.abortEditing()
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    @objc func undo(_ sender: Any?) {
        // Con texto a medio escribir, deshacer solo descarta ese texto.
        if textField != nil {
            discardText()
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

    /// Lo recién creado queda seleccionado para moverlo o cambiarle el tamaño.
    func add(_ annotation: Annotation) {
        mutate { $0.annotations.append(annotation) }
        if !annotation.isFreehand || annotation.tool == .pixelate {
            selectedIndex = document.annotations.count - 1
        }
    }

    var selectionForTesting: Int? { selectedIndex }

    /// Cambia la imagen entera con las marcas ya integradas. Se puede deshacer.
    func applyImage(_ transform: (NSImage) -> NSImage?) {
        commitText()
        guard let data = exportPNG(), let flattened = NSImage(data: data), let result = transform(flattened) else { return }
        selectedIndex = nil
        mutate {
            $0.base = result
            $0.annotations = []
            $0.crop = nil
        }
        documentGeometryChanged()
    }

    /// Pone otra imagen encima de la captura, lista para moverla.
    func addPicture(_ picture: NSImage, at center: CGPoint? = nil) {
        let content = contentRect
        let ratio = min(1, content.width * 0.5 / max(picture.size.width, 1), content.height * 0.5 / max(picture.size.height, 1))
        let size = CGSize(width: picture.size.width * ratio, height: picture.size.height * ratio)
        let middle = center ?? CGPoint(x: content.midX, y: content.midY)
        add(Annotation(
            tool: .picture,
            color: .clear,
            lineWidth: 1,
            points: [
                CGPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2),
                CGPoint(x: middle.x + size.width / 2, y: middle.y + size.height / 2),
            ],
            picture: picture
        ))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        NSImage.canInit(with: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let picture = NSImage(pasteboard: sender.draggingPasteboard) else { return false }
        addPicture(picture, at: imagePoint(fromView: convert(sender.draggingLocation, from: nil)))
        return true
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

        // Doble clic en un texto: se vuelve a escribir.
        if event.clickCount == 2, let index = document.annotations.indices.last(where: {
            document.annotations[$0].tool == .text && document.annotations[$0].hitTest(point)
        }) {
            editText(at: index)
            return
        }
        if beginDrag(at: point) {
            return
        }

        selectedIndex = nil
        needsDisplay = true

        switch tool {
        case .select:
            break
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
            current = Annotation(
                tool: tool,
                color: color,
                lineWidth: lineWidth,
                points: [point],
                pixelBrush: tool == .pixelate && pixelBrush,
                blockSize: blockSize,
                filled: filled,
                plainLine: plainLine,
                smoothBlur: smoothBlur
            )
        }
    }

    /// Empieza a mover o a cambiar de tamaño. Devuelve `false` si no había nada bajo el cursor.
    /// Como en los estados de WhatsApp: lo último que se creó queda listo para acomodarlo.
    @discardableResult
    func beginDrag(at point: CGPoint) -> Bool {
        if let index = selectedIndex, document.annotations.indices.contains(index) {
            let mark = document.annotations[index]
            let corners = Self.corners(of: mark.bounds)
            if let corner = corners.indices.first(where: { hypot(corners[$0].x - point.x, corners[$0].y - point.y) <= handleReach }) {
                dragMode = .resize(anchor: corners[(corner + 2) % 4], original: mark, start: corners[corner])
                dragStartDocument = document
                return true
            }
            if mark.bounds.insetBy(dx: -6, dy: -6).contains(point) {
                dragMode = .move(last: point)
                dragStartDocument = document
                return true
            }
        }
        guard tool == .select,
              let hit = document.annotations.indices.last(where: { document.annotations[$0].hitTest(point) })
        else { return false }
        selectedIndex = hit
        dragMode = .move(last: point)
        dragStartDocument = document
        needsDisplay = true
        return true
    }

    func continueDrag(to point: CGPoint) {
        guard let index = selectedIndex, document.annotations.indices.contains(index) else { return }
        switch dragMode {
        case .none:
            return
        case .move(let last):
            document.annotations[index].translate(dx: point.x - last.x, dy: point.y - last.y)
            dragMode = .move(last: point)
        case .resize(let anchor, let original, let start):
            var updated = original
            let width = start.x - anchor.x
            let height = start.y - anchor.y
            updated.scale(
                from: anchor,
                x: abs(width) > 1 ? (point.x - anchor.x) / width : 1,
                y: abs(height) > 1 ? (point.y - anchor.y) / height : 1
            )
            document.annotations[index] = updated
        }
        needsDisplay = true
    }

    func endDrag() {
        if let before = dragStartDocument, document != before {
            pushUndo(before)
        }
        dragStartDocument = nil
        dragMode = .none
    }

    private var handleReach: CGFloat { 9 / max(displayScale, 0.01) }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    private func editText(at index: Int) {
        let mark = document.annotations[index]
        mutate { $0.annotations.remove(at: index) }
        selectedIndex = nil
        let previousWidth = lineWidth
        let previousColor = color
        lineWidth = mark.lineWidth
        color = mark.color
        beginText(at: mark.points.first ?? .zero)
        textField?.stringValue = mark.text
        lineWidth = previousWidth
        color = previousColor
    }

    override func mouseDragged(with event: NSEvent) {
        var point = imagePoint(for: event)

        if case .none = dragMode {
            // Nada que mover: sigue el dibujo normal.
        } else {
            continueDrag(to: point)
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
        let freehand = annotation.isFreehand
        if event.modifierFlags.contains(.shift), !freehand {
            point = Self.constrained(point, from: first, tool: annotation.tool)
        }
        annotation.points = freehand ? annotation.points + [point] : [first, point]
        current = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .none = dragMode {
            // Sigue abajo.
        } else {
            endDrag()
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
        if annotation.isFreehand {
            isMeaningful = annotation.points.count > 1
        } else {
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]) == .command,
              window?.firstResponder === self
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "s": onRequestSave?()
        case "+", "=": onRequestZoom?(1)
        case "-": onRequestZoom?(-1)
        case "0": onRequestZoom?(0)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

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
        // El texto blanco o amarillo no se leería sobre el fondo blanco del campo.
        field.drawsBackground = true
        field.backgroundColor = Self.isLight(color) ? NSColor(white: 0.15, alpha: 1) : .white
        field.placeholderString = "Escribe y pulsa Enter"
        field.isBordered = true
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(textEntered)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    private static func isLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent * 0.3 + rgb.greenComponent * 0.59 + rgb.blueComponent * 0.11 > 0.6
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
        NSBezierPath(roundedRect: display, xRadius: 10, yRadius: 10).addClip()
        context.translateBy(x: display.minX, y: display.minY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -content.minX, y: -content.minY)

        renderContents(including: current)
        if let selectedIndex, document.annotations.indices.contains(selectedIndex) {
            drawSelection(document.annotations[selectedIndex], scale: scale)
        }
        if let cropDraft {
            drawCropDraft(cropDraft, content: content, scale: scale)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Las marcas van en una capa aparte: el borrador las quita sin tocar la captura.
    private func renderContents(including draft: Annotation? = nil) {
        image.draw(in: CGRect(origin: .zero, size: image.size))
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for annotation in document.annotations + (draft.map { [$0] } ?? []) {
            let version = annotation.tool == .pixelate ? pixelated(block: annotation.blockSize, smooth: annotation.smoothBlur) : nil
            AnnotationRenderer.draw(annotation, pixelated: version, imageSize: image.size)
        }
        context.endTransparencyLayer()
    }

    private func drawSelection(_ annotation: Annotation, scale: CGFloat) {
        let path = NSBezierPath(rect: annotation.bounds)
        path.lineWidth = 1.5 / scale
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        let radius = 5 / scale
        for corner in Self.corners(of: annotation.bounds) {
            let handle = NSBezierPath(ovalIn: CGRect(x: corner.x - radius, y: corner.y - radius, width: radius * 2, height: radius * 2))
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5 / scale
            handle.stroke()
        }
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

extension AnnotationCanvas: NSTextFieldDelegate {
    /// Esc mientras se escribe descarta ese texto, sin cerrar el editor.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelTextEntry()
        return true
    }
}

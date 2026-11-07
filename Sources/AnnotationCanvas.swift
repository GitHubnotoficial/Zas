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

    var color: NSColor = Palette.markDefault {
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

    /// Aire que se deja alrededor de la imagen al ajustarla al lienzo.
    var fitInset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private let original: NSImage
    private var image: NSImage { document.base ?? original }
    /// Una versión pixelada por cada intensidad usada.
    private var pixelatedVersions: [String: NSImage] = [:]
    private var pixelatedSource: NSImage?
    private var pendingPixelated: Set<String> = []

    /// `live` es para la pantalla: si esa versión aún no existe se calcula aparte y se pinta al llegar,
    /// porque difuminar una captura grande tarda cientos de milisegundos. Exportar siempre espera.
    private func pixelated(block: CGFloat, smooth: Bool, live: Bool) -> NSImage? {
        // Cada versión pesa tanto como la captura: pocas, y solo de la imagen actual.
        if pixelatedSource !== image || pixelatedVersions.count >= 6 {
            pixelatedVersions.removeAll()
            pixelatedSource = image
        }
        let key = "\(block)-\(smooth)"
        if let cached = pixelatedVersions[key] {
            return cached
        }
        if live {
            requestPixelated(key: key, block: block, smooth: smooth)
            return nil
        }
        let version = AnnotationRenderer.makePixelated(image, block: block, smooth: smooth)
        pixelatedVersions[key] = version
        return version
    }

    private func requestPixelated(key: String, block: CGFloat, smooth: Bool) {
        let source = image
        guard !pendingPixelated.contains(key),
              let pixels = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        pendingPixelated.insert(key)
        let box = Unchecked(value: pixels)
        let size = source.size
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Unchecked(value: AnnotationRenderer.pixelated(box.value, pointWidth: size.width, block: block, smooth: smooth))
            }.value
            guard let self else { return }
            self.pendingPixelated.remove(key)
            guard self.pixelatedSource === source, let version = result.value else { return }
            self.pixelatedVersions[key] = NSImage(cgImage: version, size: size)
            self.needsDisplay = true
        }
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
    private var textStyle: (color: NSColor, width: CGFloat) = (Palette.markDefault, 5)
    private var editedMark: Annotation?
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

    /// Todo lo que se ve y se exporta: el contenido y, si lo hay, el fondo que lo rodea.
    /// El fondo crece hacia afuera, así que la imagen y las marcas conservan sus coordenadas.
    private var outputRect: CGRect {
        guard let backdrop = document.backdrop else { return contentRect }
        return backdrop.layout(content: contentRect, edge: edgeInfo).outer
    }

    private var displayScale: CGFloat {
        let output = outputRect
        let room = bounds.insetBy(dx: fitInset, dy: fitInset)
        let across: CGFloat = max(room.width, 1) / max(output.width, 1)
        let down: CGFloat = max(room.height, 1) / max(output.height, 1)
        return max(min(across, down, 1), 0.01)
    }

    /// Escala de la imagen en el lienzo, sin contar el zoom.
    var fitScale: CGFloat { displayScale }

    /// Dónde se dibuja el resultado dentro del lienzo.
    private var displayRect: CGRect {
        let output = outputRect
        let scale = displayScale
        let width = output.width * scale
        let height = output.height * scale
        return CGRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: ((bounds.height - height) / 2).rounded(),
            width: width,
            height: height
        )
    }

    private func imagePoint(fromView point: CGPoint) -> CGPoint {
        let output = outputRect
        let display = displayRect
        let scale = displayScale
        return CGPoint(
            x: output.minX + (point.x - display.minX) / scale,
            y: output.minY + (point.y - display.minY) / scale
        )
    }

    private func viewPoint(fromImage point: CGPoint) -> CGPoint {
        let output = outputRect
        let display = displayRect
        let scale = displayScale
        return CGPoint(
            x: display.minX + (point.x - output.minX) * scale,
            y: display.minY + (point.y - output.minY) * scale
        )
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        imagePoint(fromView: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        // Con fondo solo se dibuja sobre la captura, no sobre el margen.
        let content = contentRect
        let scale = displayScale
        let area = CGRect(
            origin: viewPoint(fromImage: content.origin),
            size: CGSize(width: content.width * scale, height: content.height * scale)
        )
        addCursorRect(area, cursor: tool == .select ? .arrow : .crosshair)
    }

    /// La ventana y el panel Fondo cambian el tamaño del lienzo.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Fondo

    private var edgeCache: (image: NSImage, crop: CGRect, info: EdgeInfo)?
    private var blurCache: (image: NSImage, crop: CGRect, blurred: NSImage?)?
    private var pictureCache: (data: Data, picture: NSImage?)?
    /// Documento de antes de empezar a mover un deslizador del panel Fondo.
    private var backdropStart: AnnotationDocument?

    private var edgeInfo: EdgeInfo {
        let content = contentRect
        if let edgeCache, edgeCache.image === image, edgeCache.crop == content {
            return edgeCache.info
        }
        let info = ImageTools.edgeInfo(of: image, crop: content)
        edgeCache = (image, content, info)
        return info
    }

    private var blurredBackdrop: NSImage? {
        let content = contentRect
        if let blurCache, blurCache.image === image, blurCache.crop == content {
            return blurCache.blurred
        }
        let blurred = ImageTools.blurredBackdrop(of: image, crop: content)
        blurCache = (image, content, blurred)
        return blurred
    }

    private func backdropPicture(_ data: Data?) -> NSImage? {
        guard let data else { return nil }
        if let pictureCache, pictureCache.data == data {
            return pictureCache.picture
        }
        let picture = NSImage(data: data)
        pictureCache = (data, picture)
        return picture
    }

    /// La captura actual sin marcas: de ella sale la muestra de difuminado del panel.
    var currentImage: NSImage { image }

    /// Lee el color del borde aparte. Con esto, elegir el primer fondo no frena el dibujo.
    func prewarmBackdrop() {
        let owner = image
        let content = contentRect
        if let edgeCache, edgeCache.image === owner, edgeCache.crop == content { return }
        let box = Unchecked(value: owner)
        Task { @MainActor [weak self] in
            let info = await Task.detached(priority: .userInitiated) {
                ImageTools.edgeInfo(of: box.value, crop: content)
            }.value
            guard let self, self.image === owner, self.contentRect == content else { return }
            self.edgeCache = (owner, content, info)
        }
    }

    /// Cambia el fondo sin tocar la imagen ni las marcas.
    /// Mientras un deslizador se mueve, `finished` es `false` y todo cuenta como un solo paso de deshacer.
    func setBackdrop(_ backdrop: Backdrop?, finished: Bool = true) {
        commitTextField()
        if backdropStart == nil {
            backdropStart = document
        }
        document.backdrop = backdrop
        if finished {
            finishBackdropEdit()
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func finishBackdropEdit() {
        guard let start = backdropStart else { return }
        backdropStart = nil
        if document != start {
            pushUndo(start)
        }
    }

    // MARK: - Historial

    /// Cambia con cada edición, también al deshacer. Sirve para saber si hay algo sin guardar.
    private(set) var revision = 0

    private func pushUndo(_ state: AnnotationDocument) {
        revision += 1
        undoStack.append(state)
        redoStack.removeAll()
        onHistoryChanged?()
    }

    private func mutate(_ change: (inout AnnotationDocument) -> Void) {
        finishBackdropEdit()
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
        // Cancelar la edición de un texto lo devuelve como estaba.
        if let original = editedMark {
            editedMark = nil
            add(original)
        }
    }

    var hasPendingText: Bool {
        !(textField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    @objc func undo(_ sender: Any?) {
        // Con texto a medio escribir, deshacer solo descarta ese texto.
        if textField != nil {
            discardText()
            return
        }
        finishBackdropEdit()
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
        revision += 1
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

    func load(_ saved: AnnotationDocument) {
        document = saved
        documentGeometryChanged()
    }

    /// Proyecto editable con la imagen y cada marca por separado.
    func projectData() -> Data? {
        guard let project = ZasProject(image: image, document: document) else { return nil }
        return try? JSONEncoder().encode(project)
    }

    /// Cambia la imagen entera con las marcas ya integradas. Se puede deshacer.
    /// El fondo queda aparte: sigue siendo editable y se recompone alrededor del resultado.
    func applyImage(_ transform: (NSImage) -> NSImage?) {
        commitText()
        guard let data = exportPNG(includingBackdrop: false), let flattened = NSImage(data: data), let result = transform(flattened) else { return }
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

        // Lo que se dibuje fuera de la captura quedaría recortado: sobre el margen no se empieza nada.
        if document.backdrop != nil, !contentRect.contains(point) {
            return
        }

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
            let before = document.annotations[index]
            document.annotations[index].translate(dx: point.x - last.x, dy: point.y - last.y)
            dragMode = .move(last: point)
            invalidate(before, document.annotations[index])
        case .resize(let anchor, let original, let start):
            let before = document.annotations[index]
            var updated = original
            let width = start.x - anchor.x
            let height = start.y - anchor.y
            updated.scale(
                from: anchor,
                x: abs(width) > 1 ? (point.x - anchor.x) / width : 1,
                y: abs(height) > 1 ? (point.y - anchor.y) / height : 1
            )
            document.annotations[index] = updated
            invalidate(before, updated)
        }
    }

    /// Solo se repinta lo que tocan las marcas: con doscientas, redibujar el lienzo entero pierde cuadros.
    private func invalidate(_ first: Annotation, _ second: Annotation) {
        // El foco oscurece toda la imagen.
        guard first.tool != .spotlight else {
            needsDisplay = true
            return
        }
        setNeedsDisplay(viewArea(of: first).union(viewArea(of: second)))
    }

    /// Lo que ocupa una marca en el lienzo, con su grosor, su punta y los tiradores de selección.
    private func viewArea(of mark: Annotation) -> CGRect {
        var area = mark.bounds
        if mark.tool == .arrow {
            area = area.union(CGRect(origin: mark.arrowControl, size: .zero))
        }
        let scale = displayScale
        let reach = mark.lineWidth * 3 + 16 + 14 / scale
        area = area.insetBy(dx: -reach, dy: -reach)
        return CGRect(origin: viewPoint(fromImage: area.origin), size: CGSize(width: area.width * scale, height: area.height * scale))
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
        selectedIndex = nil
        mutate { $0.annotations.remove(at: index) }
        editedMark = mark
        beginText(at: mark.points.first ?? .zero, width: mark.lineWidth, color: mark.color)
        textField?.stringValue = mark.text
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
        let before = annotation
        let freehand = annotation.isFreehand
        if event.modifierFlags.contains(.shift), !freehand {
            point = Self.constrained(point, from: first, tool: annotation.tool)
        }
        annotation.points = freehand ? annotation.points + [point] : [first, point]
        current = annotation
        invalidate(before, annotation)
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
        // Una tecla muerta, como el acento, llega vacía: la herramienta Imagen tampoco tiene letra.
        if plain, let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty,
           let match = AnnotationTool.allCases.first(where: { $0.key == characters }) {
            onToolShortcut?(match)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Texto

    private func beginText(at point: CGPoint, width: CGFloat? = nil, color: NSColor? = nil) {
        let lineWidth = width ?? self.lineWidth
        let color = color ?? self.color
        textPoint = point
        textStyle = (color, lineWidth)
        let origin = viewPoint(fromImage: point)
        let fontSize = (12 + lineWidth * 2.4) * displayScale

        let field = NSTextField(frame: CGRect(
            x: max(0, min(origin.x, bounds.maxX - 260)),
            y: max(0, min(origin.y, bounds.maxY - fontSize - 12)),
            width: 260,
            height: fontSize + 12
        ))
        field.font = Annotation.markFont(ofSize: fontSize)
        field.textColor = color
        // Se escribe directamente sobre la captura, sin caja, igual que quedará.
        field.drawsBackground = false
        field.placeholderString = "Escribe y pulsa Enter"
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
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
        finishBackdropEdit()
        commitTextField()
    }

    private func commitTextField() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        // Devuelve el teclado al lienzo: si no, ⌘Z, Supr y las teclas de herramienta dejan de responder.
        window?.makeFirstResponder(self)
        if !text.isEmpty {
            add(Annotation(tool: .text, color: textStyle.color, lineWidth: textStyle.width, points: [textPoint], text: text))
            editedMark = nil
        } else if let original = editedMark {
            editedMark = nil
            add(original)
        }
    }

    // MARK: - Dibujo

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let display = displayRect
        let content = contentRect
        let output = outputRect
        let scale = displayScale

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: display).addClip()
        context.translateBy(x: display.minX, y: display.minY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -output.minX, y: -output.minY)

        renderContents(including: current, live: true)
        if let selectedIndex, document.annotations.indices.contains(selectedIndex) {
            drawSelection(document.annotations[selectedIndex], scale: scale)
        }
        if let cropDraft {
            drawCropDraft(cropDraft, content: content, scale: scale)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Las marcas van en una capa aparte: el borrador las quita sin tocar la captura.
    private func renderContents(including draft: Annotation? = nil, withBackdrop: Bool = true, live: Bool = false) {
        guard withBackdrop, let backdrop = document.backdrop else {
            renderCapture(including: draft, live: live)
            return
        }
        let content = contentRect
        let edge = edgeInfo
        BackdropArt.compose(
            backdrop,
            layout: backdrop.layout(content: content, edge: edge),
            content: content,
            edge: edge,
            blurred: backdrop.kind == .ownBlur ? blurredBackdrop : nil,
            picture: backdropPicture(backdrop.picture)
        ) {
            renderCapture(including: draft, live: live)
        }
    }

    private func renderCapture(including draft: Annotation?, live: Bool) {
        image.draw(in: CGRect(origin: .zero, size: image.size))
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for annotation in document.annotations + (draft.map { [$0] } ?? []) {
            let version = annotation.tool == .pixelate ? pixelated(block: annotation.blockSize, smooth: annotation.smoothBlur, live: live) : nil
            AnnotationRenderer.draw(annotation, pixelated: version, imageSize: image.size)
        }
        context.endTransparencyLayer()
    }

    private func drawSelection(_ annotation: Annotation, scale: CGFloat) {
        let path = NSBezierPath(rect: annotation.bounds)
        path.lineWidth = 1.5 / scale
        Palette.accent.setStroke()
        path.stroke()
        let radius = 4.5 / scale
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

    /// Exporta lo que se ve. Sin el fondo, sale solo la captura con sus marcas.
    func exportPNG(includingBackdrop: Bool = true) -> Data? {
        exportBitmap(includingBackdrop: includingBackdrop)?.representation(using: .png, properties: [:])
    }

    /// El resultado sin codificar: lo lento es el PNG, y ese paso se puede hacer fuera del hilo principal.
    func exportBitmap(includingBackdrop: Bool = true) -> NSBitmapImageRep? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let frame = includingBackdrop ? outputRect : contentRect
        let pixelsPerPoint = CGFloat(cgImage.width) / max(image.size.width, 1)
        let width = Int((frame.width * pixelsPerPoint).rounded())
        let height = Int((frame.height * pixelsPerPoint).rounded())

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
        context.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
        renderContents(withBackdrop: includingBackdrop)
        NSGraphicsContext.restoreGraphicsState()

        // Se asigna al final para no alterar la escala del dibujo de arriba.
        bitmap.size = frame.size
        return bitmap
    }

    /// Lo que se lee al seleccionar texto: el mismo resultado, para mostrarlo y para reconocerlo.
    func textSnapshot() -> (image: NSImage, pixels: CGImage)? {
        guard let bitmap = exportBitmap(), let pixels = bitmap.cgImage else { return nil }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return (image, pixels)
    }

    #if ZAS_TEST
    func testViewPoint(fromImage point: CGPoint) -> CGPoint { viewPoint(fromImage: point) }
    func testImagePoint(fromView point: CGPoint) -> CGPoint { imagePoint(fromView: point) }
    #endif
}

extension AnnotationCanvas: NSTextFieldDelegate {
    /// Esc mientras se escribe descarta ese texto, sin cerrar el editor.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelTextEntry()
        return true
    }
}

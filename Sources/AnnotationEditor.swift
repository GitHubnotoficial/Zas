import AppKit
import VisionKit

/// Punto de color en la paleta.
private final class DotButton: ReactiveButton {
    var dotColor: NSColor? {
        didSet { needsDisplay = true }
    }
    private let dotDiameter: CGFloat

    var isActive = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor?, diameter: CGFloat, tooltip: String, target: AnyObject, action: Selector) {
        dotColor = color
        dotDiameter = diameter
        super.init(frame: CGRect(x: 0, y: 0, width: 26, height: 26))
        title = ""
        isBordered = false
        toolTip = tooltip
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if isActive {
            Palette.accent.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2
            ring.stroke()
        }
        if isPressed || isHovering {
            (isPressed ? Palette.pressed : Palette.hover).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
        (dotColor ?? Palette.text).setFill()
        let radius = dotDiameter / 2
        let dot = NSBezierPath(ovalIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: dotDiameter,
            height: dotDiameter
        ))
        dot.fill()
        // Contorno visible: si no, el blanco desaparece sobre la barra clara.
        Palette.hairline.setStroke()
        dot.lineWidth = Design.lineWidth
        dot.stroke()
    }
}

/// Muestra de "Cualquier color". `NSColorWell` le resta 26 a cada canal en modo claro, dentro de un popover,
/// y dejaría de coincidir con los puntos de la paleta. Abre el mismo panel de colores del sistema.
private final class ColorSwatch: ReactiveButton {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(frame: CGRect, color: NSColor, tooltip: String, target: AnyObject, action: Selector) {
        self.color = color
        super.init(frame: frame)
        title = ""
        isBordered = false
        toolTip = tooltip
        self.target = target
        self.action = action
        setAccessibilityLabel(tooltip)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath.continuous(in: bounds.insetBy(dx: 0.25, dy: 0.25), radius: Design.radiusSmall)
        color.setFill()
        shape.fill()
        if isPressed || isHovering {
            (isPressed ? Palette.pressed : Palette.hover).setFill()
            shape.fill()
        }
        Palette.hairline.setStroke()
        shape.lineWidth = Design.lineWidth
        shape.stroke()
    }
}

/// Análisis de Live Text. La imagen se amplía igual que para copiar y se piden los mismos idiomas:
/// sin eso, un Mac en inglés leería peor las tildes y una captura 1x perdería letras.
@MainActor
enum LiveText {
    private static let analyzer = ImageAnalyzer()

    static func analysis(of image: NSImage) async -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported,
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let box = Unchecked(value: source)
        let large = await Task.detached(priority: .userInitiated) {
            Unchecked(value: TextReader.enlarged(box.value))
        }.value
        var configuration = ImageAnalyzer.Configuration([.text])
        configuration.locales = TextReader.languages
        return try? await analyzer.analyze(large.value, orientation: .up, configuration: configuration)
    }
}

/// Imagen con Live Text: el texto se selecciona sobre la captura, igual que en Fotos o Vista Previa.
///
/// La capa de Apple reparte sus cajas sobre todo su propio tamaño. Si es más grande que la imagen,
/// como pasaba con una tira de menú en una ventana alta, cada palabra se resalta mucho más alta que
/// su texto. Por eso imagen y capa miden lo mismo que la imagen en el lienzo: ni un punto más.
@MainActor
private final class LiveTextPane: NSView {
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()

    /// `area` es donde el lienzo pinta la imagen: se queda en su sitio, sin agrandarse al entrar.
    init(frame: CGRect, image: NSImage, area: CGRect) {
        super.init(frame: frame)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)

        overlay.preferredInteractionTypes = .textSelection
        overlay.selectableItemsHighlighted = true
        // El botón de Live Text del sistema sobra: Zas ya tiene el suyo en la barra.
        overlay.isSupplementaryInterfaceHidden = true
        // Sin esto, las zonas de texto se reparten mal y el arrastre no selecciona nada.
        overlay.trackingImageView = imageView
        addSubview(overlay)
        place(in: area)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func place(in area: CGRect) {
        imageView.frame = area
        overlay.frame = area
        overlay.setContentsRectNeedsUpdate()
    }

    /// Tapa el lienzo: las dos imágenes juntas se verían dobles.
    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill()
        dirtyRect.fill()
    }

    /// La capa de Apple deja pasar lo que no es texto. Aquí se queda: en este modo no se dibuja.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}

    /// Devuelve `false` si este Mac no ofrece Live Text.
    func analyze() async -> Bool {
        guard let image = imageView.image, let analysis = await LiveText.analysis(of: image) else { return false }
        overlay.analysis = analysis
        return true
    }

    var imageScaling: NSImageScaling { imageView.imageScaling }

    #if ZAS_TEST
    var testImageFrame: CGRect { imageView.frame }
    var testOverlayFrame: CGRect { overlay.frame }
    /// Qué ve de verdad la capa de Apple: si tiene análisis, su rectángulo y si hay texto en `point`.
    func testOverlayReport(at point: CGPoint) -> String {
        let local = convert(point, to: overlay)
        let found = overlay.analysis?.hasResults(for: .text) ?? false
        return "análisis \(overlay.analysis != nil), con texto \(found), contenido \(overlay.contentsRect), capa \(overlay.frame), en la ventana \(overlay.window != nil), oculta \(overlay.isHidden), texto en punto \(overlay.hasInteractiveItem(at: local))"
    }
    #endif
}

/// La barra comparte fila con los semáforos, una zona donde el título puede quedarse con el clic.
/// La ventana entrega directamente a cada control de la barra lo que le toca.
private final class EditorWindow: NSWindow {
    weak var topBar: NSView?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, attachedSheet == nil, let topBar,
           let point = topBar.superview?.convert(event.locationInWindow, from: nil),
           let control = topBar.hitTest(point) as? NSControl {
            if !isKeyWindow {
                makeKey()
            }
            control.mouseDown(with: event)
            return
        }
        super.sendEvent(event)
    }
}

/// Fondo liso y neutro de la ventana.
private final class EditorSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

/// Contenido del popover de estilo: se llena de arriba abajo y mide lo que ocupa.
private final class StyleStack: NSView {
    override var isFlipped: Bool { true }
}

/// Velo de la herramienta activa. Va en su propia capa para tener esquinas continuas y deslizarse.
private final class ActiveMarker: NSView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Design.radiusSmall
        layer?.cornerCurve = .continuous
        refreshColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    private func refreshColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.activeVeil.cgColor
        }
    }

    // Decoración: el clic es de la herramienta que hay encima.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Las ocho herramientas, sin fondo ni separadores. Cada una ocupa siempre el mismo sitio:
/// lo único que se mueve al elegir otra es el cuadrado activo.
private final class ToolStrip: NSView {
    private var items: [PillControl] = []
    private let marker = ActiveMarker(frame: CGRect(x: 0, y: 0, width: Design.toolSize, height: Design.toolSize))
    private var slide: Timer?
    private var hasActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        marker.isHidden = true
        addSubview(marker)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func add(_ item: PillControl) {
        item.paintsActiveVeil = false
        item.frame.origin = CGPoint(x: CGFloat(items.count) * Design.toolSize, y: 0)
        items.append(item)
        addSubview(item)
        frame.size = CGSize(width: CGFloat(items.count) * Design.toolSize, height: Design.toolSize)
    }

    /// `nil` cuando la herramienta vive fuera de la tira, como Recortar.
    func highlight(_ item: PillControl?) {
        slide?.invalidate()
        guard let item else {
            hasActive = false
            marker.isHidden = true
            return
        }
        let target = item.frame.minX
        marker.isHidden = false
        // Al volver de Recortar no hay de dónde deslizarse.
        guard hasActive else {
            hasActive = true
            marker.frame.origin.x = target
            return
        }
        let start = marker.frame.minX
        slide = Spring.run(response: Design.slideResponse, step: { [weak self] progress in
            self?.marker.frame.origin.x = start + (target - start) * progress
        })
    }

    #if ZAS_TEST
    var testItemFrames: [CGRect] { items.map(\.frame) }
    var testMarkerFrame: CGRect? { marker.isHidden ? nil : marker.frame }
    #endif
}

/// Barra superior o inferior. Una línea fina las separa del lienzo.
private final class EditorBar: NSView {
    private let lineAtBottom: Bool

    init(frame: CGRect, lineAtBottom: Bool) {
        self.lineAtBottom = lineAtBottom
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    // La barra de arriba es también el título: desde ahí se mueve la ventana.
    override var mouseDownCanMoveWindow: Bool { lineAtBottom }

    override func draw(_ dirtyRect: NSRect) {
        (lineAtBottom ? Palette.window : Palette.bottomBar).setFill()
        NSBezierPath(rect: bounds).fill()
        Palette.hairline.setFill()
        NSBezierPath(rect: CGRect(
            x: 0,
            y: lineAtBottom ? 0 : bounds.height - Design.lineWidth,
            width: bounds.width,
            height: Design.lineWidth
        )).fill()
    }
}

/// Avisa cuando cambia de tamaño, para que el lienzo siga llenando el espacio.
private final class CanvasScrollView: NSScrollView {
    var onResize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

/// Con poco zoom la imagen queda en el centro, no pegada a una esquina.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width {
            rect.origin.x = (document.width - rect.width) / 2
        }
        if rect.height > document.height {
            rect.origin.y = (document.height - rect.height) / 2
        }
        return rect
    }
}

/// Píldora "Arrástrame": al arrastrarla, el archivo con las marcas sale hacia otra app.
private final class DragPill: NSView, NSDraggingSource {
    var fileProvider: (() -> URL?)?

    /// Miniatura real de la captura, como el icono de un documento en su ventana.
    var proxy: NSImage? {
        didSet { needsDisplay = true }
    }

    private var start: CGPoint?
    private var dragged = false
    private var isHovering = false
    private var hoverArea: NSTrackingArea?

    override init(frame: CGRect) {
        super.init(frame: frame)
        toolTip = "Arrastra la imagen a otra app"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Arrastrar la imagen a otra app")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: start == nil ? .openHand : .closedHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        dragged = false
        needsDisplay = true
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        dragged = true

        guard let url = fileProvider?(), let image = NSImage(contentsOf: url) else { return }
        let ratio = min(220 / max(image.size.width, 1), 160 / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(
            CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            contents: image
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // Tocarla, una o dos veces, no hace nada: solo responde al arrastre.
    override func mouseUp(with event: NSEvent) {
        start = nil
        needsDisplay = true
        NSCursor.openHand.set()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        start = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath.continuous(in: bounds, radius: Design.radiusSmall)
        if start != nil {
            Palette.pressed.setFill()
            shape.fill()
        } else if isHovering {
            Palette.hover.setFill()
            shape.fill()
        }

        // La propia captura delante del texto: lo que se ve es lo que se arrastra.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: Palette.secondaryText,
        ]
        let title = "Arrástrame" as NSString
        let size = title.size(withAttributes: attributes)
        let side = Design.dragProxySize
        let gap: CGFloat = 6
        var x = (bounds.midX - (side + gap + size.width) / 2).rounded()
        drawProxy(in: CGRect(x: x, y: (bounds.midY - side / 2).rounded(), width: side, height: side))
        x += side + gap
        title.draw(at: CGPoint(x: x, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    /// La imagen llena el cuadrado y recorta lo que sobra. El filo la separa de una barra del mismo color.
    private func drawProxy(in rect: CGRect) {
        guard let proxy, proxy.size.width > 0, proxy.size.height > 0 else { return }
        let shape = NSBezierPath.continuous(in: rect, radius: Design.dragProxyRadius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        let ratio = max(rect.width / proxy.size.width, rect.height / proxy.size.height)
        let drawn = CGSize(width: proxy.size.width * ratio, height: proxy.size.height * ratio)
        proxy.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        Palette.hairline.setStroke()
        shape.lineWidth = Design.lineWidth
        shape.stroke()
    }
}

/// Ventana de anotación. "Listo" reemplaza el portapapeles, guarda una copia y cierra.
@MainActor
final class AnnotationEditor: NSObject, NSWindowDelegate, NSPopoverDelegate {
    var onFinish: ((NSImage, URL) -> Void)?
    var onClose: (() -> Void)?

    /// Las ocho casillas de la barra. Varias herramientas comparten casilla, pero cada una
    /// conserva su tecla: R y O son Forma, X y F son Ocultar, P y H son Dibujar.
    private enum ToolSlot: Int, CaseIterable {
        case select, arrow, shape, text, counter, hide, draw, eraser

        var title: String {
            switch self {
            case .select: return "\(AnnotationTool.select.label) (V)"
            case .arrow: return "\(AnnotationTool.arrow.label) (A)"
            case .shape: return "Forma (R, O)"
            case .text: return "\(AnnotationTool.text.label) (T)"
            case .counter: return "\(AnnotationTool.counter.label) (N)"
            case .hide: return "Ocultar (X, F)"
            case .draw: return "Dibujar (P, H)"
            case .eraser: return "\(AnnotationTool.eraser.label) (E)"
            }
        }

        /// Las que reúnen variantes: pulsarlas de nuevo abre el estilo.
        var hasVariants: Bool {
            self == .shape || self == .hide || self == .draw
        }
    }

    /// Variantes de Forma. La línea es la herramienta de flecha sin su punta.
    private enum ShapeKind: Int, CaseIterable {
        case box, filled, circle, line

        var label: String {
            switch self {
            case .box: return "Cuadro"
            case .filled: return "Relleno"
            case .circle: return "Círculo"
            case .line: return "Línea"
            }
        }

        var symbol: String {
            switch self {
            case .box: return "rectangle"
            case .filled: return "rectangle.fill"
            case .circle: return "circle"
            case .line: return "line.diagonal"
            }
        }
    }

    /// Variantes de Ocultar.
    private enum HideKind: Int, CaseIterable {
        case pixelate, blur, focus

        var label: String {
            switch self {
            case .pixelate: return "Pixelado"
            case .blur: return "Desenfoque"
            case .focus: return "Foco"
            }
        }

        var symbol: String {
            switch self {
            case .pixelate: return "eye.slash"
            case .blur: return "drop"
            case .focus: return AnnotationTool.spotlight.symbol
            }
        }
    }

    /// Ancho del botón Estilo: su punto de color y la flecha que avisa del popover.
    private static let styleWidth: CGFloat = 44

    private static let palette = Palette.inks
    private static let markers = Palette.highlighters
    /// Mínimo, máximo y valor inicial del tamaño de cada herramienta.
    private static let sizes: [AnnotationTool: (CGFloat, CGFloat, CGFloat)] = [
        .arrow: (2, 24, 5), .rectangle: (1, 24, 4), .ellipse: (1, 24, 4), .pencil: (1, 40, 5),
        .highlight: (6, 60, 22), .text: (1, 24, 5), .counter: (1, 24, 5), .eraser: (6, 90, 28),
        .pixelate: (8, 90, 30),
    ]
    /// Sobrevive al editor: lo fijado sigue en pantalla aunque se cierre esta ventana.
    private static let pins = PinController()

    private let image: NSImage
    private let file: URL
    let canvas: AnnotationCanvas
    private let scrollView: CanvasScrollView
    private let window: EditorWindow
    private let backgroundPanel: BackgroundPanel
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private let targetScreen: NSScreen

    private var slotButtons: [ToolSlot: PillControl] = [:]
    private var cropButton: PillControl?
    private var backgroundButton: PillControl?
    private let toolStrip = ToolStrip()
    private var styleButton: PillControl?
    private var chosenShape = ShapeKind.box
    private var chosenHide = HideKind.pixelate
    private var chosenDraw = AnnotationTool.pencil
    private var zoomPill: PillControl?
    private var undoButton: PillControl?
    private var redoButton: PillControl?
    private var textButton: PillControl?
    private var liveText: LiveTextPane?
    private var escapeMonitor: Any?

    private var stylePopover: NSPopover?
    private var popoverClosed: Date?

    private var panelOpen = false
    private var panelProgress: CGFloat = 0
    private var panelSpring: Timer?
    private var zoomSpring: Timer?
    private var sharePicker: NSSharingServicePicker?
    private var pathExport: (revision: Int, url: URL)?
    /// "Listo" ya está codificando: un segundo Enter no debe guardar dos veces.
    private var isFinishing = false

    private var sizeValue: ValueChip?
    private weak var anySwatch: ColorSwatch?
    private var dragPill: DragPill?
    /// De qué imagen sale la miniatura de Arrástrame: rotar o recortar crea otra.
    private var proxySource: NSImage?
    private var penColor = Palette.markDefault
    private var markerColor = AnnotationEditor.markers[0].1
    private var toolSizes: [AnnotationTool: CGFloat] = [:]
    private var savedRevision = 0
    private var magnifyObserver: NSObjectProtocol?

    init(image: NSImage, file: URL) {
        self.image = image
        self.file = file

        // Una barra arriba y otra abajo. Nada flota encima de la captura.
        let bars = Design.editorBar + Design.editorBottomBar
        let padding: CGFloat = 24
        let minimumWidth: CGFloat = 980
        let minimumHeight: CGFloat = 420

        let screen = NSScreen.underMouse
        targetScreen = screen
        let visible = screen.visibleFrame.insetBy(dx: 40, dy: 30)
        let fit = min(
            1,
            (visible.width - padding * 2) / max(image.size.width, 1),
            (visible.height - bars - padding * 2) / max(image.size.height, 1)
        )
        let imageWidth = (image.size.width * fit).rounded()
        let imageHeight = (image.size.height * fit).rounded()
        let contentSize = CGSize(
            width: max(imageWidth + padding * 2, minimumWidth),
            height: max(imageHeight + padding * 2 + bars, minimumHeight)
        )

        let area = CGRect(x: 0, y: Design.editorBottomBar, width: contentSize.width, height: contentSize.height - bars)
        canvas = AnnotationCanvas(frame: CGRect(origin: .zero, size: area.size), image: image)
        scrollView = CanvasScrollView(frame: area)
        backgroundPanel = BackgroundPanel(frame: CGRect(x: -BackgroundPanel.width, y: Design.editorBottomBar, width: BackgroundPanel.width, height: area.height))
        window = EditorWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        canvas.fitInset = padding

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Palette.window
        window.title = "Anotar captura"
        window.autorecalculatesKeyViewLoop = true
        window.minSize = CGSize(width: minimumWidth, height: minimumHeight)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 8

        backgroundPanel.isHidden = true
        backgroundPanel.autoresizingMask = [.height, .maxXMargin]

        let content = EditorSurface(frame: CGRect(origin: .zero, size: contentSize))
        content.addSubview(scrollView)
        content.addSubview(backgroundPanel)
        buildTopBar(in: content)
        buildBottomBar(in: content)
        window.contentView = content

        for (tool, size) in Self.sizes {
            toolSizes[tool] = size.2
        }

        canvas.onHistoryChanged = { [weak self] in self?.documentChanged() }
        canvas.onRequestClose = { [weak self] in self?.window.performClose(nil) }
        canvas.onRequestCopy = { [weak self] in self?.quickCopy() }
        canvas.onRequestSave = { [weak self] in self?.saveCopy() }
        canvas.onRequestZoom = { [weak self] step in self?.zoom(by: step) }
        canvas.onToolShortcut = { [weak self] tool in self?.pick(tool) }

        backgroundPanel.onChange = { [weak self] backdrop, finished in
            guard let self else { return }
            self.canvas.setBackdrop(backdrop, finished: finished)
            self.refreshZoomLabel()
        }
        backgroundPanel.onPickPicture = { [weak self] in self?.pickBackdropPicture() }

        scrollView.onResize = { [weak self] in self?.fitCanvas() }
        fitCanvas()

        // Cambia con cada cuadro del zoom, también al pellizcar: la etiqueta sigue al gesto.
        scrollView.contentView.postsBoundsChangedNotifications = true
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshZoomLabel()
            }
        }

        select(tool: .arrow)
        documentChanged()
    }

    // MARK: - Barras

    /// Tres grupos: la imagen junto a los semáforos, las herramientas al centro y, a la derecha,
    /// el estilo y la única acción con relleno de la barra.
    private func buildTopBar(in content: NSView) {
        let barHeight = Design.editorBar
        let bar = EditorBar(
            frame: CGRect(x: 0, y: content.bounds.height - barHeight, width: content.bounds.width, height: barHeight),
            lineAtBottom: true
        )
        bar.autoresizingMask = [.width, .minYMargin]
        let size = Design.controlSize

        // Empieza después de los semáforos.
        var x: CGFloat = 84
        func place(_ view: NSView) {
            view.frame.origin = CGPoint(x: x, y: ((barHeight - view.frame.height) / 2).rounded())
            bar.addSubview(view)
            x += view.frame.width + 4
        }

        let crop = PillControl(
            content: .symbol(AnnotationTool.crop.symbol),
            width: size,
            tooltip: "\(AnnotationTool.crop.label) (\(AnnotationTool.crop.key))",
            target: self,
            action: #selector(cropPressed)
        )
        place(crop)
        cropButton = crop
        place(PillControl(content: .symbol("rotate.right"), width: size, tooltip: "Imagen: rotar, voltear, tamaño", target: self, action: #selector(imagePressed(_:))))
        let background = PillControl(content: .symbol("photo.artframe"), width: size, tooltip: "Fondo", target: self, action: #selector(backgroundPressed))
        place(background)
        backgroundButton = background

        for slot in ToolSlot.allCases {
            let button = PillControl(content: .symbol(symbol(for: slot)), width: Design.toolSize, height: Design.toolSize, tooltip: slot.title, target: self, action: #selector(slotPressed(_:)))
            button.tag = slot.rawValue
            slotButtons[slot] = button
            toolStrip.add(button)
        }
        toolStrip.frame.origin = CGPoint(
            x: ((bar.bounds.width - toolStrip.frame.width) / 2).rounded(),
            y: ((barHeight - toolStrip.frame.height) / 2).rounded()
        )
        toolStrip.autoresizingMask = [.minXMargin, .maxXMargin]
        bar.addSubview(toolStrip)

        let doneTitle = "Listo"
        let done = PillControl(
            content: .text(doneTitle),
            width: PillControl.width(for: doneTitle, weight: .semibold),
            surface: .accent,
            tooltip: "Copiar, guardar y cerrar (⏎)",
            target: self,
            action: #selector(copyAndClose)
        )
        done.textWeight = .semibold
        done.keyEquivalent = "\r"
        done.setAccessibilityLabel(doneTitle)
        let style = PillControl(content: .dot(penColor), width: Self.styleWidth, tooltip: "Estilo", chevron: true, target: self, action: #selector(stylePressed(_:)))
        styleButton = style

        var right = bar.bounds.width - 12
        for button in [done, style] {
            right -= button.frame.width
            button.frame.origin = CGPoint(x: right, y: ((barHeight - button.frame.height) / 2).rounded())
            button.autoresizingMask = [.minXMargin]
            bar.addSubview(button)
            right -= Design.barGap
        }

        content.addSubview(bar)
        window.topBar = bar
    }

    /// Zoom e historia a la izquierda, arrastre al centro, salidas a la derecha.
    private func buildBottomBar(in content: NSView) {
        let barHeight = Design.editorBottomBar
        let size = Design.controlSize
        let bar = EditorBar(frame: CGRect(x: 0, y: 0, width: content.bounds.width, height: barHeight), lineAtBottom: false)
        bar.autoresizingMask = [.width, .maxYMargin]
        let middle = ((barHeight - size) / 2).rounded()

        var x: CGFloat = 12
        func place(_ view: NSView) {
            view.frame.origin = CGPoint(x: x, y: middle)
            bar.addSubview(view)
            x += view.frame.width + 2
        }

        let zoom = PillControl(content: .text("100%"), width: 62, tooltip: "Zoom", chevron: true, target: self, action: #selector(zoomPressed(_:)))
        place(zoom)
        zoomPill = zoom

        let undo = PillControl(content: .symbol("arrow.uturn.backward"), width: size, tooltip: "Deshacer (⌘Z)", target: canvas, action: #selector(AnnotationCanvas.undo(_:)))
        place(undo)
        undoButton = undo
        let redo = PillControl(content: .symbol("arrow.uturn.forward"), width: size, tooltip: "Rehacer (⇧⌘Z)", target: canvas, action: #selector(AnnotationCanvas.redo(_:)))
        place(redo)
        redoButton = redo
        let text = PillControl(content: .symbol("text.viewfinder"), width: size, tooltip: "Seleccionar texto en la imagen", target: self, action: #selector(toggleTextMode))
        place(text)
        textButton = text

        let dragWidth = Design.dragPillWidth
        let drag = DragPill(frame: CGRect(x: ((bar.bounds.width - dragWidth) / 2).rounded(), y: middle, width: dragWidth, height: size))
        drag.autoresizingMask = [.minXMargin, .maxXMargin]
        drag.fileProvider = { [weak self] in self?.exportTemporaryFile() }
        bar.addSubview(drag)
        dragPill = drag

        func action(_ symbol: String, tooltip: String, _ selector: Selector) -> PillControl {
            PillControl(content: .symbol(symbol), width: size, tooltip: tooltip, target: self, action: selector)
        }
        let saveTitle = "Guardar como…"
        let buttons = [
            action("square.and.arrow.up", tooltip: "Compartir", #selector(sharePressed(_:))),
            action("pin", tooltip: "Fijar en la pantalla", #selector(pinPressed)),
            action("doc.on.doc", tooltip: "Copiar sin cerrar (⌘C)", #selector(quickCopy)),
            action("terminal", tooltip: "Copiar ruta para un agente", #selector(copyPathPressed)),
            PillControl(
                content: .text(saveTitle),
                width: PillControl.width(for: saveTitle, weight: .regular, padding: 8),
                tooltip: saveTitle,
                target: self,
                action: #selector(savePressed(_:))
            ),
        ]
        var right = bar.bounds.width - 12
        for button in buttons.reversed() {
            right -= button.frame.width
            button.frame.origin = CGPoint(x: right, y: middle)
            button.autoresizingMask = [.minXMargin]
            bar.addSubview(button)
            right -= 2
        }

        content.addSubview(bar)
    }

    /// Centra los semáforos en la barra superior, que comparten con las herramientas.
    /// macOS los recoloca al cambiar el tamaño, así que se repite cada vez.
    private func alignWindowButtons() {
        let barHeight = Design.editorBar
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        guard let first = buttons.first, let titlebar = first.superview?.superview else { return }
        var frame = titlebar.frame
        frame.size.height = barHeight
        frame.origin.y = window.frame.height - barHeight
        titlebar.frame = frame
        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(NSPoint(
                x: 16 + CGFloat(index) * 20,
                y: ((barHeight - button.frame.height) / 2).rounded()
            ))
        }
    }

    func windowDidResize(_ notification: Notification) {
        alignWindowButtons()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        alignWindowButtons()
    }

    func show() {
        // Se abre en la pantalla de la captura, que puede no ser la principal.
        let visible = targetScreen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()
        ))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        alignWindowButtons()
    }

    /// El lienzo llena su zona y la imagen se ajusta dentro; el zoom se aplica encima.
    private func fitCanvas() {
        canvas.setFrameSize(scrollView.contentSize)
        if let liveText {
            liveText.place(in: canvas.convert(canvas.displayFrame, to: liveText))
        }
        refreshZoomLabel()
    }

    /// Algo cambió en el documento, también al deshacer o al abrir un proyecto.
    private func documentChanged() {
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
        refreshZoomLabel()
        refreshDragProxy()
        if panelOpen {
            backgroundPanel.reload(canvas.document.backdrop, capture: canvas.currentImage)
        }
    }

    /// La miniatura se reduce aparte: abrir el editor no espera por ella.
    private func refreshDragProxy() {
        let source = canvas.currentImage
        guard source !== proxySource, let pixels = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        proxySource = source
        let box = Unchecked(value: pixels)
        let longestSide = Int(Design.dragProxySize * 4)
        Task { @MainActor [weak self] in
            let small = await Task.detached(priority: .utility) {
                Unchecked(value: ImageTools.reduced(box.value, longestSide: longestSide))
            }.value
            guard let self, self.proxySource === source, let reduced = small.value else { return }
            self.dragPill?.proxy = NSImage(cgImage: reduced, size: CGSize(width: reduced.width, height: reduced.height))
        }
    }

    /// Con tecla o desde el menú, cada letra da su herramienta real: la A siempre es flecha.
    private func pick(_ tool: AnnotationTool) {
        if tool == .arrow {
            canvas.plainLine = false
        }
        select(tool: tool)
    }

    /// `keepingPopover` es para las variantes: se eligen dentro del popover y este sigue abierto.
    private func select(tool: AnnotationTool, keepingPopover: Bool = false) {
        canvas.commitText()
        closeTextMode()
        if !keepingPopover {
            stylePopover?.performClose(nil)
        }
        canvas.tool = tool
        canvas.color = tool == .highlight ? markerColor : penColor
        if let size = toolSizes[tool] {
            canvas.lineWidth = size
        }
        rememberVariant()
        refreshToolButtons()
        refreshStyleControls()
        if keepingPopover {
            rebuildStylePopover()
        }
    }

    /// La casilla vuelve a la última variante usada, también si se llegó a ella con una tecla.
    private func rememberVariant() {
        switch canvas.tool {
        case .rectangle: chosenShape = canvas.filled ? .filled : .box
        case .ellipse: chosenShape = .circle
        case .arrow where canvas.plainLine: chosenShape = .line
        case .pixelate: chosenHide = canvas.smoothBlur ? .blur : .pixelate
        case .spotlight: chosenHide = .focus
        case .pencil, .highlight: chosenDraw = canvas.tool
        default: break
        }
    }

    private var currentSlot: ToolSlot? {
        switch canvas.tool {
        case .select: return .select
        case .arrow: return canvas.plainLine ? .shape : .arrow
        case .rectangle, .ellipse: return .shape
        case .text: return .text
        case .counter: return .counter
        case .pixelate, .spotlight: return .hide
        case .pencil, .highlight: return .draw
        case .eraser: return .eraser
        case .crop, .picture: return nil
        }
    }

    private func symbol(for slot: ToolSlot) -> String {
        switch slot {
        case .select: return AnnotationTool.select.symbol
        case .arrow: return AnnotationTool.arrow.symbol
        case .shape: return chosenShape.symbol
        case .text: return AnnotationTool.text.symbol
        case .counter: return AnnotationTool.counter.symbol
        case .hide: return chosenHide.symbol
        case .draw: return chosenDraw.symbol
        case .eraser: return AnnotationTool.eraser.symbol
        }
    }

    private func refreshToolButtons() {
        let current = currentSlot
        for (slot, button) in slotButtons {
            button.isActive = slot == current
            button.content = .symbol(symbol(for: slot))
        }
        slotButtons[.shape]?.setAccessibilityLabel("Forma: \(chosenShape.label)")
        slotButtons[.hide]?.setAccessibilityLabel("Ocultar: \(chosenHide.label)")
        slotButtons[.draw]?.setAccessibilityLabel("Dibujar: \(chosenDraw.label)")
        cropButton?.isActive = canvas.tool == .crop
        toolStrip.highlight(current.flatMap { slotButtons[$0] })
    }

    private var toolHasColor: Bool {
        ![.eraser, .pixelate, .crop, .spotlight, .select].contains(canvas.tool)
    }

    private var toolHasSize: Bool {
        [.pencil, .highlight, .eraser, .pixelate, .rectangle, .ellipse, .arrow, .text, .counter].contains(canvas.tool)
    }

    private func refreshStyleControls() {
        // Sin color que mostrar, el botón sigue abriendo el grosor o las variantes.
        styleButton?.content = toolHasColor ? .dot(canvas.color) : .symbol("slider.horizontal.3")
        styleButton?.isEnabled = toolHasColor || toolHasSize || currentSlot?.hasVariants == true
        styleButton?.setAccessibilityValue(toolHasColor ? colorName(canvas.color) : nil)
    }

    private func colorName(_ color: NSColor) -> String {
        (Self.palette + Self.markers).first { Self.sameColor($0.1, color) }?.0 ?? "Color propio"
    }

    @objc private func cropPressed() {
        select(tool: .crop)
    }

    /// Una herramienta que ya está activa y tiene variantes abre el estilo desde su sitio.
    @objc private func slotPressed(_ sender: NSButton) {
        guard let slot = ToolSlot(rawValue: sender.tag) else { return }
        if slot == currentSlot, slot.hasVariants {
            toggleStylePopover(from: sender)
            return
        }
        switch slot {
        case .select: select(tool: .select)
        case .arrow: pick(.arrow)
        case .shape: choose(chosenShape)
        case .text: select(tool: .text)
        case .counter: select(tool: .counter)
        case .hide: choose(chosenHide)
        case .draw: select(tool: chosenDraw)
        case .eraser: select(tool: .eraser)
        }
    }

    private func choose(_ kind: ShapeKind, keepingPopover: Bool = false) {
        canvas.filled = kind == .filled
        canvas.plainLine = kind == .line
        switch kind {
        case .box, .filled: select(tool: .rectangle, keepingPopover: keepingPopover)
        case .circle: select(tool: .ellipse, keepingPopover: keepingPopover)
        case .line: select(tool: .arrow, keepingPopover: keepingPopover)
        }
    }

    private func choose(_ kind: HideKind, keepingPopover: Bool = false) {
        if kind != .focus {
            canvas.smoothBlur = kind == .blur
        }
        select(tool: kind == .focus ? .spotlight : .pixelate, keepingPopover: keepingPopover)
    }

    @objc private func shapeChanged(_ sender: NSSegmentedControl) {
        guard let kind = ShapeKind(rawValue: sender.selectedSegment) else { return }
        choose(kind, keepingPopover: true)
    }

    @objc private func hideChanged(_ sender: NSSegmentedControl) {
        guard let kind = HideKind(rawValue: sender.selectedSegment) else { return }
        choose(kind, keepingPopover: true)
    }

    @objc private func drawChanged(_ sender: NSSegmentedControl) {
        select(tool: sender.selectedSegment == 1 ? .highlight : .pencil, keepingPopover: true)
    }

    // MARK: - Imagen

    @objc private func imagePressed(_ sender: NSButton) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, tag: Int = 0, to target: NSMenu? = nil) {
            let item = (target ?? menu).addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
        }
        add("Rotar a la derecha", #selector(rotateImage(_:)), tag: 1)
        add("Rotar a la izquierda", #selector(rotateImage(_:)))
        add("Voltear en horizontal", #selector(flipImage(_:)), tag: 1)
        add("Voltear en vertical", #selector(flipImage(_:)))
        menu.addItem(.separator())
        let sizes = NSMenu()
        for percent in [75, 50, 25] {
            add("\(percent)%", #selector(resizeImage(_:)), tag: percent, to: sizes)
        }
        menu.addItem(withTitle: "Cambiar tamaño", action: nil, keyEquivalent: "").submenu = sizes
        menu.addItem(.separator())
        add("Añadir otra imagen…", #selector(addOtherImage))
        add(panelOpen ? "Ocultar el fondo" : "Mostrar el fondo", #selector(backgroundPressed))
        // La píldora dibuja con origen abajo: el menú cae justo debajo de ella.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: sender)
    }

    @objc private func rotateImage(_ sender: NSMenuItem) {
        canvas.applyImage { ImageTools.rotated($0, clockwise: sender.tag == 1) }
    }

    @objc private func flipImage(_ sender: NSMenuItem) {
        canvas.applyImage { ImageTools.flipped($0, horizontally: sender.tag == 1) }
    }

    @objc private func resizeImage(_ sender: NSMenuItem) {
        canvas.applyImage { ImageTools.resized($0, factor: CGFloat(sender.tag) / 100) }
    }

    @objc private func addOtherImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            let url = panel.url
            Task { @MainActor in
                guard response == .OK, let url, let picture = NSImage(contentsOf: url) else { return }
                self?.canvas.addPicture(picture)
            }
        }
    }

    // MARK: - Panel Fondo

    @objc private func backgroundPressed() {
        setBackgroundPanel(open: !panelOpen)
    }

    /// El panel entra por la izquierda con resorte y el lienzo le hace sitio.
    private func setBackgroundPanel(open: Bool) {
        guard open != panelOpen else { return }
        canvas.commitText()
        closeTextMode()
        panelOpen = open
        backgroundButton?.isActive = open
        backgroundButton?.setAccessibilityValue(open ? "Abierto" : "Cerrado")
        panelSpring?.invalidate()

        if open {
            canvas.prewarmBackdrop()
            backgroundPanel.reload(canvas.document.backdrop, capture: canvas.currentImage)
            backgroundPanel.isHidden = false
        }
        let start = panelProgress
        let target: CGFloat = open ? 1 : 0
        panelSpring = Spring.run(
            step: { [weak self] value in
                self?.applyPanel(progress: start + (target - start) * value)
            },
            completion: { [weak self] in
                self?.applyPanel(progress: target)
                self?.backgroundPanel.isHidden = !open
            }
        )
    }

    private func applyPanel(progress: CGFloat) {
        panelProgress = progress
        guard let content = window.contentView else { return }
        let width = BackgroundPanel.width
        // El panel no se despega del borde. El lienzo sí acusa el rebote del resorte.
        backgroundPanel.frame.origin.x = -width * (1 - min(max(progress, 0), 1))
        let shift = width * max(progress, 0)
        scrollView.frame = CGRect(
            x: shift,
            y: Design.editorBottomBar,
            width: max(content.bounds.width - shift, 1),
            height: max(content.bounds.height - Design.editorBar - Design.editorBottomBar, 1)
        )
    }

    private func pickBackdropPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            let url = panel.url
            Task { @MainActor in
                guard response == .OK, let url, let picture = NSImage(contentsOf: url),
                      let data = ImageTools.backdropPicture(from: picture)
                else { return }
                self?.backgroundPanel.usePicture(data)
            }
        }
    }

    @objc private func pixelModeChanged(_ sender: NSSegmentedControl) {
        canvas.pixelBrush = sender.selectedSegment == 1
        rebuildStylePopover()
    }

    @objc private func blockChanged(_ sender: NSSlider) {
        canvas.blockSize = CGFloat(sender.doubleValue.rounded())
    }

    private func setColor(_ color: NSColor) {
        if canvas.tool == .highlight {
            markerColor = color
        } else {
            penColor = color
        }
        canvas.color = color
        anySwatch?.color = color
        refreshStyleControls()
    }

    // MARK: - Popovers de estilo

    /// Pulsar lo mismo con el popover abierto debe cerrarlo: el sistema ya lo cerró
    /// al apretar el botón, y no hay que volver a abrirlo al soltar.
    private func toggleStylePopover(from sender: NSView) {
        if stylePopover?.isShown == true {
            stylePopover?.performClose(nil)
            return
        }
        if let popoverClosed, Date().timeIntervalSince(popoverClosed) < 0.25 {
            self.popoverClosed = nil
            return
        }
        stylePopover?.close()

        let controller = NSViewController()
        controller.view = buildStyleControls()
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        popover.behavior = .transient
        popover.animates = !Design.reduceMotion
        popover.delegate = self
        stylePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === stylePopover else { return }
        popoverClosed = Date()
        stylePopover = nil
    }

    @objc private func stylePressed(_ sender: NSButton) {
        toggleStylePopover(from: sender)
    }

    /// Cambiar de variante cambia lo que se puede ajustar.
    private func rebuildStylePopover() {
        guard let popover = stylePopover, popover.isShown else { return }
        let view = buildStyleControls()
        popover.contentViewController?.view = view
        popover.contentSize = view.frame.size
    }

    /// Todo el estilo en un solo sitio: variante, color y grosor de la herramienta elegida.
    private func buildStyleControls() -> NSView {
        let tool = canvas.tool
        let width: CGFloat = 282
        let side: CGFloat = 12
        let inner = width - side * 2
        let view = StyleStack(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = side

        func addLabel(_ text: String, x: CGFloat = side, y labelY: CGFloat, width labelWidth: CGFloat = 72) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13)
            label.textColor = Palette.text
            label.frame = CGRect(x: x, y: labelY, width: labelWidth, height: 18)
            view.addSubview(label)
        }
        func addSegment(_ labels: [String], selected: Int, name: String, action: Selector) {
            let mode = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
            mode.selectedSegment = selected
            mode.controlSize = .small
            mode.segmentDistribution = .fillEqually
            // Sin esto se pinta gris mientras el foco siga en el lienzo.
            mode.selectedSegmentBezelColor = Palette.accent
            mode.setAccessibilityLabel(name)
            mode.frame = CGRect(x: side, y: y, width: inner, height: 22)
            view.addSubview(mode)
            y += 22 + 10
        }

        switch currentSlot {
        case .shape:
            addSegment(ShapeKind.allCases.map(\.label), selected: chosenShape.rawValue, name: "Forma", action: #selector(shapeChanged(_:)))
        case .hide:
            addSegment(HideKind.allCases.map(\.label), selected: chosenHide.rawValue, name: "Ocultar", action: #selector(hideChanged(_:)))
            if tool == .pixelate {
                addSegment(["Recuadro", "Pincel"], selected: canvas.pixelBrush ? 1 : 0, name: "Forma de la censura", action: #selector(pixelModeChanged(_:)))
            }
        case .draw:
            addSegment([AnnotationTool.pencil.label, AnnotationTool.highlight.label], selected: tool == .highlight ? 1 : 0, name: "Dibujar", action: #selector(drawChanged(_:)))
        default:
            break
        }

        if toolHasColor {
            let colors = tool == .highlight ? Self.markers : Self.palette
            let dot: CGFloat = 26
            let gap: CGFloat = 3
            var x = side
            for (index, entry) in colors.enumerated() {
                let button = DotButton(color: entry.1, diameter: 18, tooltip: entry.0, target: self, action: #selector(colorPressed(_:)))
                button.tag = index
                button.frame.origin = CGPoint(x: x, y: y)
                button.isActive = Self.sameColor(entry.1, canvas.color)
                button.setAccessibilityLabel(entry.0)
                view.addSubview(button)
                x += dot + gap
            }
            y += dot + 8

            if tool != .highlight {
                let swatch = ColorSwatch(frame: CGRect(x: side, y: y, width: 34, height: 24), color: canvas.color, tooltip: "Cualquier color", target: self, action: #selector(anyColorPressed))
                view.addSubview(swatch)
                anySwatch = swatch
                addLabel("Cualquier color", x: side + 42, y: y + 3, width: 120)
                let picker = GlassButton(symbol: "eyedropper", tooltip: "Tomar un color de la pantalla", target: self, action: #selector(sampleColor), size: Design.controlSize)
                picker.frame.origin = CGPoint(x: width - side - Design.controlSize, y: y - 2)
                view.addSubview(picker)
                y += 24 + 10
            }
        }

        if toolHasSize, tool != .pixelate || canvas.pixelBrush, let size = Self.sizes[tool] {
            addLabel("Tamaño", y: y + 2)
            let slider = ZasSlider(value: Double(canvas.lineWidth), minValue: Double(size.0), maxValue: Double(size.1), target: self, action: #selector(sizeChanged(_:)))
            slider.frame = CGRect(x: 90, y: y + 2, width: 136, height: 18)
            slider.setAccessibilityLabel("Tamaño")
            view.addSubview(slider)

            let value = ValueChip(text: "\(Int(canvas.lineWidth))", fill: Palette.pill)
            value.frame.origin = CGPoint(x: width - side - value.frame.width, y: y)
            view.addSubview(value)
            sizeValue = value
            y += 22 + 8
        }

        if tool == .pixelate {
            addLabel("Intensidad", y: y + 2)
            let blocks = ZasSlider(value: Double(canvas.blockSize), minValue: 6, maxValue: 40, target: self, action: #selector(blockChanged(_:)))
            blocks.frame = CGRect(x: 90, y: y + 2, width: width - side - 90, height: 18)
            blocks.setAccessibilityLabel("Intensidad")
            view.addSubview(blocks)
            y += 22 + 8
        }

        // El último renglón ya dejó su separación: el margen de abajo es igual al de arriba.
        view.frame.size.height = max(y - 8 + side, side * 2)
        return view
    }

    private static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let first = a.usingColorSpace(.sRGB), let second = b.usingColorSpace(.sRGB) else { return false }
        return abs(first.redComponent - second.redComponent) < 0.01
            && abs(first.greenComponent - second.greenComponent) < 0.01
            && abs(first.blueComponent - second.blueComponent) < 0.01
    }

    @objc private func colorPressed(_ sender: NSButton) {
        let colors = canvas.tool == .highlight ? Self.markers : Self.palette
        setColor(colors[sender.tag].1)
        rebuildStylePopover()
    }

    @objc private func sampleColor() {
        stylePopover?.performClose(nil)
        NSColorSampler().show { [weak self] color in
            guard let color else { return }
            Task { @MainActor in
                self?.setColor(color)
            }
        }
    }

    /// El panel es el del sistema. Sigue apuntando aquí aunque el popover se cierre, hasta que se cierre el editor.
    @objc private func anyColorPressed() {
        let colors = NSColorPanel.shared
        colors.setTarget(self)
        colors.setAction(#selector(anyColorChanged(_:)))
        colors.showsAlpha = false
        colors.isContinuous = true
        colors.color = canvas.color
        colors.orderFront(nil)
    }

    @objc private func anyColorChanged(_ sender: NSColorPanel) {
        setColor(sender.color)
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        let value = CGFloat(sender.doubleValue.rounded())
        toolSizes[canvas.tool] = value
        canvas.lineWidth = value
        sizeValue?.text = "\(Int(value))"
    }

    // MARK: - Zoom

    private func zoom(by step: Int) {
        switch step {
        case 0:
            zoomFit()
        case let value where value > 0:
            zoomIn()
        default:
            zoomOut()
        }
    }

    /// Con el resorte de siempre. La etiqueta sigue a cada cuadro por el aviso de la vista de recorte.
    private func setMagnification(_ value: CGFloat) {
        zoomSpring?.invalidate()
        let start = scrollView.magnification
        zoomSpring = Spring.run(step: { [weak self] progress in
            self?.scrollView.magnification = start + (value - start) * progress
        }, completion: { [weak self] in
            self?.refreshZoomLabel()
        })
    }

    @objc private func zoomIn() { setMagnification(min(scrollView.magnification * 1.25, 8)) }
    @objc private func zoomOut() { setMagnification(max(scrollView.magnification / 1.25, 0.25)) }
    /// La imagen entera a la vista, sin agrandarla más de su tamaño real: el lienzo ya se ajusta solo.
    @objc private func zoomFit() { setMagnification(1) }

    @objc private func zoomPressed(_ sender: NSButton) {
        let menu = NSMenu()
        for percent in [50, 100, 200] {
            let item = menu.addItem(withTitle: "\(percent)%", action: #selector(zoomPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ajustar", action: #selector(zoomFit), keyEquivalent: "").target = self
        // La píldora vive abajo: el menú se abre hacia arriba.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + menu.size.height + 6), in: sender)
    }

    /// El porcentaje se cuenta sobre el tamaño real de la imagen, no sobre el ajuste al lienzo.
    @objc private func zoomPreset(_ sender: NSMenuItem) {
        let target = CGFloat(sender.tag) / 100 / max(canvas.fitScale, 0.01)
        setMagnification(min(max(target, 0.25), 8))
    }

    // MARK: - Menú principal

    @objc private func menuSave() { saveCopy() }

    @objc private func menuTool(_ sender: NSMenuItem) {
        guard let tool = AnnotationTool(rawValue: sender.tag) else { return }
        pick(tool)
    }

    private func refreshZoomLabel() {
        let percent = "\(Int((scrollView.magnification * canvas.fitScale * 100).rounded()))%"
        zoomPill?.content = .text(percent)
        zoomPill?.setAccessibilityValue(percent)
    }

    // MARK: - Selección de texto

    /// Copia todo el texto al instante y deja seleccionar palabras sobre la imagen.
    @objc private func toggleTextMode() {
        if liveText != nil {
            closeTextMode()
            return
        }
        canvas.commitText()
        guard let snapshot = canvas.textSnapshot() else { return }
        // La imagen se lee entera y ajustada al lienzo, en el mismo sitio donde estaba.
        zoomSpring?.invalidate()
        scrollView.magnification = 1

        TextReader.read(image: snapshot.pixels) { text in
            guard !text.isEmpty else {
                Toast.shared.show("No hay texto en esta captura")
                return
            }
            Capture.copyText(text)
            Sounds.play(.copy)
            Toast.shared.show("Texto copiado")
        }

        let pane = LiveTextPane(frame: scrollView.frame, image: snapshot.image, area: .zero)
        pane.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(pane, positioned: .above, relativeTo: scrollView)
        // El lienzo está dentro de la vista con zoom: su sitio se traduce al de la capa.
        pane.place(in: canvas.convert(canvas.displayFrame, to: pane))
        liveText = pane
        textButton?.isActive = true
        // Al seleccionar, el foco queda en la capa de Apple y Esc nunca llegaría al lienzo.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, event.window === self.window else { return event }
            MainActor.assumeIsolated {
                self.closeTextMode()
            }
            return nil
        }
        Task { @MainActor in
            _ = await pane.analyze()
        }
    }

    private func closeTextMode() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        liveText?.removeFromSuperview()
        liveText = nil
        textButton?.isActive = false
        window.makeFirstResponder(canvas)
    }

    /// Abre el editor ya listo para seleccionar texto.
    func openTextMode() {
        toggleTextMode()
    }

    // MARK: - Copiar y guardar

    @objc private func quickCopy() {
        canvas.commitText()
        guard let bitmap = canvas.exportBitmap() else { return }
        Task { @MainActor in
            guard let data = await Capture.encodePNG(bitmap) else {
                Toast.shared.show("No se pudo copiar.")
                return
            }
            Capture.publish(data)
            Sounds.play(.copy)
            Toast.shared.show("Copiado")
        }
    }

    /// Archivo de paso con el resultado actual, para arrastrar o compartir.
    private func exportTemporaryFile() -> URL? {
        canvas.commitText()
        guard let data = canvas.exportPNG() else { return nil }
        let url = Capture.uniqueURL(in: Capture.scratchFolder, name: "\(Self.baseName(of: file)) anotada.png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    @objc private func sharePressed(_ sender: NSButton) {
        guard let url = exportTemporaryFile() else {
            Toast.shared.show("No se pudo crear la imagen.")
            return
        }
        let picker = NSSharingServicePicker(items: Self.shareItems(for: url))
        sharePicker = picker
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// Se comparte el archivo con las marcas, no la captura original.
    private static func shareItems(for file: URL) -> [Any] {
        [file]
    }

    @objc private func pinPressed() {
        canvas.commitText()
        guard let data = canvas.exportPNG(), let picture = NSImage(data: data) else {
            Toast.shared.show("No se pudo crear la imagen.")
            return
        }
        Self.pins.pin(picture)
    }

    /// Sin cambios, la ruta es la de la captura. Con cambios, la de una copia con las marcas:
    /// quien la reciba debe ver lo mismo que hay en el editor.
    @objc private func copyPathPressed() {
        canvas.commitText()
        var path: URL?
        if canvas.revision == 0, file.pathExtension != "zas", FileManager.default.fileExists(atPath: file.path) {
            path = file
        } else if let pathExport, pathExport.revision == canvas.revision {
            path = pathExport.url
        } else {
            let url = nextCopyURL(in: Capture.imageFolder)
            guard write(to: url) else { return }
            pathExport = (canvas.revision, url)
            path = url
        }
        guard let path else { return }
        Capture.copyText(path.path)
        Sounds.play(.copy)
        Toast.shared.show("Ruta copiada")
    }

    @objc private func savePressed(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Guardar una copia con los cambios", action: #selector(saveCopy), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reemplazar el original", action: #selector(replaceOriginal), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Guardar como…", action: #selector(saveAs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Guardar proyecto editable…", action: #selector(saveProject), keyEquivalent: "").target = self
        // La barra vive abajo: el menú se abre hacia arriba.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + menu.size.height + 6), in: sender)
    }

    private func nextCopyURL(in folder: URL) -> URL {
        let base = Self.baseName(of: file)
        var output = folder.appendingPathComponent("\(base) anotada.png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = folder.appendingPathComponent("\(base) anotada \(suffix).png")
            suffix += 1
        }
        return output
    }

    private func write(to url: URL) -> Bool {
        canvas.commitText()
        guard let data = canvas.exportPNG(), (try? data.write(to: url)) != nil else {
            Toast.shared.show("No se pudo guardar. Revisa la carpeta en Ajustes.")
            return false
        }
        savedRevision = canvas.revision
        return true
    }

    private func announce(_ url: URL) {
        let path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        Toast.shared.show("Guardado en \(path)", seconds: 3.5)
    }

    @objc private func saveCopy() {
        // Guardar a propósito nunca va a la carpeta temporal.
        let url = nextCopyURL(in: Capture.folder)
        if write(to: url) {
            announce(url)
        }
    }

    @objc private func replaceOriginal() {
        let alert = NSAlert()
        alert.messageText = "¿Reemplazar el original?"
        alert.informativeText = "La imagen anterior no se podrá recuperar."
        let replace = alert.addButton(withTitle: "Reemplazar")
        replace.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                self?.performReplace()
            }
        }
    }

    private func performReplace() {
        // Un proyecto se reemplaza como proyecto: si no, dejaría de abrirse.
        if file.pathExtension == "zas" {
            canvas.commitText()
            guard let data = canvas.projectData(), (try? data.write(to: file)) != nil else {
                Toast.shared.show("No se pudo guardar.")
                return
            }
            savedRevision = canvas.revision
            announce(file)
        } else if write(to: file) {
            announce(file)
        }
    }

    @objc private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = Capture.folder
        panel.nameFieldStringValue = "\(Self.baseName(of: file)) anotada.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            let url = panel.url
            Task { @MainActor in
                guard response == .OK, let url, let self else { return }
                if self.write(to: url) {
                    self.announce(url)
                }
            }
        }
    }

    @objc private func saveProject() {
        canvas.commitText()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ZasProject.fileType]
        panel.directoryURL = Capture.folder
        panel.nameFieldStringValue = "\(Self.baseName(of: file)).zas"
        panel.beginSheetModal(for: window) { [weak self] response in
            let url = panel.url
            Task { @MainActor in
                guard response == .OK, let url, let self, let data = self.canvas.projectData(),
                      (try? data.write(to: url)) != nil
                else { return }
                self.savedRevision = self.canvas.revision
                self.announce(url)
            }
        }
    }

    @objc func copyAndClose() {
        guard !isFinishing else { return }
        canvas.commitText()
        guard let bitmap = canvas.exportBitmap() else {
            Toast.shared.show("No se pudo crear la imagen.")
            return
        }
        isFinishing = true
        let output = nextCopyURL(in: Capture.imageFolder)
        Task { @MainActor in
            defer { self.isFinishing = false }
            guard let data = await Capture.encodePNG(bitmap),
                  (try? data.write(to: output)) != nil,
                  let copied = NSImage(data: data)
            else {
                Toast.shared.show("No se pudo guardar. Revisa la carpeta en Ajustes.")
                return
            }
            Capture.publish(data)
            self.window.close()
            self.onFinish?(copied, output)
        }
    }

    /// Nombre sin el " anotada" de una edición anterior, para no acumularlo.
    static func baseName(of file: URL) -> String {
        var base = file.deletingPathExtension().lastPathComponent
        if let suffix = base.range(of: #" anotada( \d+)?$"#, options: .regularExpression) {
            base.removeSubrange(suffix)
        }
        return base
    }

    /// Esc o la × no deben borrar sin preguntar lo que se acaba de dibujar.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if liveText != nil {
            closeTextMode()
            return false
        }
        guard hasUnsavedWork else { return true }

        let alert = NSAlert()
        alert.messageText = "¿Cerrar sin copiar?"
        alert.informativeText = "Lo que dibujaste en esta captura se perderá."
        alert.addButton(withTitle: "Copiar y cerrar")
        alert.addButton(withTitle: "Descartar").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancelar").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                switch response {
                case .alertFirstButtonReturn: self?.copyAndClose()
                case .alertSecondButtonReturn: self?.window.close()
                default: break
                }
            }
        }
        return false
    }

    var hasUnsavedWork: Bool {
        canvas.hasPendingText || (canvas.hasUnsavedMarks && canvas.revision != savedRevision)
    }

    func windowWillClose(_ notification: Notification) {
        closeTextMode()
        panelSpring?.invalidate()
        zoomSpring?.invalidate()
        backgroundPanel.releaseColorPanel()
        stylePopover?.close()
        if let magnifyObserver {
            NotificationCenter.default.removeObserver(magnifyObserver)
            self.magnifyObserver = nil
        }
        // Devuelve el foco a la app donde se estaba trabajando, se copie o no.
        previousApp?.activate(options: [])
        onClose?()
    }

    #if ZAS_TEST
    var testWindow: NSWindow { window }

    func testSelect(tool: AnnotationTool, colorIndex: Int? = nil) {
        select(tool: tool)
        if let colorIndex {
            setColor(Self.palette[colorIndex].1)
        }
    }

    /// Abre o cierra el popover de estilo, como el botón Estilo de la barra.
    func testOpenStylePopover() {
        if let styleButton {
            stylePressed(styleButton)
        }
    }

    /// Las dos escenas de siempre: la paleta y el grosor viven ahora en el mismo popover.
    func testOpenPalette() { testOpenStylePopover() }
    func testOpenSizePopover() { testOpenStylePopover() }

    var testStylePopoverShown: Bool { stylePopover?.isShown == true }
    var testHasDragProxy: Bool { dragPill?.proxy != nil }
    var testAnySwatchColor: NSColor? { anySwatch?.color }

    /// Pulsa una de las ocho casillas, en el orden de la barra.
    func testPressSlot(_ index: Int) {
        if let slot = ToolSlot(rawValue: index), let button = slotButtons[slot] {
            slotPressed(button)
        }
    }

    func testChooseShape(_ index: Int) {
        if let kind = ShapeKind(rawValue: index) {
            choose(kind, keepingPopover: true)
        }
    }

    func testChooseHide(_ index: Int) {
        if let kind = HideKind(rawValue: index) {
            choose(kind, keepingPopover: true)
        }
    }

    var testSlotCount: Int { slotButtons.count }
    var testCurrentSlot: Int? { currentSlot?.rawValue }
    var testToolFrames: [CGRect] { toolStrip.testItemFrames }
    var testMarkerFrame: CGRect? { toolStrip.testMarkerFrame }
    var testStyleEnabled: Bool { styleButton?.isEnabled == true }

    /// Sitio de la imagen en el lienzo y de las dos piezas de Live Text.
    var testTextPaneReport: String {
        guard let liveText else { return "sin capa" }
        let area = canvas.convert(canvas.displayFrame, to: liveText)
        return liveText.testOverlayReport(at: CGPoint(x: area.midX, y: area.midY))
    }

    var testCanvasImageFrame: CGRect {
        guard let liveText else { return canvas.displayFrame }
        return canvas.convert(canvas.displayFrame, to: liveText)
    }
    var testTextPaneFrames: (image: CGRect, overlay: CGRect)? {
        liveText.map { ($0.testImageFrame, $0.testOverlayFrame) }
    }

    func testOpenBackgroundPanel(gradient: Int) {
        setBackgroundPanel(open: true)
        backgroundPanel.chooseGradient(gradient)
    }

    func testCloseBackgroundPanel() {
        setBackgroundPanel(open: false)
    }

    var testBackgroundPanelOpen: Bool { panelOpen }

    /// Zona del lienzo: toda la ventana menos las dos barras y el panel.
    var testCanvasArea: CGRect { scrollView.frame }

    func testZoom() -> CGFloat {
        zoomSpring?.invalidate()
        scrollView.magnification = 2
        return scrollView.magnification
    }

    func testResetZoom() {
        scrollView.magnification = 1
    }

    func testTextMode() {
        toggleTextMode()
    }

    /// Prueba real de Live Text: detecta texto en una imagen y dice si lo encontró.
    func testLiveTextFindsText() async -> Bool {
        guard let snapshot = canvas.textSnapshot(), let analysis = await LiveText.analysis(of: snapshot.image) else {
            return false
        }
        return analysis.hasResults(for: .text)
    }

    /// Entrar a seleccionar texto no debe agrandar una captura pequeña.
    var testTextPaneScaling: NSImageScaling? { liveText?.imageScaling }

    func testKeyDown(_ characters: String) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
        ) else { return }
        canvas.keyDown(with: event)
    }

    func testShowBackgroundPanel() { setBackgroundPanel(open: true) }
    var testPanel: BackgroundPanel { backgroundPanel }
    func testQuickCopy() { quickCopy() }
    func testCopyPath() { copyPathPressed() }
    func testPin() { pinPressed() }
    func testSaveCopy() { saveCopy() }
    func testFinish() { copyAndClose() }
    func testDragFile() -> URL? { exportTemporaryFile() }
    func testZoomPreset(_ percent: Int) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = percent
        zoomPreset(item)
    }

    var testZoomLabel: String? { zoomPill?.accessibilityValue() as? String }
    func testCloseEditor() { window.close() }
    static func testPinCount() -> Int { pins.testCount }
    static func testClosePins() { pins.closeAll() }

    /// Lo que recibiría el selector de Compartir, sin abrirlo: su menú detendría la prueba.
    func testShareItems() -> [Any]? {
        exportTemporaryFile().map(Self.shareItems)
    }

    /// Cuántos controles se pisan en las dos barras.
    var testBarOverlaps: Int {
        var total = 0
        for bar in window.contentView?.subviews.compactMap({ $0 as? EditorBar }) ?? [] {
            let frames = bar.subviews.map { $0.frame.insetBy(dx: 1, dy: 1) }
            for (index, frame) in frames.enumerated() {
                total += frames[(index + 1)...].filter { $0.intersects(frame) }.count
            }
        }
        return total
    }
    #endif
}

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
        dot.lineWidth = 1
        dot.stroke()
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
@MainActor
private final class LiveTextPane: NSView {
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()

    /// `inset` es el aire del lienzo: la imagen se queda donde estaba, sin agrandarse al entrar.
    init(frame: CGRect, image: NSImage, inset: CGFloat) {
        super.init(frame: frame)
        imageView.frame = bounds.insetBy(dx: inset, dy: inset)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        overlay.frame = imageView.frame
        overlay.autoresizingMask = [.width, .height]
        overlay.preferredInteractionTypes = .textSelection
        overlay.selectableItemsHighlighted = true
        // El botón de Live Text del sistema sobra: Zas ya tiene el suyo en la barra.
        overlay.isSupplementaryInterfaceHidden = true
        overlay.trackingImageView = imageView
        addSubview(overlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    /// Devuelve `false` si este Mac no ofrece Live Text.
    func analyze() async -> Bool {
        guard let image = imageView.image, let analysis = await LiveText.analysis(of: image) else { return false }
        overlay.analysis = analysis
        return true
    }

    var imageScaling: NSImageScaling { imageView.imageScaling }
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

/// Fondo de los popovers de estilo: el sistema pone la forma y Zas el color.
private final class PopoverSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.group.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

/// Cápsula de las herramientas: todas caben en una sola pieza, con una línea entre cada dos.
/// La activa crece, ocupa toda la altura y borra las líneas que la tocan.
private final class ToolStrip: NSView {
    private var items: [PillControl] = []

    /// Botón que se muestra activo. `nil` cuando la herramienta vive fuera de la cápsula.
    var active: PillControl? {
        didSet { relayout() }
    }

    var totalWidth: CGFloat {
        CGFloat(items.count) * Design.toolSize + Design.activeToolWidth - Design.toolSize
    }

    func add(_ item: PillControl) {
        items.append(item)
        addSubview(item)
    }

    func relayout() {
        frame.size = CGSize(width: totalWidth, height: Design.pillHeight)
        // Sin activa, el ancho que le toca se reparte: la cápsula no cambia de tamaño.
        let plain = active == nil ? totalWidth / CGFloat(max(items.count, 1)) : Design.toolSize
        var x: CGFloat = 0
        for item in items {
            let width = item === active ? Design.activeToolWidth : plain
            item.frame = CGRect(x: x, y: 0, width: width, height: Design.pillHeight)
            x += width
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.group.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        Palette.hairline.setFill()
        for (left, right) in zip(items, items.dropFirst()) where left !== active && right !== active {
            NSBezierPath(rect: CGRect(x: right.frame.minX.rounded(), y: bounds.midY - 7, width: 1, height: 14)).fill()
        }
    }
}

/// Barra superior o inferior: color propio y un filo fino hacia el lienzo.
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
        NSBezierPath(rect: CGRect(x: 0, y: lineAtBottom ? 0 : bounds.height - 1, width: bounds.width, height: 1)).fill()
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
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2 - 0.5, yRadius: bounds.height / 2 - 0.5)
        Palette.group.setFill()
        capsule.fill()
        if start != nil {
            Palette.pressed.setFill()
            capsule.fill()
        } else if isHovering {
            Palette.hover.setFill()
            capsule.fill()
        }
        Palette.hairline.setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Palette.text,
        ]
        let title = "Arrástrame" as NSString
        let size = title.size(withAttributes: attributes)
        title.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )

        // Tres rayas finas a cada lado: una pila de 11 puntos de alto.
        Palette.secondaryText.setFill()
        for x in [CGFloat(15), bounds.maxX - 23] {
            for offset in [CGFloat(-5), 0, 5] {
                NSBezierPath(rect: CGRect(x: x, y: (bounds.midY + offset - 0.5).rounded(), width: 8, height: 1)).fill()
            }
        }
    }
}

/// Ventana de anotación. "Listo" reemplaza el portapapeles, guarda una copia y cierra.
@MainActor
final class AnnotationEditor: NSObject, NSWindowDelegate, NSPopoverDelegate {
    var onFinish: ((NSImage, URL) -> Void)?
    var onClose: (() -> Void)?

    private enum StylePopover {
        case color, size, line
    }

    private static let palette: [(String, NSColor)] = [
        ("Rosa", Palette.markDefault),
        ("Rojo", .systemRed),
        ("Anaranjado", .systemOrange),
        ("Amarillo", .systemYellow),
        ("Verde", .systemGreen),
        ("Azul", .systemBlue),
        ("Morado", .systemPurple),
        ("Negro", .black),
        ("Blanco", .white),
    ]
    private static let markers: [(String, NSColor)] = [
        ("Amarillo", NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)),
        ("Verde", NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)),
        ("Azul", NSColor(srgbRed: 0.39, green: 0.82, blue: 1, alpha: 1)),
        ("Rosado", NSColor(srgbRed: 1, green: 0.44, blue: 0.68, alpha: 1)),
        ("Anaranjado", NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)),
        ("Morado", NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1)),
        ("Violeta", NSColor(srgbRed: 0.49, green: 0.48, blue: 1, alpha: 1)),
    ]
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

    private var toolButtons: [AnnotationTool: PillControl] = [:]
    private var filledButton: PillControl?
    private var backgroundButton: PillControl?
    private let toolStrip = ToolStrip()
    private var colorPill: PillControl?
    private var widthPill: PillControl?
    private var linePill: PillControl?
    private var zoomPill: PillControl?
    private var undoButton: PillControl?
    private var redoButton: PillControl?
    private var textButton: PillControl?
    private var liveText: LiveTextPane?
    private var escapeMonitor: Any?

    private var stylePopover: NSPopover?
    private var openPopover: StylePopover?
    private var popoverClosed: (kind: StylePopover, at: Date)?

    private var panelOpen = false
    private var panelProgress: CGFloat = 0
    private var panelSpring: Timer?
    private var sharePicker: NSSharingServicePicker?
    private var pathExport: (revision: Int, url: URL)?
    /// "Listo" ya está codificando: un segundo Enter no debe guardar dos veces.
    private var isFinishing = false

    private var sizeValue: ValueChip?
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
        canvas.onToolShortcut = { [weak self] tool in self?.select(tool: tool) }

        backgroundPanel.onChange = { [weak self] backdrop, finished in
            guard let self else { return }
            self.canvas.setBackdrop(backdrop, finished: finished)
            self.refreshZoomLabel()
        }
        backgroundPanel.onPickPicture = { [weak self] in self?.pickBackdropPicture() }

        scrollView.onResize = { [weak self] in self?.fitCanvas() }
        fitCanvas()

        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView,
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

    /// Dibujo de cada herramienta en la barra.
    private func toolContent(_ tool: AnnotationTool) -> PillControl.Content {
        switch tool {
        case .select: return .icon(.cursor)
        case .rectangle: return .icon(.rectangle)
        case .ellipse: return .icon(.ellipse)
        case .arrow: return .icon(.arrow)
        case .text: return .icon(.letter)
        case .pixelate: return .icon(.mosaic)
        case .spotlight: return .icon(.focus)
        case .counter: return .icon(.number)
        default: return .symbol(tool.symbol)
        }
    }

    /// Una sola fila junto a los semáforos: imagen, herramientas, estilo y, a la derecha, las salidas.
    private func buildTopBar(in content: NSView) {
        let barHeight = Design.editorBar
        let bar = EditorBar(
            frame: CGRect(x: 0, y: content.bounds.height - barHeight, width: content.bounds.width, height: barHeight),
            lineAtBottom: true
        )
        bar.autoresizingMask = [.width, .minYMargin]

        // Empieza después de los semáforos.
        var x: CGFloat = 84
        func place(_ view: NSView, gap: CGFloat) {
            view.frame.origin = CGPoint(x: x, y: ((barHeight - view.frame.height) / 2).rounded())
            bar.addSubview(view)
            x += view.frame.width + gap
        }
        func imagePill(_ content: PillControl.Content, tooltip: String, action: Selector) -> PillControl {
            PillControl(content: content, width: Design.imagePillWidth, tooltip: tooltip, chevron: false, target: self, action: action)
        }
        func stripButton(_ content: PillControl.Content, tooltip: String, action: Selector) -> PillControl {
            let button = PillControl(content: content, width: Design.toolSize, surface: .clear, tooltip: tooltip, chevron: false, target: self, action: action)
            toolStrip.add(button)
            return button
        }
        func addTool(_ tool: AnnotationTool) {
            let button = stripButton(toolContent(tool), tooltip: "\(tool.label) (\(tool.key))", action: #selector(toolPressed(_:)))
            button.tag = tool.rawValue
            toolButtons[tool] = button
        }

        // Grupo de imagen: tres píldoras separadas.
        let crop = imagePill(.symbol(AnnotationTool.crop.symbol), tooltip: "\(AnnotationTool.crop.label) (\(AnnotationTool.crop.key))", action: #selector(toolPressed(_:)))
        crop.tag = AnnotationTool.crop.rawValue
        crop.symbolSize = 15
        place(crop, gap: 6)
        toolButtons[.crop] = crop
        place(imagePill(.icon(.picture), tooltip: "Imagen: rotar, voltear, tamaño", action: #selector(imagePressed(_:))), gap: 6)
        let background = imagePill(.icon(.backdrop), tooltip: "Fondo", action: #selector(backgroundPressed))
        place(background, gap: 12)
        backgroundButton = background

        // Herramientas.
        addTool(.select)
        addTool(.rectangle)
        filledButton = stripButton(.icon(.filledRectangle), tooltip: "Cuadro relleno", action: #selector(filledPressed))
        addTool(.ellipse)
        addTool(.arrow)
        addTool(.text)
        addTool(.pixelate)
        addTool(.spotlight)
        addTool(.counter)
        addTool(.pencil)
        addTool(.highlight)
        addTool(.eraser)
        toolStrip.relayout()
        place(toolStrip, gap: 12)

        // Píldoras de estilo: sustituyen a la antigua fila de opciones.
        let color = PillControl(content: .dot(penColor), width: Design.stylePillWidth, tooltip: "Color", target: self, action: #selector(swatchPressed(_:)))
        place(color, gap: 6)
        colorPill = color
        let width = PillControl(content: .stroke(5), width: Design.stylePillWidth, tooltip: "Grosor", target: self, action: #selector(widthPressed(_:)))
        place(width, gap: 6)
        widthPill = width
        let line = PillControl(content: .icon(.arrow), width: Design.stylePillWidth, tooltip: "Tipo de línea", target: self, action: #selector(linePressed(_:)))
        place(line, gap: 6)
        linePill = line

        // Salidas, pegadas a la derecha.
        let doneTitle = "Listo"
        let done = PillControl(
            content: .text(doneTitle),
            width: PillControl.width(for: doneTitle, weight: .semibold),
            surface: .accent,
            tooltip: "Copiar, guardar y cerrar (⏎)",
            chevron: false,
            target: self,
            action: #selector(copyAndClose)
        )
        done.textWeight = .semibold
        done.keyEquivalent = "\r"
        done.setAccessibilityLabel(doneTitle)
        let saveTitle = "Guardar como…"
        let save = PillControl(
            content: .text(saveTitle),
            width: PillControl.width(for: saveTitle, weight: .medium),
            tooltip: saveTitle,
            chevron: false,
            target: self,
            action: #selector(savePressed(_:))
        )

        var right = bar.bounds.width - 12
        for button in [done, save] {
            right -= button.frame.width
            button.frame.origin = CGPoint(x: right, y: ((barHeight - button.frame.height) / 2).rounded())
            button.autoresizingMask = [.minXMargin]
            bar.addSubview(button)
            right -= Design.barGap
        }

        content.addSubview(bar)
        window.topBar = bar
    }

    /// Zoom e historia a la izquierda, arrastre al centro, salidas rápidas a la derecha.
    private func buildBottomBar(in content: NSView) {
        let barHeight = Design.editorBottomBar
        let size = Design.toolSize
        let bar = EditorBar(frame: CGRect(x: 0, y: 0, width: content.bounds.width, height: barHeight), lineAtBottom: false)
        bar.autoresizingMask = [.width, .maxYMargin]
        let middle = ((barHeight - size) / 2).rounded()

        var x: CGFloat = 12
        func place(_ view: NSView, gap: CGFloat) {
            view.frame.origin = CGPoint(x: x, y: middle)
            bar.addSubview(view)
            x += view.frame.width + gap
        }
        func historyButton(_ symbol: String, tooltip: String, target: AnyObject, action: Selector) -> PillControl {
            let button = PillControl(content: .symbol(symbol), width: size, surface: .clear, tooltip: tooltip, chevron: false, target: target, action: action)
            button.symbolSize = 13
            return button
        }

        let zoom = PillControl(content: .text("100%"), width: 68, tooltip: "Zoom", target: self, action: #selector(zoomPressed(_:)))
        place(zoom, gap: 8)
        zoomPill = zoom

        let undo = historyButton("arrow.uturn.backward", tooltip: "Deshacer (⌘Z)", target: canvas, action: #selector(AnnotationCanvas.undo(_:)))
        place(undo, gap: 2)
        undoButton = undo
        let redo = historyButton("arrow.uturn.forward", tooltip: "Rehacer (⇧⌘Z)", target: canvas, action: #selector(AnnotationCanvas.redo(_:)))
        place(redo, gap: 2)
        redoButton = redo
        let text = historyButton("text.viewfinder", tooltip: "Seleccionar texto en la imagen", target: self, action: #selector(toggleTextMode))
        place(text, gap: 2)
        textButton = text

        let dragWidth = Design.dragPillWidth
        let drag = DragPill(frame: CGRect(x: ((bar.bounds.width - dragWidth) / 2).rounded(), y: middle, width: dragWidth, height: size))
        drag.autoresizingMask = [.minXMargin, .maxXMargin]
        drag.fileProvider = { [weak self] in self?.exportTemporaryFile() }
        bar.addSubview(drag)

        func action(_ symbol: String, tooltip: String, _ selector: Selector) -> PillControl {
            PillControl(content: .symbol(symbol), width: Design.bottomActionWidth, raised: true, tooltip: tooltip, chevron: false, target: self, action: selector)
        }
        let buttons = [
            action("square.and.arrow.up", tooltip: "Compartir", #selector(sharePressed(_:))),
            action("pin.fill", tooltip: "Fijar en la pantalla", #selector(pinPressed)),
            action("doc.on.doc.fill", tooltip: "Copiar sin cerrar (⌘C)", #selector(quickCopy)),
            action("terminal.fill", tooltip: "Copiar ruta para un agente", #selector(copyPathPressed)),
        ]
        // Cada una trae aire para su sombra: la forma visible sigue alineada con el resto.
        let room = PillControl.shadowRoom
        var right = bar.bounds.width - 12
        for button in buttons.reversed() {
            right -= Design.bottomActionWidth
            button.frame.origin = CGPoint(x: right - room, y: middle - room)
            button.autoresizingMask = [.minXMargin]
            bar.addSubview(button)
            right -= Design.barGap
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
        refreshZoomLabel()
    }

    /// Algo cambió en el documento, también al deshacer o al abrir un proyecto.
    private func documentChanged() {
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
        refreshZoomLabel()
        if panelOpen {
            backgroundPanel.reload(canvas.document.backdrop, capture: canvas.currentImage)
        }
    }

    private func select(tool: AnnotationTool) {
        canvas.commitText()
        closeTextMode()
        stylePopover?.performClose(nil)
        canvas.tool = tool
        canvas.color = tool == .highlight ? markerColor : penColor
        if let size = toolSizes[tool] {
            canvas.lineWidth = size
        }
        refreshToolButtons()
        refreshStyleControls()
    }

    /// Fondo azul solo en la activa. Cuadro y cuadro relleno son la misma herramienta.
    private func refreshToolButtons() {
        for (candidate, button) in toolButtons {
            button.isActive = candidate == canvas.tool && !(candidate == .rectangle && canvas.filled)
        }
        filledButton?.isActive = canvas.tool == .rectangle && canvas.filled

        // La misma herramienta traza flecha o línea: el botón muestra cuál.
        toolButtons[.arrow]?.content = .icon(canvas.plainLine ? .line : .arrow)

        let lit = canvas.tool == .rectangle && canvas.filled ? filledButton : toolButtons[canvas.tool]
        toolStrip.active = canvas.tool == .crop ? nil : lit
    }

    /// Dibujo de la variante elegida, en las herramientas que tienen más de una.
    private var lineContent: PillControl.Content? {
        switch canvas.tool {
        case .arrow: return .icon(canvas.plainLine ? .line : .arrow)
        case .rectangle: return .icon(canvas.filled ? .filledRectangle : .rectangle)
        case .pixelate: return canvas.smoothBlur ? .symbol("drop.fill") : .icon(.mosaic)
        default: return nil
        }
    }

    private func refreshStyleControls() {
        let tool = canvas.tool
        colorPill?.isEnabled = ![.eraser, .pixelate, .crop, .spotlight, .select].contains(tool)
        colorPill?.content = .dot(canvas.color)
        colorPill?.setAccessibilityValue(colorName(canvas.color))

        widthPill?.isEnabled = [.pencil, .highlight, .eraser, .pixelate, .rectangle, .ellipse, .arrow, .text, .counter].contains(tool)
        widthPill?.content = .stroke(canvas.lineWidth)
        widthPill?.setAccessibilityValue("\(Int(canvas.lineWidth))")

        // Las tres píldoras no se mueven: sin variantes, esta solo se apaga.
        let variant = lineContent
        linePill?.isEnabled = variant != nil
        if let variant {
            linePill?.content = variant
        }
    }

    private func colorName(_ color: NSColor) -> String {
        (Self.palette + Self.markers).first { Self.sameColor($0.1, color) }?.0 ?? "Color propio"
    }

    @objc private func blurStyleChanged(_ sender: NSSegmentedControl) {
        canvas.smoothBlur = sender.selectedSegment == 1
        refreshStyleControls()
    }

    @objc private func fillChanged(_ sender: NSSegmentedControl) {
        canvas.filled = sender.selectedSegment == 1
        refreshToolButtons()
        refreshStyleControls()
    }

    @objc private func lineChanged(_ sender: NSSegmentedControl) {
        canvas.plainLine = sender.selectedSegment == 1
        refreshToolButtons()
        refreshStyleControls()
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
        colorPill?.content = .dot(color)
        colorPill?.setAccessibilityValue(colorName(color))
    }

    @objc private func toolPressed(_ sender: NSButton) {
        if let tool = AnnotationTool(rawValue: sender.tag) {
            if tool == .rectangle {
                canvas.filled = false
            }
            select(tool: tool)
        }
    }

    @objc private func filledPressed() {
        canvas.filled = true
        select(tool: .rectangle)
    }

    // MARK: - Popovers de estilo

    /// Abre o cierra una píldora. Pulsar la misma con su popover abierto debe cerrarlo:
    /// el sistema ya lo cerró al apretar el botón, y no hay que volver a abrirlo al soltar.
    private func togglePopover(_ kind: StylePopover, from sender: NSView, content: () -> NSView) {
        if stylePopover?.isShown == true, openPopover == kind {
            stylePopover?.performClose(nil)
            return
        }
        if let popoverClosed, popoverClosed.kind == kind, Date().timeIntervalSince(popoverClosed.at) < 0.25 {
            self.popoverClosed = nil
            return
        }
        stylePopover?.close()

        let controller = NSViewController()
        controller.view = content()
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = !Design.reduceMotion
        popover.delegate = self
        stylePopover = popover
        openPopover = kind
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === stylePopover, let openPopover else { return }
        popoverClosed = (openPopover, Date())
        stylePopover = nil
        self.openPopover = nil
    }

    @objc private func swatchPressed(_ sender: NSButton) {
        togglePopover(.color, from: sender) { buildPalette() }
    }

    @objc private func widthPressed(_ sender: NSButton) {
        togglePopover(.size, from: sender) { buildSizeControls() }
    }

    @objc private func linePressed(_ sender: NSButton) {
        togglePopover(.line, from: sender) { buildLineControls() }
    }

    /// Mini paleta: solo color. El grosor y el tipo de línea tienen su propia píldora.
    private func buildPalette() -> NSView {
        let tool = canvas.tool
        let colors = tool == .highlight ? Self.markers : Self.palette
        let side: CGFloat = 12
        let dot: CGFloat = 26
        let gap: CGFloat = 3
        let width = side * 2 + CGFloat(colors.count) * dot + CGFloat(colors.count - 1) * gap
        let wide = max(width, 196)
        let height: CGFloat = tool == .highlight ? 50 : 88
        let view = PopoverSurface(frame: CGRect(x: 0, y: 0, width: wide, height: height))

        var x = ((wide - width) / 2).rounded() + side
        let y = height - 12 - dot
        for (index, entry) in colors.enumerated() {
            let button = DotButton(color: entry.1, diameter: 18, tooltip: entry.0, target: self, action: #selector(colorPressed(_:)))
            button.tag = index
            button.frame.origin = CGPoint(x: x, y: y)
            button.isActive = Self.sameColor(entry.1, canvas.color)
            button.setAccessibilityLabel(entry.0)
            view.addSubview(button)
            x += dot + gap
        }
        guard tool != .highlight else { return view }

        let well = NSColorWell(frame: CGRect(x: 12, y: 12, width: 34, height: 24))
        well.color = canvas.color
        well.target = self
        well.action = #selector(wellChanged(_:))
        well.setAccessibilityLabel("Cualquier color")
        view.addSubview(well)
        let label = NSTextField(labelWithString: "Cualquier color")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Palette.text
        label.sizeToFit()
        label.frame.origin = CGPoint(x: 54, y: 16)
        view.addSubview(label)
        let picker = GlassButton(symbol: "eyedropper", tooltip: "Tomar un color de la pantalla", target: self, action: #selector(sampleColor), size: 28)
        picker.frame.origin = CGPoint(x: wide - 40, y: 10)
        view.addSubview(picker)
        return view
    }

    /// Lo que antes estaba a la vista en la fila de opciones: tamaño e intensidad.
    private func buildSizeControls() -> NSView {
        let tool = canvas.tool
        let showsSize = tool != .pixelate || canvas.pixelBrush
        let showsStrength = tool == .pixelate
        let rowHeight: CGFloat = 30
        let width: CGFloat = 262
        let rows = (showsSize ? 1 : 0) + (showsStrength ? 1 : 0)
        let height = CGFloat(max(rows, 1)) * rowHeight + 14
        let view = PopoverSurface(frame: CGRect(x: 0, y: 0, width: width, height: height))
        var y = height - 7 - rowHeight

        func addLabel(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = Palette.text
            label.frame = CGRect(x: 12, y: y + 7, width: 72, height: 16)
            view.addSubview(label)
        }

        if showsSize, let size = Self.sizes[tool] {
            addLabel("Tamaño")
            let slider = ZasSlider(value: Double(canvas.lineWidth), minValue: Double(size.0), maxValue: Double(size.1), target: self, action: #selector(sizeChanged(_:)))
            slider.frame = CGRect(x: 86, y: y + 6, width: 120, height: 18)
            slider.setAccessibilityLabel("Tamaño")
            view.addSubview(slider)

            let value = ValueChip(text: "\(Int(canvas.lineWidth))", fill: Palette.pill)
            value.frame.origin = CGPoint(x: width - 12 - value.frame.width, y: y + 4)
            view.addSubview(value)
            sizeValue = value
            y -= rowHeight
        }

        if showsStrength {
            addLabel("Intensidad")
            let blocks = ZasSlider(value: Double(canvas.blockSize), minValue: 6, maxValue: 40, target: self, action: #selector(blockChanged(_:)))
            blocks.frame = CGRect(x: 86, y: y + 6, width: 164, height: 18)
            blocks.setAccessibilityLabel("Intensidad")
            view.addSubview(blocks)
        }
        return view
    }

    /// Variantes de la herramienta: flecha o línea, contorno o relleno, tipo de censura.
    private func buildLineControls() -> NSView {
        var rows: [NSSegmentedControl] = []
        func addSegment(_ labels: [String], selected: Int, name: String, action: Selector) {
            let mode = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
            mode.selectedSegment = selected
            mode.controlSize = .small
            mode.setAccessibilityLabel(name)
            mode.sizeToFit()
            rows.append(mode)
        }
        switch canvas.tool {
        case .pixelate:
            addSegment(["Pixelado", "Desenfoque"], selected: canvas.smoothBlur ? 1 : 0, name: "Tipo de censura", action: #selector(blurStyleChanged(_:)))
            addSegment(["Recuadro", "Pincel"], selected: canvas.pixelBrush ? 1 : 0, name: "Forma de la censura", action: #selector(pixelModeChanged(_:)))
        case .rectangle:
            addSegment(["Contorno", "Relleno"], selected: canvas.filled ? 1 : 0, name: "Tipo de cuadro", action: #selector(fillChanged(_:)))
        default:
            addSegment(["Flecha", "Línea"], selected: canvas.plainLine ? 1 : 0, name: "Tipo de línea", action: #selector(lineChanged(_:)))
        }

        let width = (rows.map { $0.frame.width }.max() ?? 120) + 24
        let height = CGFloat(rows.count) * 30 + 14
        let view = PopoverSurface(frame: CGRect(x: 0, y: 0, width: width, height: height))
        var y = height - 12 - 22
        for row in rows {
            row.frame.origin = CGPoint(x: ((width - row.frame.width) / 2).rounded(), y: y)
            view.addSubview(row)
            y -= 30
        }
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
        stylePopover?.performClose(nil)
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

    @objc private func wellChanged(_ sender: NSColorWell) {
        setColor(sender.color)
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        let value = CGFloat(sender.doubleValue.rounded())
        toolSizes[canvas.tool] = value
        canvas.lineWidth = value
        sizeValue?.text = "\(Int(value))"
        widthPill?.content = .stroke(value)
        widthPill?.setAccessibilityValue("\(Int(value))")
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

    private func setMagnification(_ value: CGFloat) {
        if Design.reduceMotion {
            scrollView.magnification = value
            refreshZoomLabel()
            return
        }
        scrollView.animator().magnification = value
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            self?.refreshZoomLabel()
        }
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
        select(tool: tool)
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

        TextReader.read(image: snapshot.pixels) { text in
            guard !text.isEmpty else {
                Toast.shared.show("No hay texto en esta captura")
                return
            }
            Capture.copyText(text)
            Sounds.play(.copy)
            Toast.shared.show("Texto copiado")
        }

        let pane = LiveTextPane(frame: scrollView.frame, image: snapshot.image, inset: canvas.fitInset)
        pane.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(pane, positioned: .above, relativeTo: scrollView)
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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: sender)
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

    func testOpenPalette() {
        if let colorPill {
            swatchPressed(colorPill)
        }
    }

    func testOpenSizePopover() {
        if let widthPill {
            widthPressed(widthPill)
        }
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

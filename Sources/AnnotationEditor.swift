import AppKit
import VisionKit

/// Punto de color en la paleta.
private final class DotButton: NSButton {
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
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2
            ring.stroke()
        }
        (dotColor ?? NSColor.labelColor).setFill()
        let radius = dotDiameter / 2
        let dot = NSBezierPath(ovalIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: dotDiameter,
            height: dotDiameter
        ))
        dot.fill()
        // Contorno visible: si no, el blanco desaparece sobre la barra clara.
        NSColor.tertiaryLabelColor.setStroke()
        dot.lineWidth = 1
        dot.stroke()
    }
}

/// Imagen con Live Text: el texto se selecciona sobre la captura, igual que en Fotos o Vista Previa.
@MainActor
private final class LiveTextPane: NSView {
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()

    init(frame: CGRect, image: NSImage) {
        super.init(frame: frame)
        imageView.frame = bounds
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        overlay.frame = bounds
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
        guard ImageAnalyzer.isSupported, let image = imageView.image else { return false }
        let analyzer = ImageAnalyzer()
        let configuration = ImageAnalyzer.Configuration([.text])
        guard let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: configuration) else {
            return false
        }
        overlay.analysis = analysis
        return true
    }
}

/// Ventana de anotación. "Listo" reemplaza el portapapeles, guarda una copia y cierra.
@MainActor
final class AnnotationEditor: NSObject, NSWindowDelegate {
    var onFinish: ((NSImage, URL) -> Void)?
    var onClose: (() -> Void)?

    private static let palette: [(String, NSColor)] = [
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

    private let image: NSImage
    private let file: URL
    let canvas: AnnotationCanvas
    private let scrollView: NSScrollView
    private let window: NSWindow
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private let targetScreen: NSScreen

    private var toolButtons: [AnnotationTool: GlassButton] = [:]
    private var colorSwatch: DotButton?
    private let colorPopover = NSPopover()
    private var undoButton: GlassButton?
    private var redoButton: GlassButton?
    private var saveButton: GlassButton?
    private var textButton: GlassButton?
    private var zoomLabel: NSTextField?
    private var subBar: GlassView?
    private var liveText: LiveTextPane?
    private var escapeMonitor: Any?

    private var penColor: NSColor = .systemRed
    private var markerColor = AnnotationEditor.markers[0].1
    private var toolSizes: [AnnotationTool: CGFloat] = [:]
    private var savedHistoryCount = 0

    init(image: NSImage, file: URL) {
        self.image = image
        self.file = file

        let toolbarHeight: CGFloat = 62
        let padding: CGFloat = 24
        let minimumWidth: CGFloat = 900
        let minimumHeight: CGFloat = 340

        let screen = NSScreen.underMouse
        targetScreen = screen
        let visible = screen.visibleFrame.insetBy(dx: 40, dy: 30)
        let fit = min(
            1,
            (visible.width - padding * 2) / max(image.size.width, 1),
            (visible.height - toolbarHeight - padding * 2) / max(image.size.height, 1)
        )
        let imageWidth = (image.size.width * fit).rounded()
        let imageHeight = (image.size.height * fit).rounded()
        let contentSize = CGSize(
            width: max(imageWidth + padding * 2, minimumWidth),
            height: max(imageHeight + padding * 2 + toolbarHeight, minimumHeight)
        )

        let area = CGRect(
            x: padding,
            y: padding,
            width: contentSize.width - padding * 2,
            height: contentSize.height - toolbarHeight - padding * 2
        )
        canvas = AnnotationCanvas(frame: CGRect(origin: .zero, size: area.size), image: image)
        scrollView = NSScrollView(frame: area)
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = "Anotar captura"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 8

        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: contentSize))
        content.material = .underWindowBackground
        content.blendingMode = .behindWindow
        content.state = .followsWindowActiveState
        content.addSubview(scrollView)
        buildToolbar(in: content)
        buildZoomControls(in: content)
        window.contentView = content

        for (tool, size) in Self.sizes {
            toolSizes[tool] = size.2
        }

        canvas.onHistoryChanged = { [weak self] in self?.refreshHistoryButtons() }
        canvas.onRequestClose = { [weak self] in self?.window.performClose(nil) }
        canvas.onRequestCopy = { [weak self] in self?.quickCopy() }
        canvas.onRequestSave = { [weak self] in self?.saveCopy() }
        canvas.onRequestZoom = { [weak self] step in self?.zoom(by: step) }
        canvas.onToolShortcut = { [weak self] tool in self?.select(tool: tool) }

        NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshZoomLabel()
            }
        }

        select(tool: .arrow)
        refreshHistoryButtons()
    }

    /// Barra de vidrio flotante.
    private func buildToolbar(in content: NSView) {
        let tools: [AnnotationTool] = [
            .select, .arrow, .rectangle, .ellipse, .pencil, .highlight, .text, .counter, .pixelate, .spotlight, .eraser, .crop,
        ]
        let padding: CGFloat = 6
        let barHeight = Design.actionSize + padding * 2

        let bar = GlassView(frame: .zero, radius: 14)
        var x = padding
        func place(_ view: NSView, gap: CGFloat = 2) {
            view.frame.origin = CGPoint(x: x, y: ((barHeight - view.frame.height) / 2).rounded())
            bar.addSubview(view)
            x += view.frame.width + gap
        }

        for tool in tools {
            let button = GlassButton(
                symbol: tool.symbol,
                tooltip: "\(tool.label) (\(tool.key))",
                target: self,
                action: #selector(toolPressed(_:))
            )
            button.tag = tool.rawValue
            place(button)
            toolButtons[tool] = button
        }

        x += 6
        let swatch = DotButton(color: penColor, diameter: 18, tooltip: "Color y tamaño", target: self, action: #selector(swatchPressed(_:)))
        place(swatch, gap: 10)
        colorSwatch = swatch

        let undo = GlassButton(symbol: "arrow.uturn.backward", tooltip: "Deshacer (⌘Z)", target: canvas, action: #selector(AnnotationCanvas.undo(_:)))
        place(undo)
        undoButton = undo
        let redo = GlassButton(symbol: "arrow.uturn.forward", tooltip: "Rehacer (⇧⌘Z)", target: canvas, action: #selector(AnnotationCanvas.redo(_:)))
        place(redo, gap: 10)
        redoButton = redo

        place(GlassButton(symbol: "doc.on.doc", tooltip: "Copiar sin cerrar (⌘C)", target: self, action: #selector(quickCopy)))
        let save = GlassButton(symbol: "square.and.arrow.down", tooltip: "Guardar", target: self, action: #selector(savePressed(_:)))
        place(save)
        saveButton = save
        place(GlassButton(symbol: "photo.on.rectangle", tooltip: "Imagen: rotar, fondo, tamaño", target: self, action: #selector(imagePressed(_:))))
        let text = GlassButton(symbol: "text.viewfinder", tooltip: "Seleccionar texto en la imagen", target: self, action: #selector(toggleTextMode))
        place(text, gap: 8)
        textButton = text

        let done = NSButton(title: "Listo", target: self, action: #selector(copyAndClose))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.sizeToFit()
        place(done, gap: padding + 2)

        bar.frame = CGRect(
            x: ((content.bounds.width - x) / 2).rounded(),
            y: content.bounds.height - barHeight - 10,
            width: x,
            height: barHeight
        )
        bar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        content.addSubview(bar)
    }

    private func buildZoomControls(in content: NSView) {
        let pill = GlassView(frame: CGRect(x: 0, y: 0, width: 186, height: 34), radius: 11)
        let out = GlassButton(symbol: "minus", tooltip: "Alejar (⌘-)", target: self, action: #selector(zoomOut), size: 28)
        out.frame.origin = CGPoint(x: 3, y: 3)
        pill.addSubview(out)

        let label = NSTextField(labelWithString: "100 %")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.frame = CGRect(x: 32, y: 9, width: 50, height: 16)
        pill.addSubview(label)
        zoomLabel = label

        let plus = GlassButton(symbol: "plus", tooltip: "Acercar (⌘+)", target: self, action: #selector(zoomIn), size: 28)
        plus.frame.origin = CGPoint(x: 84, y: 3)
        pill.addSubview(plus)

        let fit = NSButton(title: "Ajustar", target: self, action: #selector(zoomFit))
        fit.isBordered = false
        fit.font = .systemFont(ofSize: 12, weight: .medium)
        fit.frame = CGRect(x: 116, y: 6, width: 64, height: 22)
        fit.toolTip = "Ver toda la imagen (⌘0)"
        pill.addSubview(fit)

        pill.frame.origin = CGPoint(x: content.bounds.maxX - pill.frame.width - 12, y: 10)
        pill.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(pill)
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
    }

    private func refreshHistoryButtons() {
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
    }

    private func select(tool: AnnotationTool) {
        canvas.commitText()
        closeTextMode()
        colorPopover.performClose(nil)
        canvas.tool = tool
        canvas.color = tool == .highlight ? markerColor : penColor
        if let size = toolSizes[tool] {
            canvas.lineWidth = size
        }
        colorSwatch?.dotColor = canvas.color
        for (candidate, button) in toolButtons {
            button.isActive = candidate == tool
        }
        buildSubBar()
    }

    /// Las herramientas de pincel muestran su tamaño a la vista, sin abrir nada.
    private func buildSubBar() {
        subBar?.removeFromSuperview()
        subBar = nil
        let tool = canvas.tool
        guard [.pencil, .highlight, .eraser, .pixelate, .rectangle, .arrow].contains(tool),
              let size = Self.sizes[tool], let content = window.contentView
        else { return }

        let bar = GlassView(frame: .zero, radius: 12)
        var x: CGFloat = 12
        func addSegment(_ labels: [String], selected: Int, action: Selector) {
            let mode = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
            mode.selectedSegment = selected
            mode.controlSize = .small
            mode.sizeToFit()
            mode.frame.origin = CGPoint(x: x, y: 9)
            bar.addSubview(mode)
            x += mode.frame.width + 12
        }
        if tool == .pixelate {
            addSegment(["Pixelado", "Desenfoque"], selected: canvas.smoothBlur ? 1 : 0, action: #selector(blurStyleChanged(_:)))
            addSegment(["Recuadro", "Pincel"], selected: canvas.pixelBrush ? 1 : 0, action: #selector(pixelModeChanged(_:)))
        }
        if tool == .rectangle {
            addSegment(["Contorno", "Relleno"], selected: canvas.filled ? 1 : 0, action: #selector(fillChanged(_:)))
        }
        if tool == .arrow {
            addSegment(["Flecha", "Línea"], selected: canvas.plainLine ? 1 : 0, action: #selector(lineChanged(_:)))
        }

        let sizeEnabled = tool != .pixelate || canvas.pixelBrush
        let label = NSTextField(labelWithString: "Tamaño")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = sizeEnabled ? .labelColor : .tertiaryLabelColor
        label.sizeToFit()
        label.frame.origin = CGPoint(x: x, y: 11)
        bar.addSubview(label)
        x += label.frame.width + 8

        let slider = NSSlider(value: Double(canvas.lineWidth), minValue: Double(size.0), maxValue: Double(size.1), target: self, action: #selector(sizeChanged(_:)))
        slider.isEnabled = sizeEnabled
        slider.frame = CGRect(x: x, y: 8, width: 120, height: 22)
        bar.addSubview(slider)
        x += 128

        let value = NSTextField(labelWithString: "\(Int(canvas.lineWidth))")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.alignment = .right
        value.frame = CGRect(x: x, y: 11, width: 24, height: 16)
        value.tag = 77
        bar.addSubview(value)
        x += 34

        if tool == .pixelate {
            let strength = NSTextField(labelWithString: "Intensidad")
            strength.font = .systemFont(ofSize: 12, weight: .medium)
            strength.sizeToFit()
            strength.frame.origin = CGPoint(x: x, y: 11)
            bar.addSubview(strength)
            x += strength.frame.width + 8
            let blocks = NSSlider(value: Double(canvas.blockSize), minValue: 6, maxValue: 40, target: self, action: #selector(blockChanged(_:)))
            blocks.frame = CGRect(x: x, y: 8, width: 100, height: 22)
            bar.addSubview(blocks)
            x += 112
        }

        bar.frame = CGRect(
            x: ((content.bounds.width - x) / 2).rounded(),
            y: content.bounds.height - 62 - 44,
            width: x,
            height: 38
        )
        bar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        content.addSubview(bar)
        subBar = bar
    }

    @objc private func blurStyleChanged(_ sender: NSSegmentedControl) {
        canvas.smoothBlur = sender.selectedSegment == 1
    }

    @objc private func fillChanged(_ sender: NSSegmentedControl) {
        canvas.filled = sender.selectedSegment == 1
    }

    @objc private func lineChanged(_ sender: NSSegmentedControl) {
        canvas.plainLine = sender.selectedSegment == 1
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
            add("\(percent) %", #selector(resizeImage(_:)), tag: percent, to: sizes)
        }
        menu.addItem(withTitle: "Cambiar tamaño", action: nil, keyEquivalent: "").submenu = sizes
        let fonts = NSMenu()
        for (index, entry) in ImageTools.backgrounds.enumerated() {
            add(entry.name, #selector(addBackground(_:)), tag: index, to: fonts)
        }
        menu.addItem(withTitle: "Añadir fondo", action: nil, keyEquivalent: "").submenu = fonts
        menu.addItem(.separator())
        add("Añadir otra imagen…", #selector(addOtherImage))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
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

    @objc private func addBackground(_ sender: NSMenuItem) {
        canvas.applyImage { ImageTools.withBackground($0, colors: ImageTools.backgrounds[sender.tag].colors) }
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

    @objc private func pixelModeChanged(_ sender: NSSegmentedControl) {
        canvas.pixelBrush = sender.selectedSegment == 1
        buildSubBar()
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
        colorSwatch?.dotColor = color
    }

    @objc private func toolPressed(_ sender: NSButton) {
        if let tool = AnnotationTool(rawValue: sender.tag) {
            select(tool: tool)
        }
    }

    // MARK: - Mini paleta

    @objc private func swatchPressed(_ sender: NSButton) {
        if colorPopover.isShown {
            colorPopover.performClose(nil)
            return
        }
        let controller = NSViewController()
        controller.view = buildPalette()
        colorPopover.contentViewController = controller
        colorPopover.behavior = .transient
        colorPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// Cada herramienta muestra solo lo que le sirve.
    private func buildPalette() -> NSView {
        let tool = canvas.tool
        let showsColor = tool != .eraser && tool != .pixelate && tool != .crop && tool != .spotlight
        let colors = tool == .highlight ? Self.markers : Self.palette
        let size = Self.sizes[tool]

        let width: CGFloat = 12 * 2 + 8 * 29
        var height: CGFloat = 12
        if showsColor { height += 30 }
        if showsColor, tool != .highlight { height += 34 }
        if size != nil { height += 38 }
        if !showsColor, size == nil { height += 24 }
        height += 8
        let view = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))

        var y = height - 12
        if showsColor {
            y -= 26
            var x: CGFloat = 12
            for (index, entry) in colors.enumerated() {
                let button = DotButton(color: entry.1, diameter: 18, tooltip: entry.0, target: self, action: #selector(colorPressed(_:)))
                button.tag = index
                button.frame.origin = CGPoint(x: x, y: y)
                button.isActive = Self.sameColor(entry.1, canvas.color)
                view.addSubview(button)
                x += 29
            }
            y -= 4
        }
        if showsColor, tool != .highlight {
            y -= 30
            let well = NSColorWell(frame: CGRect(x: 12, y: y + 2, width: 34, height: 24))
            well.color = canvas.color
            well.target = self
            well.action = #selector(wellChanged(_:))
            view.addSubview(well)
            let label = NSTextField(labelWithString: "Cualquier color")
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.sizeToFit()
            label.frame.origin = CGPoint(x: 54, y: y + 6)
            view.addSubview(label)
            let picker = GlassButton(symbol: "eyedropper", tooltip: "Tomar un color de la pantalla", target: self, action: #selector(sampleColor), size: 28)
            picker.frame.origin = CGPoint(x: width - 40, y: y)
            view.addSubview(picker)
            y -= 4
        }
        if let size {
            y -= 32
            let slider = NSSlider(value: Double(canvas.lineWidth), minValue: Double(size.0), maxValue: Double(size.1), target: self, action: #selector(sizeChanged(_:)))
            slider.frame = CGRect(x: 12, y: y + 4, width: width - 60, height: 22)
            view.addSubview(slider)
            let value = NSTextField(labelWithString: "\(Int(canvas.lineWidth))")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            value.alignment = .right
            value.frame = CGRect(x: width - 44, y: y + 7, width: 32, height: 16)
            value.tag = 77
            view.addSubview(value)
        }
        if !showsColor, size == nil {
            let label = NSTextField(labelWithString: "Esta herramienta no tiene opciones.")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.sizeToFit()
            label.frame.origin = CGPoint(x: 12, y: 12)
            view.addSubview(label)
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
        colorPopover.performClose(nil)
    }

    @objc private func sampleColor() {
        colorPopover.performClose(nil)
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
        (sender.superview?.viewWithTag(77) as? NSTextField)?.stringValue = "\(Int(value))"
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
        scrollView.animator().magnification = value
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            self?.refreshZoomLabel()
        }
    }

    @objc private func zoomIn() { setMagnification(min(scrollView.magnification * 1.25, 8)) }
    @objc private func zoomOut() { setMagnification(max(scrollView.magnification / 1.25, 0.25)) }
    @objc private func zoomFit() { setMagnification(1) }

    private func refreshZoomLabel() {
        zoomLabel?.stringValue = "\(Int((scrollView.magnification * 100).rounded())) %"
    }

    // MARK: - Selección de texto

    /// Copia todo el texto al instante y deja seleccionar palabras sobre la imagen.
    @objc private func toggleTextMode() {
        if liveText != nil {
            closeTextMode()
            return
        }
        canvas.commitText()
        guard let data = canvas.exportPNG(), let snapshot = NSImage(data: data) else { return }

        let url = Capture.temporaryFileURL()
        try? data.write(to: url)
        TextReader.read(from: url) { text in
            try? FileManager.default.removeItem(at: url)
            guard !text.isEmpty else {
                Toast.shared.show("No encontré texto en esta captura.")
                return
            }
            Capture.copyText(text)
            Toast.shared.show("Texto copiado. También puedes seleccionarlo sobre la imagen.")
        }

        let pane = LiveTextPane(frame: scrollView.frame, image: snapshot)
        pane.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(pane, positioned: .above, relativeTo: scrollView)
        liveText = pane
        textButton?.isActive = true
        // Al seleccionar, el foco queda en la capa de Apple y Esc nunca llegaría al lienzo.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                self?.closeTextMode()
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
        guard let data = canvas.exportPNG() else { return }
        let url = Capture.temporaryFileURL()
        guard (try? data.write(to: url)) != nil, Capture.copyImage(at: url) != nil else {
            Toast.shared.show("No se pudo copiar.")
            return
        }
        Capture.playSound()
        Toast.shared.show("Copiado")
    }

    @objc private func savePressed(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Guardar una copia con los cambios", action: #selector(saveCopy), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reemplazar el original", action: #selector(replaceOriginal), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Guardar como…", action: #selector(saveAs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Guardar proyecto editable…", action: #selector(saveProject), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    private func nextCopyURL() -> URL {
        let folder = Capture.imageFolder
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
        savedHistoryCount = canvas.historyCount
        return true
    }

    private func announce(_ url: URL) {
        let path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        Toast.shared.show("Guardado en \(path)", seconds: 3.5)
    }

    @objc private func saveCopy() {
        let url = nextCopyURL()
        if write(to: url) {
            announce(url)
        }
    }

    @objc private func replaceOriginal() {
        if write(to: file) {
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
                self.savedHistoryCount = self.canvas.historyCount
                self.announce(url)
            }
        }
    }

    @objc func copyAndClose() {
        canvas.commitText()
        let output = nextCopyURL()
        guard let data = canvas.exportPNG() else {
            Toast.shared.show("No se pudo crear la imagen.")
            return
        }
        guard (try? data.write(to: output)) != nil,
              let copied = Capture.copyImage(at: output)
        else {
            Toast.shared.show("No se pudo guardar. Revisa la carpeta en Ajustes.")
            return
        }

        window.close()
        onFinish?(copied, output)
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
        guard canvas.hasUnsavedMarks, canvas.historyCount != savedHistoryCount else { return true }

        let alert = NSAlert()
        alert.messageText = "¿Cerrar sin copiar?"
        alert.informativeText = "Lo que dibujaste en esta captura se perderá."
        alert.addButton(withTitle: "Copiar y cerrar")
        alert.addButton(withTitle: "Descartar")
        alert.addButton(withTitle: "Seguir editando").keyEquivalent = "\u{1b}"
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

    func windowWillClose(_ notification: Notification) {
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
        if let colorSwatch {
            swatchPressed(colorSwatch)
        }
    }

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
        guard ImageAnalyzer.isSupported, let data = canvas.exportPNG(), let snapshot = NSImage(data: data) else {
            return false
        }
        let analyzer = ImageAnalyzer()
        guard let analysis = try? await analyzer.analyze(
            snapshot,
            orientation: .up,
            configuration: ImageAnalyzer.Configuration([.text])
        ) else { return false }
        return analysis.hasResults(for: .text)
    }
    #endif
}

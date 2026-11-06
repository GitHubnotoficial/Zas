import AppKit

/// Punto de color o de grosor en la barra.
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
        super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
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
        if dotColor != nil {
            // Contorno visible: si no, el blanco desaparece sobre la barra clara.
            NSColor.tertiaryLabelColor.setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
    }
}

/// Ventana de anotación. "Copiar" reemplaza el portapapeles y guarda una copia aparte.
@MainActor
final class AnnotationEditor: NSObject, NSWindowDelegate {
    var onFinish: ((NSImage, URL) -> Void)?
    var onClose: (() -> Void)?

    private static let palette: [(String, NSColor)] = [
        ("Rojo", .systemRed),
        ("Amarillo", .systemYellow),
        ("Verde", .systemGreen),
        ("Azul", .systemBlue),
        ("Negro", .black),
        ("Blanco", .white),
    ]
    private static let lineWidths: [(String, CGFloat, CGFloat)] = [
        ("Fino", 3, 6),
        ("Medio", 5, 10),
        ("Grueso", 9, 15),
    ]

    private let image: NSImage
    private let file: URL
    let canvas: AnnotationCanvas
    private let window: NSWindow
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private let targetScreen: NSScreen

    private var toolButtons: [AnnotationTool: GlassButton] = [:]
    private var colorSwatch: DotButton?
    private let colorPopover = NSPopover()
    private var colorButtons: [DotButton] = []
    private var widthButtons: [DotButton] = []
    private var undoButton: GlassButton?
    private var colorBeforeHighlight: Int?

    init(image: NSImage, file: URL) {
        self.image = image
        self.file = file

        let toolbarHeight: CGFloat = 62
        let padding: CGFloat = 24
        let minimumWidth: CGFloat = 860
        let minimumHeight: CGFloat = 320

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

        canvas = AnnotationCanvas(
            frame: CGRect(
                x: padding,
                y: padding,
                width: contentSize.width - padding * 2,
                height: contentSize.height - toolbarHeight - padding * 2
            ),
            image: image
        )
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

        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: contentSize))
        content.material = .underWindowBackground
        content.blendingMode = .behindWindow
        content.state = .followsWindowActiveState
        content.addSubview(canvas)
        buildToolbar(in: content, height: toolbarHeight)
        window.contentView = content

        canvas.onHistoryChanged = { [weak self] in self?.refreshHistoryButtons() }
        canvas.onRequestClose = { [weak self] in self?.window.performClose(nil) }
        canvas.onRequestCopy = { [weak self] in self?.copyAndClose() }
        canvas.onToolShortcut = { [weak self] tool in self?.select(tool: tool) }

        select(tool: .arrow)
        selectColor(index: 0)
        selectWidth(index: 1)
        refreshHistoryButtons()
    }

    /// Barra de vidrio flotante: ocho herramientas, color, deshacer y copiar.
    /// V (mover) y H (resaltar) siguen en el teclado, sin ocupar sitio.
    private func buildToolbar(in content: NSView, height: CGFloat) {
        let tools: [AnnotationTool] = [.arrow, .rectangle, .ellipse, .pencil, .text, .counter, .pixelate, .crop]
        let padding: CGFloat = 6
        let barHeight = Design.actionSize + padding * 2

        let bar = GlassView(frame: .zero, radius: 14)
        var x = padding
        for tool in tools {
            let button = GlassButton(
                symbol: tool.symbol,
                tooltip: "\(tool.label) (\(tool.key))",
                target: self,
                action: #selector(toolPressed(_:))
            )
            button.tag = tool.rawValue
            button.frame.origin = CGPoint(x: x, y: padding)
            bar.addSubview(button)
            toolButtons[tool] = button
            x += Design.actionSize + 2
        }

        x += 8
        let swatch = DotButton(color: Self.palette[0].1, diameter: 18, tooltip: "Color y grosor", target: self, action: #selector(swatchPressed(_:)))
        swatch.frame = CGRect(x: x, y: (barHeight - 24) / 2, width: 24, height: 24)
        bar.addSubview(swatch)
        colorSwatch = swatch
        x += 24 + 10

        let undo = GlassButton(symbol: "arrow.uturn.backward", tooltip: "Deshacer (⌘Z)", target: canvas, action: #selector(AnnotationCanvas.undo(_:)))
        undo.frame.origin = CGPoint(x: x, y: padding)
        bar.addSubview(undo)
        undoButton = undo
        x += Design.actionSize + 8

        let copy = NSButton(title: "Copiar", target: self, action: #selector(copyAndClose))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        copy.sizeToFit()
        copy.frame.origin = CGPoint(x: x, y: ((barHeight - copy.frame.height) / 2).rounded())
        bar.addSubview(copy)
        x += copy.frame.width + padding + 2

        bar.frame = CGRect(
            x: ((content.bounds.width - x) / 2).rounded(),
            y: content.bounds.height - barHeight - 10,
            width: x,
            height: barHeight
        )
        bar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        content.addSubview(bar)

        buildColorPopover()
    }

    /// Color y grosor aparecen solo cuando se piden.
    private func buildColorPopover() {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 196, height: 76))
        var x: CGFloat = 12
        for (index, entry) in Self.palette.enumerated() {
            let button = DotButton(color: entry.1, diameter: 16, tooltip: entry.0, target: self, action: #selector(colorPressed(_:)))
            button.tag = index
            button.frame = CGRect(x: x, y: 42, width: 24, height: 24)
            view.addSubview(button)
            colorButtons.append(button)
            x += 29
        }
        x = 12
        for (index, entry) in Self.lineWidths.enumerated() {
            let button = DotButton(color: nil, diameter: entry.2, tooltip: entry.0, target: self, action: #selector(widthPressed(_:)))
            button.tag = index
            button.frame = CGRect(x: x, y: 10, width: 24, height: 24)
            view.addSubview(button)
            widthButtons.append(button)
            x += 29
        }
        let controller = NSViewController()
        controller.view = view
        colorPopover.contentViewController = controller
        colorPopover.behavior = .transient
    }

    @objc private func swatchPressed(_ sender: NSButton) {
        colorPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
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
    }

    private func select(tool: AnnotationTool) {
        canvas.commitText()

        // Cambiar de herramienta suelta la selección: si no, el color iría a esa marca.
        let previousTool = canvas.tool
        canvas.tool = tool

        // El resaltador empieza en amarillo y al salir vuelve el color anterior.
        if tool == .highlight, previousTool != .highlight {
            colorBeforeHighlight = colorButtons.firstIndex { $0.isActive }
            selectColor(index: 1)
        } else if tool != .highlight, previousTool == .highlight, let previous = colorBeforeHighlight {
            selectColor(index: previous)
            colorBeforeHighlight = nil
        }

        for (candidate, button) in toolButtons {
            button.isActive = candidate == tool
        }
    }

    private func selectColor(index: Int) {
        canvas.color = Self.palette[index].1
        colorSwatch?.dotColor = Self.palette[index].1
        for (position, button) in colorButtons.enumerated() {
            button.isActive = position == index
        }
    }

    private func selectWidth(index: Int) {
        canvas.lineWidth = Self.lineWidths[index].1
        for (position, button) in widthButtons.enumerated() {
            button.isActive = position == index
        }
    }

    @objc private func toolPressed(_ sender: NSButton) {
        if let tool = AnnotationTool(rawValue: sender.tag) {
            select(tool: tool)
        }
    }

    @objc private func colorPressed(_ sender: NSButton) {
        selectColor(index: sender.tag)
    }

    @objc private func widthPressed(_ sender: NSButton) {
        selectWidth(index: sender.tag)
    }

    @objc func copyAndClose() {
        canvas.commitText()
        guard let data = canvas.exportPNG() else {
            Toast.shared.show("No se pudo crear la imagen.")
            return
        }

        let folder = Capture.imageFolder
        let base = Self.baseName(of: file)
        var output = folder.appendingPathComponent("\(base) anotada.png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = folder.appendingPathComponent("\(base) anotada \(suffix).png")
            suffix += 1
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
        guard canvas.hasUnsavedMarks else { return true }

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
            selectColor(index: colorIndex)
        }
    }
    #endif
}

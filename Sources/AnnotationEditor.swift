import AppKit

/// Botón de herramienta de la barra del editor.
private final class ToolButton: NSButton {
    var isActive = false {
        didSet { refresh() }
    }

    init(symbol: String, tooltip: String, target: AnyObject, action: Selector) {
        super.init(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(configuration)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tooltip
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 7
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        contentTintColor = isActive ? .white : .labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isActive ? NSColor.controlAccentColor : NSColor.clear).cgColor
        }
    }
}

/// Punto de color o de grosor en la barra.
private final class DotButton: NSButton {
    private let dotColor: NSColor?
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
            NSColor.separatorColor.setStroke()
            dot.lineWidth = 0.5
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

    private var toolButtons: [AnnotationTool: ToolButton] = [:]
    private var colorButtons: [DotButton] = []
    private var widthButtons: [DotButton] = []
    private var undoButton: ToolButton?
    private var redoButton: ToolButton?
    private var colorBeforeHighlight: Int?

    init(image: NSImage, file: URL) {
        self.image = image
        self.file = file

        let toolbarHeight: CGFloat = 52
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

        let content = NSView(frame: CGRect(origin: .zero, size: contentSize))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
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

    private func buildToolbar(in content: NSView, height: CGFloat) {
        let bar = NSVisualEffectView(frame: CGRect(
            x: 0,
            y: content.bounds.height - height,
            width: content.bounds.width,
            height: height
        ))
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(bar)

        let separator = NSBox(frame: CGRect(x: 0, y: 0, width: bar.bounds.width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        bar.addSubview(separator)

        let centerY = (height - 32) / 2
        var x: CGFloat = 80

        for tool in AnnotationTool.allCases {
            let button = ToolButton(
                symbol: tool.symbol,
                tooltip: "\(tool.label) (\(tool.key))",
                target: self,
                action: #selector(toolPressed(_:))
            )
            button.tag = tool.rawValue
            button.frame.origin = CGPoint(x: x, y: centerY)
            bar.addSubview(button)
            toolButtons[tool] = button
            x += 34
        }

        x += 12
        for (index, entry) in Self.palette.enumerated() {
            let button = DotButton(
                color: entry.1,
                diameter: 14,
                tooltip: entry.0,
                target: self,
                action: #selector(colorPressed(_:))
            )
            button.tag = index
            button.frame.origin = CGPoint(x: x, y: (height - 24) / 2)
            bar.addSubview(button)
            colorButtons.append(button)
            x += 24
        }

        x += 12
        for (index, entry) in Self.lineWidths.enumerated() {
            let button = DotButton(
                color: nil,
                diameter: entry.2,
                tooltip: entry.0,
                target: self,
                action: #selector(widthPressed(_:))
            )
            button.tag = index
            button.frame.origin = CGPoint(x: x, y: (height - 24) / 2)
            bar.addSubview(button)
            widthButtons.append(button)
            x += 24
        }

        let copy = NSButton(title: "Copiar", target: self, action: #selector(copyAndClose))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "\r"
        copy.controlSize = .large
        copy.sizeToFit()
        copy.frame.origin = CGPoint(
            x: bar.bounds.maxX - copy.frame.width - 14,
            y: ((height - copy.frame.height) / 2).rounded()
        )
        copy.autoresizingMask = [.minXMargin]
        bar.addSubview(copy)

        let redo = ToolButton(
            symbol: "arrow.uturn.forward",
            tooltip: "Rehacer (⇧⌘Z)",
            target: canvas,
            action: #selector(AnnotationCanvas.redo(_:))
        )
        redo.frame.origin = CGPoint(x: copy.frame.minX - 40, y: centerY)
        bar.addSubview(redo)
        redoButton = redo

        let undo = ToolButton(
            symbol: "arrow.uturn.backward",
            tooltip: "Deshacer (⌘Z)",
            target: canvas,
            action: #selector(AnnotationCanvas.undo(_:))
        )
        undo.frame.origin = CGPoint(x: redo.frame.minX - 34, y: centerY)
        bar.addSubview(undo)
        undoButton = undo
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
        guard let data = canvas.exportPNG() else { return }

        let base = file.deletingPathExtension().lastPathComponent
        var output = Capture.folder.appendingPathComponent("\(base) anotada.png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = Capture.folder.appendingPathComponent("\(base) anotada \(suffix).png")
            suffix += 1
        }

        guard (try? data.write(to: output)) != nil,
              let copied = Capture.copyImage(at: output)
        else { return }

        window.close()
        onFinish?(copied, output)
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

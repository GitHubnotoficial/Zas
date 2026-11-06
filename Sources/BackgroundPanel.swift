import AppKit

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Muestra del panel: un degradado, una imagen o un color, con anillo azul en la elegida.
private final class SwatchButton: NSButton {
    var paint: ((CGRect, CGContext) -> Void)? {
        didSet { needsDisplay = true }
    }

    var isChosen = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isChosen ? "Elegido" : nil)
        }
    }

    override var isFlipped: Bool { false }

    private let radius: CGFloat

    init(side: CGFloat, radius: CGFloat, label: String, target: AnyObject, action: Selector) {
        self.radius = radius
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        title = ""
        isBordered = false
        toolTip = label
        self.target = target
        self.action = action
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let area = isChosen ? bounds.insetBy(dx: 3, dy: 3) : bounds
        let inner = max(radius - (isChosen ? 3 : 0), 1)
        let shape = NSBezierPath(roundedRect: area, xRadius: inner, yRadius: inner)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        paint?(area, context)
        NSGraphicsContext.restoreGraphicsState()

        // Contorno suave: si no, las muestras claras se pierden en el panel.
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()

        if isChosen {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

/// Ajuste con nombre guardado por la persona.
private struct BackdropPreset: Codable {
    var name: String
    var backdrop: Backdrop
}

/// Panel Fondo. Solo edita una receta: quien la aplica y la deshace es el lienzo.
@MainActor
final class BackgroundPanel: NSView {
    static let width: CGFloat = 260

    /// Cada cambio del fondo. El segundo valor es `false` mientras un deslizador sigue en movimiento.
    var onChange: ((Backdrop?, Bool) -> Void)?
    var onPickPicture: (() -> Void)?

    private static let presetsKey = "editor.fondo.ajustes"
    private static let lastPictureKey = "editor.fondo.ultimaImagen"

    private static let solidColors: [(name: String, value: UInt32)] = [
        ("Negro", 0x111114), ("Blanco", 0xFFFFFF), ("Rojo", 0xE5484D), ("Naranja", 0xF5873C), ("Amarillo", 0xF7C948),
        ("Verde", 0x2FA866), ("Azul", 0x2F7CF6), ("Añil", 0x4F46C8), ("Violeta", 0x9B4DDB), ("Rosa", 0xE85C9C),
        ("Grafito", 0x3B3F4A), ("Gris", 0xBFC3CC), ("Rubor", 0xF7B5B0), ("Durazno", 0xFBD0A6), ("Vainilla", 0xFBEFB0),
        ("Salvia", 0xBDE5C8), ("Celeste", 0xB4DCF8), ("Bígaro", 0xC4CCF7), ("Malva", 0xDFC4F4), ("Pétalo", 0xF8C8E0),
    ]

    private let scroll = NSScrollView()
    private let body = FlippedView()
    private var backdrop: Backdrop?
    /// Margen, sombra y demás sobreviven a pasar por Ninguno.
    private var lastStyle = Backdrop()
    private var activePreset: Int?
    private var lastPicture: Data?
    private var paintedPicture: Data?
    private var capture: NSImage?
    private var captureBlur: NSImage?

    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var gradientButtons: [SwatchButton] = []
    private var solidButtons: [SwatchButton] = []
    private var pictureButton: SwatchButton?
    private var blurButton: SwatchButton?
    private var softWhiteButton: SwatchButton?
    private var softGrayButton: SwatchButton?
    private var marginSlider: NSSlider?
    private var insetSlider: NSSlider?
    private var shadowSlider: NSSlider?
    private var cornersSlider: NSSlider?
    private var balanceBox: NSButton?
    private var marginValue: NSTextField?

    override init(frame: CGRect) {
        super.init(frame: frame)
        lastPicture = UserDefaults.standard.data(forKey: Self.lastPictureKey)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Fondo")

        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.autohidesScrollers = true
        scroll.documentView = body
        addSubview(scroll)
        build()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    // MARK: - Construcción

    private func build() {
        let side: CGFloat = 14
        let inner = Self.width - side * 2
        var y: CGFloat = 12

        func caption(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.frame = CGRect(x: side, y: y, width: inner, height: 14)
            body.addSubview(label)
            y += 20
        }

        // Ajustes guardados.
        presetPopup.frame = CGRect(x: side, y: y, width: inner - 32, height: 24)
        presetPopup.controlSize = .small
        presetPopup.font = .systemFont(ofSize: 12)
        presetPopup.setAccessibilityLabel("Ajustes guardados")
        body.addSubview(presetPopup)
        let save = GlassButton(symbol: "plus", tooltip: "Guardar el ajuste actual", target: self, action: #selector(savePreset), size: 24)
        save.frame.origin = CGPoint(x: Self.width - side - 24, y: y)
        body.addSubview(save)
        rebuildPresets()
        y += 34

        // Ninguno.
        let none = NSButton(title: "Ninguno", target: self, action: #selector(nonePressed))
        none.bezelStyle = .rounded
        none.controlSize = .regular
        none.frame = CGRect(x: side - 4, y: y - 2, width: inner + 8, height: 30)
        none.setAccessibilityLabel("Quitar el fondo")
        body.addSubview(none)
        y += 38

        // Degradados: cinco columnas de 40 puntos.
        caption("Degradados")
        for (index, gradient) in BackdropArt.gradients.enumerated() {
            let button = SwatchButton(side: 40, radius: 9, label: gradient.name, target: self, action: #selector(gradientPressed(_:)))
            button.tag = index
            button.paint = { rect, context in
                BackdropArt.drawGradient(index, in: rect, context: context)
            }
            button.frame.origin = CGPoint(x: side + CGFloat(index % 5) * 48, y: y + CGFloat(index / 5) * 48)
            body.addSubview(button)
            gradientButtons.append(button)
        }
        y += 4 * 48 + 6

        // Imágenes.
        caption("Imágenes")
        let picture = SwatchButton(side: 40, radius: 9, label: "Última imagen", target: self, action: #selector(lastPicturePressed))
        picture.frame.origin = CGPoint(x: side, y: y)
        body.addSubview(picture)
        pictureButton = picture
        let add = PillControl(content: .symbol("plus"), width: 40, tooltip: "Elegir una imagen propia", chevron: false, target: self, action: #selector(addPicturePressed))
        add.frame.origin = CGPoint(x: side + 48, y: y + 6)
        body.addSubview(add)
        y += 54

        // Difuminado.
        caption("Difuminado")
        let blur = SwatchButton(side: 40, radius: 9, label: "La captura difuminada", target: self, action: #selector(softPressed(_:)))
        blur.tag = 0
        let white = SwatchButton(side: 40, radius: 9, label: "Blanco suave", target: self, action: #selector(softPressed(_:)))
        white.tag = 1
        white.paint = { rect, context in
            BackdropArt.drawSoft(white: true, in: rect, context: context)
        }
        let gray = SwatchButton(side: 40, radius: 9, label: "Gris suave", target: self, action: #selector(softPressed(_:)))
        gray.tag = 2
        gray.paint = { rect, context in
            BackdropArt.drawSoft(white: false, in: rect, context: context)
        }
        for (index, button) in [blur, white, gray].enumerated() {
            button.frame.origin = CGPoint(x: side + CGFloat(index) * 48, y: y)
            body.addSubview(button)
        }
        blurButton = blur
        softWhiteButton = white
        softGrayButton = gray
        y += 54

        // Color liso: dos filas de diez.
        caption("Color liso")
        let dot: CGFloat = 19
        let dotGap = (inner - dot * 10) / 9
        for (index, entry) in Self.solidColors.enumerated() {
            let button = SwatchButton(side: dot, radius: dot / 2, label: entry.name, target: self, action: #selector(solidPressed(_:)))
            button.tag = index
            let hex = entry.value
            button.paint = { rect, context in
                context.setFillColor(NSColor.hex(hex).cgColor)
                context.fill(rect)
            }
            button.frame.origin = CGPoint(
                x: side + CGFloat(index % 10) * (dot + dotGap),
                y: y + CGFloat(index / 10) * (dot + 7)
            )
            body.addSubview(button)
            solidButtons.append(button)
        }
        y += 2 * dot + 7 + 16

        // Deslizadores.
        func slider(_ name: String, min: Double, max: Double, x: CGFloat, width: CGFloat, y: CGFloat) -> NSSlider {
            let control = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: #selector(sliderChanged(_:)))
            control.controlSize = .small
            control.isContinuous = true
            control.frame = CGRect(x: x, y: y, width: width, height: 18)
            control.setAccessibilityLabel(name)
            control.toolTip = name
            body.addSubview(control)
            return control
        }

        caption("Margen")
        let value = NSTextField(labelWithString: "0")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = CGRect(x: Self.width - side - 40, y: y - 20, width: 40, height: 14)
        body.addSubview(value)
        marginValue = value
        marginSlider = slider("Margen", min: 0, max: 240, x: side, width: inner, y: y)
        y += 28

        let half = (inner - 14) / 2
        caption("Interior")
        insetSlider = slider("Interior", min: 0, max: 80, x: side, width: half, y: y)
        let box = NSButton(checkboxWithTitle: "Autoequilibrar", target: self, action: #selector(balanceChanged(_:)))
        box.controlSize = .small
        box.font = .systemFont(ofSize: 11)
        box.sizeToFit()
        box.frame.origin = CGPoint(x: side + half + 14, y: y)
        box.toolTip = "Centra el contenido igualando el color del borde"
        box.setAccessibilityLabel("Autoequilibrar")
        body.addSubview(box)
        balanceBox = box
        y += 28

        for (index, name) in ["Sombra", "Esquinas"].enumerated() {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.frame = CGRect(x: side + CGFloat(index) * (half + 14), y: y, width: half, height: 14)
            body.addSubview(label)
        }
        y += 20
        shadowSlider = slider("Sombra", min: 0, max: 1, x: side, width: half, y: y)
        cornersSlider = slider("Esquinas", min: 0, max: 40, x: side + half + 14, width: half, y: y)
        y += 32

        body.frame = CGRect(x: 0, y: 0, width: Self.width, height: y)
    }

    // MARK: - Estado

    /// Refleja el fondo del lienzo: al abrir, al deshacer o al cargar un proyecto.
    func reload(_ backdrop: Backdrop?, capture image: NSImage) {
        self.backdrop = backdrop
        if let backdrop {
            lastStyle = backdrop
        }
        if capture !== image {
            capture = image
            captureBlur = ImageTools.blurredBackdrop(of: image)
            let blur = captureBlur
            blurButton?.paint = { rect, context in
                if let blur {
                    BackdropArt.drawCover(blur, in: rect)
                } else {
                    BackdropArt.drawSoft(white: false, in: rect, context: context)
                }
            }
        }
        refresh()
    }

    private func refresh() {
        let current = backdrop
        let isGradient = current?.kind == .gradient
        for (index, button) in gradientButtons.enumerated() {
            button.isChosen = isGradient && current?.gradient == index
        }
        pictureButton?.isChosen = current?.kind == .picture
        blurButton?.isChosen = current?.kind == .ownBlur
        softWhiteButton?.isChosen = current?.kind == .softWhite
        softGrayButton?.isChosen = current?.kind == .softGray
        let isSolid = current?.kind == .solid
        for (index, button) in solidButtons.enumerated() {
            button.isChosen = isSolid && current.map { Self.isSame($0.color, Self.solidColors[index].value) } == true
        }

        pictureButton?.isEnabled = lastPicture != nil
        pictureButton?.alphaValue = lastPicture != nil ? 1 : 0.4
        if let data = lastPicture, data != paintedPicture, let thumbnail = NSImage(data: data) {
            paintedPicture = data
            pictureButton?.paint = { rect, _ in
                BackdropArt.drawCover(thumbnail, in: rect)
            }
        }

        let style = current ?? lastStyle
        marginSlider?.doubleValue = Double(style.margin)
        insetSlider?.doubleValue = Double(style.inset)
        shadowSlider?.doubleValue = Double(style.shadow)
        cornersSlider?.doubleValue = Double(style.corners)
        balanceBox?.state = style.autoBalance ? .on : .off
        marginValue?.stringValue = "\(Int(style.margin))"
        marginSlider?.setAccessibilityValue("\(Int(style.margin)) puntos")

        let enabled = current != nil
        [marginSlider, insetSlider, shadowSlider, cornersSlider].forEach { $0?.isEnabled = enabled }
        balanceBox?.isEnabled = enabled
    }

    private static func isSame(_ color: [CGFloat], _ value: UInt32) -> Bool {
        guard color.count >= 3, let rgb = NSColor.hex(value).usingColorSpace(.sRGB) else { return false }
        return abs(color[0] - rgb.redComponent) < 0.01
            && abs(color[1] - rgb.greenComponent) < 0.01
            && abs(color[2] - rgb.blueComponent) < 0.01
    }

    private func apply(finished: Bool = true) {
        if let backdrop {
            lastStyle = backdrop
        }
        onChange?(backdrop, finished)
        refresh()
    }

    /// Elige un relleno y conserva margen, sombra y esquinas.
    private func choose(_ change: (inout Backdrop) -> Void) {
        var next = backdrop ?? lastStyle
        change(&next)
        // La imagen pesa: solo viaja con el fondo si es el relleno elegido.
        if next.kind != .picture {
            next.picture = nil
        }
        backdrop = next
        activePreset = nil
        apply()
        rebuildPresets()
    }

    // MARK: - Acciones

    @objc private func nonePressed() {
        backdrop = nil
        activePreset = nil
        apply()
        rebuildPresets()
    }

    @objc private func gradientPressed(_ sender: NSButton) {
        chooseGradient(sender.tag)
    }

    func chooseGradient(_ index: Int) {
        choose {
            $0.kind = .gradient
            $0.gradient = index
        }
    }

    @objc private func softPressed(_ sender: NSButton) {
        choose {
            switch sender.tag {
            case 0: $0.kind = .ownBlur
            case 1: $0.kind = .softWhite
            default: $0.kind = .softGray
            }
        }
    }

    @objc private func solidPressed(_ sender: NSButton) {
        guard let rgb = NSColor.hex(Self.solidColors[sender.tag].value).usingColorSpace(.sRGB) else { return }
        choose {
            $0.kind = .solid
            $0.color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        }
    }

    @objc private func lastPicturePressed() {
        guard let lastPicture else { return }
        usePicture(lastPicture)
    }

    @objc private func addPicturePressed() {
        onPickPicture?()
    }

    /// Usa una imagen ya reducida y la recuerda como la última.
    func usePicture(_ data: Data) {
        lastPicture = data
        UserDefaults.standard.set(data, forKey: Self.lastPictureKey)
        choose {
            $0.kind = .picture
            $0.picture = data
        }
    }

    /// Mientras se arrastra, cada movimiento se ve en vivo; al soltar queda un solo paso de deshacer.
    @objc private func sliderChanged(_ sender: NSSlider) {
        guard var next = backdrop else { return }
        let value = CGFloat(sender.doubleValue)
        if sender === marginSlider {
            next.margin = value.rounded()
        } else if sender === insetSlider {
            next.inset = value.rounded()
        } else if sender === shadowSlider {
            next.shadow = value
        } else if sender === cornersSlider {
            next.corners = value.rounded()
        }
        backdrop = next
        activePreset = nil
        let event = NSApp.currentEvent?.type
        apply(finished: event != .leftMouseDragged && event != .leftMouseDown)
    }

    @objc private func balanceChanged(_ sender: NSButton) {
        guard var next = backdrop else { return }
        next.autoBalance = sender.state == .on
        backdrop = next
        activePreset = nil
        apply()
    }

    // MARK: - Ajustes guardados

    private var presets: [BackdropPreset] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.presetsKey) else { return [] }
            return (try? JSONDecoder().decode([BackdropPreset].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }

    private func rebuildPresets() {
        let saved = presets
        var title = "Ajustes guardados"
        if let activePreset, saved.indices.contains(activePreset) {
            title = saved[activePreset].name
        }
        let menu = NSMenu()
        // En un menú desplegable, la primera opción es solo el título del botón.
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        if saved.isEmpty {
            menu.addItem(withTitle: "Todavía no hay ajustes", action: nil, keyEquivalent: "")
        }
        for (index, preset) in saved.enumerated() {
            let item = menu.addItem(withTitle: preset.name, action: #selector(presetChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
        }
        if let activePreset, saved.indices.contains(activePreset) {
            menu.addItem(.separator())
            let remove = menu.addItem(withTitle: "Borrar \(saved[activePreset].name)", action: #selector(removePreset), keyEquivalent: "")
            remove.target = self
        }
        presetPopup.menu = menu
    }

    @objc private func presetChosen(_ sender: NSMenuItem) {
        let saved = presets
        guard saved.indices.contains(sender.tag) else { return }
        backdrop = saved[sender.tag].backdrop
        activePreset = sender.tag
        apply()
        rebuildPresets()
    }

    @objc private func removePreset() {
        guard let activePreset else { return }
        var saved = presets
        guard saved.indices.contains(activePreset) else { return }
        saved.remove(at: activePreset)
        presets = saved
        self.activePreset = nil
        rebuildPresets()
    }

    @objc private func savePreset() {
        guard let backdrop else {
            Toast.shared.show("Elige un fondo para guardarlo")
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Guardar este ajuste"
        alert.informativeText = "Quedará en la lista para usarlo con otras capturas."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Ajuste \(presets.count + 1)"
        field.setAccessibilityLabel("Nombre del ajuste")
        alert.accessoryView = field
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                guard let self else { return }
                let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                var saved = self.presets
                saved.append(BackdropPreset(name: typed.isEmpty ? "Ajuste \(saved.count + 1)" : typed, backdrop: backdrop))
                self.presets = saved
                self.activePreset = saved.count - 1
                self.rebuildPresets()
            }
        }
    }
}

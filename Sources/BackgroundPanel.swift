import AppKit

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    /// Alturas de las líneas finas entre secciones.
    var lines: [CGFloat] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.hairline.setFill()
        for y in lines {
            NSBezierPath(rect: CGRect(x: BackgroundPanel.side, y: y, width: bounds.width - BackgroundPanel.side * 2, height: 1)).fill()
        }
    }
}

/// Muestra del panel: un degradado, una imagen o un color. La elegida lleva un anillo azul separado por un hueco.
/// El marco guarda sitio para el anillo: la muestra visible queda en el centro.
private final class SwatchButton: ReactiveButton {
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
    private let ringGap: CGFloat
    private let ringWidth: CGFloat

    private var room: CGFloat { ringGap + ringWidth }
    private var area: CGRect { bounds.insetBy(dx: room, dy: room) }

    init(side: CGFloat, radius: CGFloat, ringGap: CGFloat = 2, ringWidth: CGFloat = 2.5, label: String, target: AnyObject, action: Selector) {
        self.radius = radius
        self.ringGap = ringGap
        self.ringWidth = ringWidth
        let full = side + (ringGap + ringWidth) * 2
        super.init(frame: CGRect(x: 0, y: 0, width: full, height: full))
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

    /// Coloca la muestra visible, sin contar el sitio del anillo.
    func place(at point: CGPoint) {
        frame.origin = CGPoint(x: point.x - room, y: point.y - room)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: area, xRadius: radius, yRadius: radius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shape = NSBezierPath(roundedRect: area, xRadius: radius, yRadius: radius)

        Palette.group.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        paint?(area, context)
        NSGraphicsContext.restoreGraphicsState()

        if isPressed {
            Palette.pressed.setFill()
            shape.fill()
        } else if isHovering, isEnabled {
            Palette.hover.setFill()
            shape.fill()
        }

        // Contorno suave: si no, las muestras claras se pierden en el panel.
        Palette.hairline.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()

        if isChosen {
            Palette.accent.setStroke()
            let reach = ringGap + ringWidth / 2
            let ring = NSBezierPath(roundedRect: area.insetBy(dx: -reach, dy: -reach), xRadius: radius + reach, yRadius: radius + reach)
            ring.lineWidth = ringWidth
            ring.stroke()
        }
    }
}

/// Casilla propia: su dibujo es de Zas, su papel y su estado siguen siendo los de una casilla del sistema.
private final class PanelCheckbox: ReactiveButton {
    private let label: String

    override var isFlipped: Bool { false }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    private static let gap: CGFloat = 7
    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Palette.text]
    }

    init(title: String, target: AnyObject, action: Selector) {
        label = title
        let text = (title as NSString).size(withAttributes: PanelCheckbox.attributes)
        super.init(frame: CGRect(x: 0, y: 0, width: Design.checkbox + PanelCheckbox.gap + text.width.rounded(.up), height: Design.checkbox))
        setButtonType(.switch)
        self.title = ""
        isBordered = false
        self.target = target
        self.action = action
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: Design.checkbox, height: Design.checkbox), xRadius: Design.checkboxRadius, yRadius: Design.checkboxRadius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let side = Design.checkbox
        let top = (bounds.height - side) / 2
        let frame = CGRect(x: 0, y: top, width: side, height: side)
        let box = NSBezierPath(roundedRect: frame, xRadius: Design.checkboxRadius, yRadius: Design.checkboxRadius)
        let isOn = state == .on
        (isOn ? Palette.accent : Palette.pill).setFill()
        box.fill()
        if isPressed {
            Palette.pressed.setFill()
            box.fill()
        } else if isHovering, isEnabled {
            Palette.hover.setFill()
            box.fill()
        }
        Palette.softEdge.setStroke()
        box.lineWidth = 0.5
        box.stroke()

        if isOn {
            let check = NSBezierPath()
            check.move(to: CGPoint(x: frame.minX + 4.8, y: frame.midY))
            check.line(to: CGPoint(x: frame.minX + 7.8, y: frame.midY - 3.2))
            check.line(to: CGPoint(x: frame.minX + 13.2, y: frame.midY + 3.6))
            check.lineWidth = 2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            Palette.onAccent.setStroke()
            check.stroke()
        }

        let text = label as NSString
        let size = text.size(withAttributes: Self.attributes)
        text.draw(at: CGPoint(x: side + Self.gap, y: bounds.midY - size.height / 2), withAttributes: Self.attributes)
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
    static let width: CGFloat = 232
    /// Relleno lateral. La referencia manda: cinco muestras de 34 con 9 de separación llenan justo este ancho.
    static let side: CGFloat = 13

    /// Cada cambio del fondo. El segundo valor es `false` mientras un deslizador sigue en movimiento.
    var onChange: ((Backdrop?, Bool) -> Void)?
    var onPickPicture: (() -> Void)?

    private static let presetsKey = "editor.fondo.ajustes"
    private static let lastPictureKey = "editor.fondo.ultimaImagen"

    /// Dos filas de nueve. El último punto de cada fila no es un color: es transparente o uno propio.
    private static let solidColors: [(name: String, value: UInt32)] = [
        ("Negro", 0x111114), ("Blanco", 0xFFFFFF), ("Rojo", 0xE5484D), ("Naranja", 0xF5873C),
        ("Amarillo", 0xF7C948), ("Verde", 0x2FA866), ("Azul", 0x2F7CF6), ("Violeta", 0x9B4DDB),
        ("Grafito", 0x3B3F4A), ("Gris", 0xBFC3CC), ("Rubor", 0xF7B5B0), ("Durazno", 0xFBD0A6),
        ("Vainilla", 0xFBEFB0), ("Salvia", 0xBDE5C8), ("Celeste", 0xB4DCF8), ("Malva", 0xDFC4F4),
    ]
    private static let perRow = 9

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

    private var presetButton: PillControl?
    private var presetMenu = NSMenu()
    private var gradientButtons: [SwatchButton] = []
    private var solidButtons: [SwatchButton] = []
    private var clearButton: SwatchButton?
    private var customButton: SwatchButton?
    private var pictureButton: SwatchButton?
    private var blurButton: SwatchButton?
    private var softWhiteButton: SwatchButton?
    private var softGrayButton: SwatchButton?
    private var marginSlider: NSSlider?
    private var insetSlider: NSSlider?
    private var shadowSlider: NSSlider?
    private var cornersSlider: NSSlider?
    private var balanceBox: PanelCheckbox?
    private var marginValue: ValueChip?
    /// Se construye al abrirlo: cuarenta muestras no deben retrasar cada editor que se abre.
    private var isBuilt = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Fondo")

        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        // Se desplaza con la rueda o el trackpad, sin barra a la vista.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = body
        addSubview(scroll)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.window.setFill()
        NSBezierPath(rect: bounds).fill()
        Palette.hairline.setFill()
        NSBezierPath(rect: CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height)).fill()
    }

    // MARK: - Construcción

    private func build() {
        let side = Self.side
        let inner = Self.width - side * 2
        let swatch: CGFloat = 34
        let pitch = swatch + 9
        var y: CGFloat = 14
        var lines: [CGFloat] = []

        func title(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = Palette.secondaryText
            label.frame = CGRect(x: x, y: y, width: width, height: 16)
            body.addSubview(label)
        }
        func caption(_ text: String) {
            title(text, x: side, y: y, width: inner)
            y += 24
        }
        func sectionBreak() {
            y += 12
            lines.append(y)
            y += 12
        }

        // Ajustes guardados: fila con su flecha y, fuera, un + fino.
        let presets = PillControl(
            content: .leadingText("Ajustes guardados"),
            width: inner - 26,
            height: 32,
            radius: Design.panelRadius,
            tooltip: "Ajustes guardados",
            target: self,
            action: #selector(presetsPressed(_:))
        )
        presets.frame.origin = CGPoint(x: side, y: y)
        body.addSubview(presets)
        presetButton = presets
        let save = PillControl(content: .symbol("plus"), width: 20, height: 32, radius: 6, surface: .clear, tooltip: "Guardar el ajuste actual", chevron: false, target: self, action: #selector(savePreset))
        save.symbolSize = 13
        save.symbolWeight = .light
        save.tint = Palette.secondaryText
        save.frame.origin = CGPoint(x: Self.width - side - 20, y: y)
        body.addSubview(save)
        rebuildPresets()
        y += 40

        // Ninguno.
        let none = PillControl(content: .text("Ninguno"), width: inner, height: 36, radius: Design.panelRadius, surface: .group, tooltip: "Quitar el fondo", chevron: false, target: self, action: #selector(nonePressed))
        none.frame.origin = CGPoint(x: side, y: y)
        body.addSubview(none)
        y += 36 + 14

        // Degradados: cinco por fila.
        caption("Degradados")
        for (index, gradient) in BackdropArt.gradients.enumerated() {
            let button = SwatchButton(side: swatch, radius: 10, label: gradient.name, target: self, action: #selector(gradientPressed(_:)))
            button.tag = index
            button.paint = { rect, context in
                BackdropArt.drawGradient(index, in: rect, context: context)
            }
            button.place(at: CGPoint(x: side + CGFloat(index % 5) * pitch, y: y + CGFloat(index / 5) * pitch))
            body.addSubview(button)
            gradientButtons.append(button)
        }
        y += 4 * pitch - 9
        sectionBreak()

        // Imágenes.
        caption("Imágenes")
        let picture = SwatchButton(side: swatch, radius: 10, label: "Última imagen", target: self, action: #selector(lastPicturePressed))
        picture.place(at: CGPoint(x: side, y: y))
        body.addSubview(picture)
        pictureButton = picture
        let add = PillControl(content: .symbol("plus"), width: swatch, height: swatch, radius: 10, surface: .group, tooltip: "Elegir una imagen propia", chevron: false, target: self, action: #selector(addPicturePressed))
        add.symbolSize = 13
        add.frame.origin = CGPoint(x: side + pitch, y: y)
        body.addSubview(add)
        y += swatch
        sectionBreak()

        // Difuminado.
        caption("Difuminado")
        let blur = SwatchButton(side: swatch, radius: 10, label: "La captura difuminada", target: self, action: #selector(softPressed(_:)))
        blur.tag = 0
        let white = SwatchButton(side: swatch, radius: 10, label: "Blanco suave", target: self, action: #selector(softPressed(_:)))
        white.tag = 1
        white.paint = { rect, context in
            BackdropArt.drawSoft(white: true, in: rect, context: context)
        }
        let gray = SwatchButton(side: swatch, radius: 10, label: "Gris suave", target: self, action: #selector(softPressed(_:)))
        gray.tag = 2
        gray.paint = { rect, context in
            BackdropArt.drawSoft(white: false, in: rect, context: context)
        }
        for (index, button) in [blur, white, gray].enumerated() {
            button.place(at: CGPoint(x: side + CGFloat(index) * pitch, y: y))
            body.addSubview(button)
        }
        blurButton = blur
        softWhiteButton = white
        softGrayButton = gray
        y += swatch
        sectionBreak()

        // Color liso: los puntos llenan el ancho, como las muestras de arriba.
        caption("Color liso")
        let dot: CGFloat = 16
        let dotPitch = (inner - dot) / CGFloat(Self.perRow - 1)
        let dotRow: CGFloat = dot + 8
        func dotButton(_ label: String, action: Selector) -> SwatchButton {
            SwatchButton(side: dot, radius: dot / 2, ringGap: 1.5, ringWidth: 2, label: label, target: self, action: action)
        }
        func placeDot(_ button: SwatchButton, column: Int, row: Int) {
            button.place(at: CGPoint(x: (side + CGFloat(column) * dotPitch).rounded(), y: y + CGFloat(row) * dotRow))
            body.addSubview(button)
        }
        let plain = Self.perRow - 1
        for (index, entry) in Self.solidColors.enumerated() {
            let button = dotButton(entry.name, action: #selector(solidPressed(_:)))
            button.tag = index
            let hex = entry.value
            button.paint = { rect, context in
                context.setFillColor(NSColor.hex(hex).cgColor)
                context.fill(rect)
            }
            placeDot(button, column: index % plain, row: index / plain)
            solidButtons.append(button)
        }
        let clear = dotButton("Transparente", action: #selector(clearPressed))
        clear.paint = { rect, context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.setFillColor(Palette.checker.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height / 2))
            context.fill(CGRect(x: rect.midX, y: rect.midY, width: rect.width / 2, height: rect.height / 2))
        }
        placeDot(clear, column: plain, row: 0)
        clearButton = clear
        let custom = dotButton("Color propio", action: #selector(customPressed))
        custom.paint = { rect, context in
            // Rueda de color: una cuña por matiz.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let steps = 48
            for step in 0..<steps {
                let start = CGFloat(step) / CGFloat(steps) * 360
                let wedge = NSBezierPath()
                wedge.move(to: center)
                wedge.appendArc(withCenter: center, radius: rect.width, startAngle: start, endAngle: start + 360 / CGFloat(steps) + 1)
                wedge.close()
                NSColor(hue: CGFloat(step) / CGFloat(steps), saturation: 0.75, brightness: 1, alpha: 1).setFill()
                wedge.fill()
            }
        }
        placeDot(custom, column: plain, row: 1)
        customButton = custom
        y += dotRow * 2 - 8
        sectionBreak()

        // Deslizadores.
        func slider(_ name: String, min: Double, max: Double, x: CGFloat, width: CGFloat, y: CGFloat) -> NSSlider {
            let control = ZasSlider(value: min, minValue: min, maxValue: max, target: self, action: #selector(sliderChanged(_:)))
            control.isContinuous = true
            control.frame = CGRect(x: x, y: y, width: width, height: 18)
            control.setAccessibilityLabel(name)
            control.toolTip = name
            body.addSubview(control)
            return control
        }

        // Margen, a todo el ancho y con su valor a la derecha.
        title("Margen", x: side, y: y + 3, width: inner - Design.valueChip.width)
        let value = ValueChip(text: "0", fill: Palette.group)
        value.frame.origin = CGPoint(x: Self.width - side - value.frame.width, y: y)
        body.addSubview(value)
        marginValue = value
        y += 28
        marginSlider = slider("Margen", min: 0, max: 240, x: side, width: inner, y: y)
        y += 18 + 12

        // Interior, con la casilla en su misma fila.
        caption("Interior")
        insetSlider = slider("Interior", min: 0, max: 80, x: side, width: 88, y: y)
        let box = PanelCheckbox(title: "Autoequilibrar", target: self, action: #selector(balanceChanged(_:)))
        box.frame.origin = CGPoint(x: Self.width - side - box.frame.width, y: y)
        box.toolTip = "Centra el contenido igualando el color del borde"
        body.addSubview(box)
        balanceBox = box
        y += 18 + 12

        // Sombra y Esquinas en dos columnas.
        let half = (inner - 14) / 2
        for (index, name) in ["Sombra", "Esquinas"].enumerated() {
            title(name, x: side + CGFloat(index) * (half + 14), y: y, width: half)
        }
        y += 24
        shadowSlider = slider("Sombra", min: 0, max: 1, x: side, width: half, y: y)
        cornersSlider = slider("Esquinas", min: 0, max: 40, x: side + half + 14, width: half, y: y)
        y += 18 + 16

        body.frame = CGRect(x: 0, y: 0, width: Self.width, height: y)
        body.lines = lines
    }

    // MARK: - Estado

    /// Refleja el fondo del lienzo: al abrir, al deshacer o al cargar un proyecto.
    func reload(_ backdrop: Backdrop?, capture image: NSImage) {
        if !isBuilt {
            isBuilt = true
            lastPicture = UserDefaults.standard.data(forKey: Self.lastPictureKey)
            build()
        }
        self.backdrop = backdrop
        if let backdrop {
            lastStyle = backdrop
        }
        if capture !== image {
            capture = image
            paintBlurSwatch(from: image)
        }
        refresh()
    }

    /// La muestra se calcula aparte: mientras tanto, gris suave.
    private func paintBlurSwatch(from image: NSImage) {
        blurButton?.paint = { rect, context in
            BackdropArt.drawSoft(white: false, in: rect, context: context)
        }
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let box = Unchecked(value: source)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Unchecked(value: ImageTools.blurred(box.value))
            }.value
            guard let self, self.capture === image, let blurred = result.value else { return }
            let blur = NSImage(cgImage: blurred, size: CGSize(width: blurred.width, height: blurred.height))
            self.captureBlur = blur
            self.blurButton?.paint = { rect, _ in
                BackdropArt.drawCover(blur, in: rect)
            }
        }
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
        let isClear = isSolid && current.map { Self.isTransparent($0) } == true
        var matched = isClear
        for (index, button) in solidButtons.enumerated() {
            let same = isSolid && !isClear && current.map { Self.isSame($0.color, Self.solidColors[index].value) } == true
            button.isChosen = same
            matched = matched || same
        }
        clearButton?.isChosen = isClear
        customButton?.isChosen = isSolid && !matched

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
        marginValue?.text = "\(Int(style.margin))"
        marginSlider?.setAccessibilityValue("\(Int(style.margin)) puntos")

        let enabled = current != nil
        [marginSlider, insetSlider, shadowSlider, cornersSlider].forEach { $0?.isEnabled = enabled }
        balanceBox?.isEnabled = enabled
    }

    private static func isTransparent(_ backdrop: Backdrop) -> Bool {
        backdrop.color.count >= 4 && backdrop.color[3] == 0
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

    @objc private func clearPressed() {
        choose {
            $0.kind = .solid
            $0.color = [0, 0, 0, 0]
        }
    }

    /// El color propio se elige en el panel de colores del sistema.
    @objc private func customPressed() {
        let colors = NSColorPanel.shared
        colors.showsAlpha = false
        colors.isContinuous = false
        colors.setTarget(self)
        colors.setAction(#selector(customColorChanged(_:)))
        colors.orderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        choose {
            $0.kind = .solid
            $0.color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        }
    }

    /// Al cerrar el editor, el panel de colores deja de apuntar aquí.
    func releaseColorPanel() {
        guard NSColorPanel.sharedColorPanelExists else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
    }

    @objc private func presetsPressed(_ sender: NSButton) {
        presetMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
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
        presetButton?.content = .leadingText(title)
        presetButton?.setAccessibilityValue(title)
        let menu = NSMenu()
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
        presetMenu = menu
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

    #if ZAS_TEST
    var testIsBuilt: Bool { isBuilt }
    var testChosenGradient: Int? { gradientButtons.firstIndex { $0.isChosen } }
    var testHasBlurSwatch: Bool { captureBlur != nil }

    func testSetMargin(_ value: Double) {
        guard let marginSlider else { return }
        marginSlider.doubleValue = value
        sliderChanged(marginSlider)
    }

    func testChooseNone() { nonePressed() }
    func testChooseTransparent() { clearPressed() }

    func testChooseBlur() {
        if let blurButton {
            softPressed(blurButton)
        }
    }
    #endif
}

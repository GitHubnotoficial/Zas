import AppKit

/// Única tabla de colores de la interfaz, con su par claro y oscuro.
/// Lo que no cambia con el modo es un color fijo: sirve igual para capas, marcas y comparaciones.
enum Palette {
    private static func pair(
        _ name: String,
        dark: UInt32, darkAlpha: CGFloat = 1,
        light: UInt32, lightAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: name) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.hex(dark, alpha: darkAlpha)
                : NSColor.hex(light, alpha: lightAlpha)
        }
    }

    /// Ventana y barra superior.
    static let window = pair("zas.ventana", dark: 0x1B1B1D, light: 0xECECEE)
    /// Zona de la captura. La barra inferior comparte este fondo: solo las separa una línea fina.
    static let canvas = pair("zas.lienzo", dark: 0x1A1A1B, light: 0xE4E4E6)
    static let hairline = pair("zas.lineaFina", dark: 0xFFFFFF, darkAlpha: 0.1, light: 0x000000, lightAlpha: 0.1)
    /// Rectángulos del panel Fondo: un velo apenas visible, nunca una isla.
    static let group = pair("zas.grupo", dark: 0xFFFFFF, darkAlpha: 0.06, light: 0x000000, lightAlpha: 0.04)
    /// Pista de los deslizadores y valores numéricos.
    static let pill = pair("zas.pildora", dark: 0x3A3A3C, light: 0xFFFFFF)
    /// Secciones de Ajustes.
    static let section = pair("zas.seccion", dark: 0xFFFFFF, darkAlpha: 0.05, light: 0xFFFFFF, lightAlpha: 0.6)
    static let text = pair("zas.texto", dark: 0xF2F2F4, light: 0x1C1C1E)
    static let secondaryText = pair("zas.textoSecundario", dark: 0x8E8E93, light: 0x636368)
    /// El único azul de Zas: el que eligió cada persona en Ajustes del Sistema.
    static let accent = NSColor.controlAccentColor
    /// Color con el que nacen las marcas. Las guardadas conservan el suyo.
    static let markDefault = NSColor.hex(0xFF2D6F)
    /// El rayo del logo. Solo aparece en el instante de la captura.
    static let bolt = NSColor.hex(0xFFCC00)

    /// Texto e iconos sobre el acento.
    static let onAccent = NSColor.white
    /// Velo sobre un control al pasar el cursor y al pulsarlo.
    static let hover = pair("zas.encima", dark: 0xFFFFFF, darkAlpha: 0.08, light: 0x000000, lightAlpha: 0.06)
    static let pressed = pair("zas.pulsado", dark: 0xFFFFFF, darkAlpha: 0.14, light: 0x000000, lightAlpha: 0.1)
    /// La única forma de "activo": velo del acento bajo un glifo del acento.
    static var activeVeil: NSColor { accent.withAlphaComponent(Design.activeVeilOpacity) }
    /// Mando de los deslizadores.
    static let knob = pair("zas.mando", dark: 0xE4E4E6, light: 0xFBFBFC)
    /// Filo de lo blanco sobre blanco. En oscuro no hace falta.
    static let softEdge = pair("zas.filo", dark: 0x000000, darkAlpha: 0, light: 0x000000, lightAlpha: 0.14)
    /// Cuadros del punto transparente.
    static let checker = NSColor.hex(0xB8B8BC)
}

/// Medidas compartidas: si dos piezas se parecen, deben medir lo mismo.
enum Design {
    /// Los tres únicos radios de la app, siempre continuos.
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 18

    static let cardRadius = radiusMedium
    static let controlRadius = radiusSmall
    /// Barras: radio 12 y margen 4. El botón interior mide 12 - 4 = 8, para que las curvas sean concéntricas.
    static let barRadius = radiusMedium
    static let barPadding: CGFloat = 4
    static let edgeMargin: CGFloat = 18
    static let stackGap: CGFloat = 10
    static let actionSize: CGFloat = 32
    /// Todo símbolo de la app.
    static let iconSize: CGFloat = 15
    static let lineWidth: CGFloat = 0.5
    static let activeVeilOpacity: CGFloat = 0.18

    /// El resorte de toda la app, también en SwiftUI.
    static let springResponse = 0.42
    static let springDamping = 0.86
    /// Salir por el borde va más rápido que entrar: lo que se va ya no importa.
    static let exitResponse = 0.34
    /// Lo que se desliza dentro de una barra: la marca de la herramienta activa.
    static let slideResponse = 0.18
    /// Destello de la captura y paso a la pantalla congelada.
    static let flashDuration = 0.12
    /// Aparecer y desaparecer sin viaje.
    static let fadeDuration = 0.16
    /// Anillo de un clic dentro de un video.
    static let clickRingDuration = 0.45

    /// Las pruebas lo fijan para ver los dos caminos. El sistema manda en todo lo demás.
    @MainActor
    static var reduceMotion: Bool {
        #if ZAS_TEST
        if let testReduceMotion { return testReduceMotion }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    #if ZAS_TEST
    @MainActor static var testReduceMotion: Bool?
    #endif
}

/// Botón propio con sus dos estados inmediatos: cursor encima y pulsado.
/// Las subclases pintan cada estado; aquí solo se sigue al ratón.
class ReactiveButton: NSButton {
    private(set) var isHovering = false
    private(set) var isPressed = false
    private var hoverArea: NSTrackingArea?

    /// Se llama en cuanto cambia cualquiera de los dos estados.
    func reactiveStateChanged() {
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        reactiveStateChanged()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        reactiveStateChanged()
    }

    /// `NSButton` sigue al ratón dentro de `mouseDown`: vuelve de ahí al soltar.
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        reactiveStateChanged()
        super.mouseDown(with: event)
        isPressed = false
        reactiveStateChanged()
    }

    #if ZAS_TEST
    func testSetHovering(_ value: Bool) {
        isHovering = value
        reactiveStateChanged()
    }

    func testSetPressed(_ value: Bool) {
        isPressed = value
        reactiveStateChanged()
    }
    #endif
}

/// Vidrio del sistema con esquinas redondeadas y un filo de luz.
/// Solo se usa en lo que flota sobre el contenido, nunca dentro de otro vidrio.
final class GlassView: NSVisualEffectView {
    init(
        frame: CGRect,
        radius: CGFloat,
        material: NSVisualEffectView.Material = .popover,
        blending: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        super.init(frame: frame)
        self.material = material
        blendingMode = blending
        state = .active
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        // La máscara recorta también el desenfoque del escritorio, no solo el dibujo.
        maskImage = Self.mask(radius: radius)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Botón redondeado de una barra de vidrio.
final class GlassButton: ReactiveButton {
    var isActive = false {
        didSet { refresh() }
    }

    /// Color del velo y del glifo cuando está activo. Grabar usa rojo; lo demás, el acento del sistema.
    var activeColor: NSColor = Palette.accent {
        didSet { refresh() }
    }

    /// Lo que dice el botón junto al glifo, si dice algo.
    private var caption: String?

    init(symbol: String, tooltip: String, target: AnyObject?, action: Selector?, size: CGFloat = Design.actionSize) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        let configuration = NSImage.SymbolConfiguration(pointSize: Design.iconSize, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(configuration)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tooltip
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = min(size * 0.3, Design.barRadius - Design.barPadding)
        layer?.cornerCurve = .continuous
        setAccessibilityLabel(tooltip)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    /// Ensancha el botón para que diga en qué estado está.
    func show(caption text: String) {
        caption = text
        let font = NSFont.systemFont(ofSize: 13)
        attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: activeColor])
        imagePosition = .imageLeading
        imageHugsTitle = true
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        frame.size.width = (frame.height + textWidth + 8).rounded(.up)
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func reactiveStateChanged() {
        refresh()
    }

    private func refresh() {
        contentTintColor = isActive ? activeColor : .labelColor
        setAccessibilityValue(isActive ? (caption ?? "Activo") : nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            var fill: NSColor = isActive ? activeColor.withAlphaComponent(Design.activeVeilOpacity) : .clear
            if isPressed, isEnabled {
                fill = isActive ? activeColor.withAlphaComponent(Design.activeVeilOpacity * 2) : .tertiaryLabelColor
            } else if isHovering, isEnabled, !isActive {
                fill = .quaternaryLabelColor
            }
            layer?.backgroundColor = fill.cgColor
        }
    }

    #if ZAS_TEST
    var testFill: CGColor? { layer?.backgroundColor }
    var testCaption: String? { caption }
    #endif
}

/// Resorte amortiguado: lo que hace que algo se sienta como un objeto con peso.
enum Spring {
    /// Avance de 0 a 1 tras `time` segundos. Puede pasarse de 1 un instante, como un objeto real.
    static func value(at time: Double, response: Double, damping: Double) -> Double {
        let frequency = 2 * Double.pi / response
        let decay = damping * frequency
        let ringing = frequency * sqrt(max(1 - damping * damping, 0.0001))
        let envelope = exp(-decay * time)
        return 1 - envelope * (cos(ringing * time) + decay / ringing * sin(ringing * time))
    }

    /// Corre el resorte hasta asentarse. Cancelar el valor devuelto detiene el movimiento.
    @MainActor
    @discardableResult
    static func run(
        response: Double = Design.springResponse,
        damping: Double = Design.springDamping,
        step: @escaping @MainActor (CGFloat) -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) -> Timer {
        // Quien pide reducir el movimiento ve el resultado sin el viaje.
        if Design.reduceMotion {
            step(1)
            completion?()
            return Timer(timeInterval: 0, repeats: false) { _ in }
        }
        let started = Date()
        let length = response * 1.6
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(started)
            MainActor.assumeIsolated {
                if elapsed >= length {
                    timer.invalidate()
                    step(1)
                    completion?()
                } else {
                    step(CGFloat(value(at: elapsed, response: response, damping: damping)))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// Reglas del gesto de deslizar una tarjeta hacia el borde.
enum CardSwipe {
    static func shouldClose(offset: CGFloat, width: CGFloat, velocity: CGFloat) -> Bool {
        offset > width * 0.4 || (velocity > 500 && offset > 12)
    }

    /// Hacia dentro la tarjeta cede poco, y cuanto más se tira, menos cede.
    static func resisted(_ offset: CGFloat) -> CGFloat {
        guard offset < 0 else { return offset }
        return -24 * (1 - 1 / (-offset / 60 + 1))
    }
}

extension NSRect {
    /// Interpolación entre dos marcos de ventana.
    func moved(to target: NSRect, by progress: CGFloat) -> NSRect {
        NSRect(
            x: origin.x + (target.origin.x - origin.x) * progress,
            y: origin.y + (target.origin.y - origin.y) * progress,
            width: max(size.width + (target.size.width - size.width) * progress, 1),
            height: max(size.height + (target.size.height - size.height) * progress, 1)
        )
    }
}

extension Design {
    /// Barra superior del editor, la misma fila de los semáforos.
    static let editorBar: CGFloat = 52
    static let editorBottomBar: CGFloat = 36
    /// Iconos sin marco de las barras.
    static let controlSize: CGFloat = 28
    /// Casilla de cada herramienta: ancho fijo, nada se desplaza al elegir otra.
    static let toolSize: CGFloat = 30
    static let dragPillWidth: CGFloat = 104
    static let barGap: CGFloat = 8
    /// Radio de los rectángulos del panel Fondo.
    static let panelRadius = radiusSmall
    static let valueChip = CGSize(width: 34, height: 22)
    static let sliderKnob = CGSize(width: 22, height: 14)
    static let sliderTrack: CGFloat = 5
    /// Sombra de la imagen sobre el lienzo.
    static let canvasShadowOpacity: CGFloat = 0.12
    static let canvasShadowDrop: CGFloat = 2
    static let canvasShadowBlur: CGFloat = 12
}

extension NSBezierPath {
    /// Rectángulo de esquinas continuas, como `cornerCurve = .continuous` pero para dibujar.
    /// La curva arranca antes de la esquina y llega sin el codo de un arco de círculo.
    static func continuous(in rect: CGRect, radius: CGFloat) -> NSBezierPath {
        let limit = min(rect.width, rect.height) / 2
        let reach = min(radius * 1.28, limit)
        let pull = reach * 0.24
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + reach, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - reach, y: rect.minY))
        path.curve(
            to: CGPoint(x: rect.maxX, y: rect.minY + reach),
            controlPoint1: CGPoint(x: rect.maxX - pull, y: rect.minY),
            controlPoint2: CGPoint(x: rect.maxX, y: rect.minY + pull)
        )
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - reach))
        path.curve(
            to: CGPoint(x: rect.maxX - reach, y: rect.maxY),
            controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY - pull),
            controlPoint2: CGPoint(x: rect.maxX - pull, y: rect.maxY)
        )
        path.line(to: CGPoint(x: rect.minX + reach, y: rect.maxY))
        path.curve(
            to: CGPoint(x: rect.minX, y: rect.maxY - reach),
            controlPoint1: CGPoint(x: rect.minX + pull, y: rect.maxY),
            controlPoint2: CGPoint(x: rect.minX, y: rect.maxY - pull)
        )
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + reach))
        path.curve(
            to: CGPoint(x: rect.minX + reach, y: rect.minY),
            controlPoint1: CGPoint(x: rect.minX, y: rect.minY + pull),
            controlPoint2: CGPoint(x: rect.minX + pull, y: rect.minY)
        )
        path.close()
        return path
    }
}

/// Control de las barras del editor y del panel Fondo. En reposo no tiene fondo: un icono, un punto
/// de color o un texto. El velo aparece con el cursor. Con `chevron` avisa de que abre algo.
final class PillControl: ReactiveButton {
    enum Content {
        case dot(NSColor)
        case symbol(String)
        case text(String)
        /// Texto pegado a la izquierda, como en la fila de ajustes guardados.
        case leadingText(String)
    }

    enum Surface {
        case clear, group, accent
    }

    var content: Content {
        didSet { needsDisplay = true }
    }

    /// Velo y glifo del acento.
    var isActive = false {
        didSet {
            setAccessibilityValue(isActive ? "Activo" : nil)
            needsDisplay = true
        }
    }

    /// La barra de herramientas pinta el velo aparte, porque se desliza entre ellas.
    var paintsActiveVeil = true {
        didSet { needsDisplay = true }
    }

    /// Color del icono cuando no debe ser el del texto.
    var tint: NSColor? {
        didSet { needsDisplay = true }
    }

    var symbolSize: CGFloat = Design.iconSize
    var symbolWeight: NSFont.Weight = .regular
    var textWeight: NSFont.Weight = .regular

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }

    // El dibujo es propio: con origen abajo, como el resto de las vistas de Zas.
    override var isFlipped: Bool { false }

    private let surface: Surface
    private let radius: CGFloat
    private let showsChevron: Bool

    init(
        content: Content,
        width: CGFloat,
        height: CGFloat = Design.controlSize,
        radius: CGFloat = Design.radiusSmall,
        surface: Surface = .clear,
        tooltip: String,
        chevron: Bool = false,
        target: AnyObject?,
        action: Selector?
    ) {
        self.content = content
        self.surface = surface
        self.radius = radius
        showsChevron = chevron
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
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

    /// Ancho de un control con texto de 13, con su relleno a cada lado.
    static func width(for text: String, weight: NSFont.Weight, padding: CGFloat = 12) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: weight)])
        return (size.width + padding * 2).rounded(.up)
    }

    private var shapePath: NSBezierPath {
        NSBezierPath.continuous(in: bounds, radius: radius)
    }

    override func drawFocusRingMask() {
        shapePath.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let path = shapePath
        switch surface {
        case .clear: break
        case .group:
            Palette.group.setFill()
            path.fill()
        case .accent:
            Palette.accent.setFill()
            path.fill()
        }
        if isActive, paintsActiveVeil {
            Palette.activeVeil.setFill()
            path.fill()
        }
        if isHighlighted || isPressed {
            Palette.pressed.setFill()
            path.fill()
        } else if isHovering && isEnabled && !isActive {
            Palette.hover.setFill()
            path.fill()
        }

        let foreground = tint ?? (isActive ? Palette.accent : (surface == .accent ? Palette.onAccent : Palette.text))
        // Con flecha, el contenido se aparta hacia la izquierda y deja sitio a los 10 puntos de la derecha.
        let center = CGPoint(x: (bounds.width - (showsChevron ? 10 : 0)) / 2, y: bounds.midY)
        drawContent(at: center, color: foreground)

        if showsChevron {
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Palette.secondaryText]))
            if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = chevron.size
                chevron.draw(in: CGRect(x: bounds.maxX - 11 - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
            }
        }
    }

    private func drawContent(at center: CGPoint, color: NSColor) {
        switch content {
        case .dot(let dotColor):
            let dot = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
            dotColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            // Filo fino: el blanco se perdería sobre la barra clara.
            Palette.hairline.setStroke()
            let edge = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = Design.lineWidth
            edge.stroke()
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: symbolWeight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = symbol.size
                symbol.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
            }
        case .text(let text):
            let attributes = textAttributes(color: color)
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
        case .leadingText(let text):
            let attributes = textAttributes(color: color)
            let size = (text as NSString).size(withAttributes: attributes)
            let room = CGRect(x: 10, y: center.y - size.height / 2, width: bounds.width - 32, height: size.height)
            (text as NSString).draw(with: room, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
        }
    }

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: textWeight),
            .foregroundColor: color,
        ]
    }
}

/// Dibuja el deslizador de Zas sobre un `NSSlider` de verdad: teclado y VoiceOver siguen siendo los del sistema.
final class ZasSliderCell: NSSliderCell {
    override var knobThickness: CGFloat { Design.sliderKnob.width }

    private var fraction: CGFloat {
        guard maxValue > minValue else { return 0 }
        return min(max(CGFloat((doubleValue - minValue) / (maxValue - minValue)), 0), 1)
    }

    private var area: CGRect { controlView?.bounds ?? .zero }

    override func knobRect(flipped: Bool) -> NSRect {
        let knob = Design.sliderKnob
        return CGRect(
            x: ((area.width - knob.width) * fraction).rounded(),
            y: ((area.height - knob.height) / 2).rounded(),
            width: knob.width,
            height: knob.height
        )
    }

    override func barRect(flipped: Bool) -> NSRect {
        CGRect(x: 0, y: ((area.height - Design.sliderTrack) / 2).rounded(), width: area.width, height: Design.sliderTrack)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = barRect(flipped: flipped)
        let radius = bar.height / 2
        let track = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
        Palette.pill.setFill()
        track.fill()
        Palette.softEdge.setStroke()
        track.lineWidth = Design.lineWidth
        track.stroke()

        var done = bar
        done.size.width = max(knobRect(flipped: flipped).midX, bar.height)
        Palette.accent.setFill()
        NSBezierPath(roundedRect: done, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let radius = knobRect.height / 2
        let knob = NSBezierPath(roundedRect: knobRect, xRadius: radius, yRadius: radius)
        Palette.knob.setFill()
        knob.fill()
        Palette.softEdge.setStroke()
        knob.lineWidth = Design.lineWidth
        knob.stroke()
    }
}

final class ZasSlider: NSSlider {
    override class var cellClass: AnyClass? {
        get { ZasSliderCell.self }
        set {}
    }
}

/// Valor de un deslizador: un número dentro de su rectángulo.
final class ValueChip: NSView {
    var text: String {
        didSet { needsDisplay = true }
    }

    private let fill: NSColor

    init(text: String, fill: NSColor) {
        self.text = text
        self.fill = fill
        super.init(frame: CGRect(origin: .zero, size: Design.valueChip))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath.continuous(in: bounds, radius: Design.radiusSmall).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: Palette.text,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

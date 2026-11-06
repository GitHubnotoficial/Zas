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
    /// Zona de la captura.
    static let canvas = pair("zas.lienzo", dark: 0x1A1A1B, light: 0xE4E4E6)
    static let bottomBar = pair("zas.barraInferior", dark: 0x212223, light: 0xD2D2D4)
    static let hairline = pair("zas.lineaFina", dark: 0xFFFFFF, darkAlpha: 0.1, light: 0x000000, lightAlpha: 0.1)
    /// Grupo de herramientas, popovers y rectángulos del panel.
    static let group = pair("zas.grupo", dark: 0x2B2B2D, light: 0xFFFFFF, lightAlpha: 0.7)
    static let pill = pair("zas.pildora", dark: 0x3A3A3C, light: 0xFFFFFF)
    static let text = pair("zas.texto", dark: 0xF2F2F4, light: 0x1C1C1E)
    static let secondaryText = pair("zas.textoSecundario", dark: 0x8E8E93, light: 0x636368)
    static let accent = NSColor.hex(0x0A6FE8)
    /// Color con el que nacen las marcas. Las guardadas conservan el suyo.
    static let markDefault = NSColor.hex(0xFF2D6F)

    /// Texto e iconos sobre el acento.
    static let onAccent = NSColor.white
    /// Velo sobre un control al pasar el cursor y al pulsarlo.
    static let hover = pair("zas.encima", dark: 0xFFFFFF, darkAlpha: 0.08, light: 0x000000, lightAlpha: 0.06)
    static let pressed = pair("zas.pulsado", dark: 0xFFFFFF, darkAlpha: 0.14, light: 0x000000, lightAlpha: 0.1)
    /// Mando de los deslizadores.
    static let knob = pair("zas.mando", dark: 0xE4E4E6, light: 0xFBFBFC)
    /// Filo de lo blanco sobre blanco. En oscuro no hace falta.
    static let softEdge = pair("zas.filo", dark: 0x000000, darkAlpha: 0, light: 0x000000, lightAlpha: 0.14)
    /// Sombra mínima de las cápsulas claras.
    static let softShadow = pair("zas.sombra", dark: 0x000000, darkAlpha: 0, light: 0x000000, lightAlpha: 0.2)
    /// Cuadros del punto transparente.
    static let checker = NSColor.hex(0xB8B8BC)
}

/// Medidas compartidas: si dos piezas se parecen, deben medir lo mismo.
enum Design {
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 10
    /// Barras: radio 14 y margen 6. El botón interior mide 14 - 6 = 8, para que las curvas sean concéntricas.
    static let barRadius: CGFloat = 14
    static let barPadding: CGFloat = 6
    static let edgeMargin: CGFloat = 18
    static let stackGap: CGFloat = 10
    static let actionSize: CGFloat = 32
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
final class GlassButton: NSButton {
    var isActive = false {
        didSet { refresh() }
    }

    /// Color del fondo cuando está activo. Grabar usa rojo; lo demás, el acento del sistema.
    var activeColor: NSColor = Palette.accent {
        didSet { refresh() }
    }

    private var hovering = false
    private var hoverArea: NSTrackingArea?

    init(symbol: String, tooltip: String, target: AnyObject?, action: Selector?, size: CGFloat = Design.actionSize) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
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
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        contentTintColor = isActive ? .alternateSelectedControlTextColor : .labelColor
        setAccessibilityValue(isActive ? "Activo" : nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = isActive ? activeColor : (hovering && isEnabled ? .quaternaryLabelColor : .clear)
            layer?.backgroundColor = fill.cgColor
        }
    }
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
        response: Double = 0.42,
        damping: Double = 0.86,
        step: @escaping @MainActor (CGFloat) -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) -> Timer {
        // Quien pide reducir el movimiento ve el resultado sin el viaje.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
    static let editorBottomBar: CGFloat = 44
    /// Alto de todo control de esas barras.
    static let pillHeight: CGFloat = 30
    /// Botones sin marco dentro de esas barras.
    static let toolSize: CGFloat = 30
    /// Herramienta activa: más ancha que las demás.
    static let activeToolWidth: CGFloat = 42
    static let imagePillWidth: CGFloat = 44
    static let stylePillWidth: CGFloat = 46
    static let bottomActionWidth: CGFloat = 42
    static let dragPillWidth: CGFloat = 128
    static let barGap: CGFloat = 8
    /// Radio de los rectángulos del panel Fondo.
    static let panelRadius: CGFloat = 8
    static let valueChip = CGSize(width: 34, height: 22)
    static let sliderKnob = CGSize(width: 22, height: 14)
    static let sliderTrack: CGFloat = 5
    static let checkbox: CGFloat = 18
    static let checkboxRadius: CGFloat = 5
}

/// Iconos de la barra del editor que SF Symbols no resuelve con el peso de la referencia.
/// Se dibujan en una caja de 16 puntos, con origen abajo.
enum EditorIcon {
    case picture, backdrop, cursor, rectangle, filledRectangle, ellipse, line, arrow, letter, mosaic, focus, number

    func draw(at center: CGPoint, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        context.translateBy(x: (center.x - 8).rounded(), y: (center.y - 8).rounded())
        color.set()
        paint(color: color, context: context)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func polygon(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        path.close()
        return path
    }

    private func stroke(_ points: [CGPoint], width: CGFloat = 2) {
        let path = NSBezierPath()
        guard let first = points.first else { return }
        path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func paint(color: NSColor, context: CGContext) {
        switch self {
        case .picture:
            // Foto llena con su montaña calada y un + que la muerde por la esquina.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let frame = NSBezierPath(roundedRect: CGRect(x: 0, y: 2.5, width: 13.5, height: 11), xRadius: 2.5, yRadius: 2.5)
            frame.append(polygon([
                CGPoint(x: 2, y: 4.5), CGPoint(x: 5, y: 8), CGPoint(x: 6.8, y: 6), CGPoint(x: 8, y: 7), CGPoint(x: 8.8, y: 4.5),
            ]))
            frame.windingRule = .evenOdd
            frame.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: CGRect(x: 7.8, y: -0.7, width: 9.4, height: 9.4)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            stroke([CGPoint(x: 12.5, y: 1.2), CGPoint(x: 12.5, y: 6.8)], width: 1.7)
            stroke([CGPoint(x: 9.7, y: 4), CGPoint(x: 15.3, y: 4)], width: 1.7)
            context.endTransparencyLayer()
        case .backdrop:
            // Marco con una imagen dentro.
            let frame = NSBezierPath(roundedRect: CGRect(x: 0.8, y: 1.8, width: 14.4, height: 12.4), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.6
            frame.stroke()
            let inner = NSBezierPath(roundedRect: CGRect(x: 3.4, y: 4.4, width: 9.2, height: 7.2), xRadius: 1.4, yRadius: 1.4)
            inner.append(polygon([
                CGPoint(x: 4.4, y: 5.4), CGPoint(x: 6.9, y: 8.4), CGPoint(x: 8.5, y: 6.7), CGPoint(x: 9.6, y: 7.7), CGPoint(x: 11.6, y: 5.4),
            ]))
            inner.windingRule = .evenOdd
            inner.fill()
        case .cursor:
            let pointer = polygon([
                CGPoint(x: 4.2, y: 14.6), CGPoint(x: 4.2, y: 3.4), CGPoint(x: 7.2, y: 6.1), CGPoint(x: 9.1, y: 1.8),
                CGPoint(x: 11, y: 2.6), CGPoint(x: 9.2, y: 6.9), CGPoint(x: 13, y: 7.1),
            ])
            pointer.lineWidth = 0.9
            pointer.lineJoinStyle = .round
            pointer.fill()
            pointer.stroke()
        case .rectangle:
            let square = NSBezierPath(roundedRect: CGRect(x: 2.5, y: 2.5, width: 11, height: 11), xRadius: 2, yRadius: 2)
            square.lineWidth = 2
            square.stroke()
        case .filledRectangle:
            NSBezierPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: 13, height: 13), xRadius: 3, yRadius: 3).fill()
        case .ellipse:
            let circle = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 12, height: 12))
            circle.lineWidth = 2.2
            circle.stroke()
        case .line:
            stroke([CGPoint(x: 13, y: 13), CGPoint(x: 3, y: 3)])
        case .arrow:
            stroke([CGPoint(x: 13, y: 13), CGPoint(x: 3.5, y: 3.5)], width: 2.2)
            stroke([CGPoint(x: 3.5, y: 10.5), CGPoint(x: 3.5, y: 3.5), CGPoint(x: 10.5, y: 3.5)], width: 2.2)
        case .letter:
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .bold),
                .foregroundColor: color,
            ]
            let letter = "A" as NSString
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: CGPoint(x: 8 - size.width / 2, y: 8 - size.height / 2), withAttributes: attributes)
        case .mosaic:
            // Tres por tres, ajedrezado, con las esquinas del conjunto redondeadas.
            NSBezierPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: 13, height: 13), xRadius: 3, yRadius: 3).addClip()
            let cell: CGFloat = 13 / 3
            for row in 0..<3 {
                for column in 0..<3 {
                    color.withAlphaComponent((row + column) % 2 == 0 ? 1 : 0.42).setFill()
                    NSBezierPath(rect: CGRect(
                        x: 1.5 + CGFloat(column) * cell,
                        y: 1.5 + CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )).fill()
                }
            }
        case .focus:
            let outer = NSBezierPath(roundedRect: CGRect(x: 0.8, y: 2.3, width: 14.4, height: 11.4), xRadius: 2.6, yRadius: 2.6)
            outer.lineWidth = 1.6
            outer.stroke()
            let inner = NSBezierPath(roundedRect: CGRect(x: 4.2, y: 5.3, width: 7.6, height: 5.4), xRadius: 1, yRadius: 1)
            inner.lineWidth = 1.5
            inner.stroke()
        case .number:
            let disc = NSBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 14, height: 14))
            disc.append(polygon([
                CGPoint(x: 9, y: 3.8), CGPoint(x: 9, y: 12.2), CGPoint(x: 7.4, y: 12.2), CGPoint(x: 5, y: 10.5),
                CGPoint(x: 5, y: 8.8), CGPoint(x: 6.9, y: 9.9), CGPoint(x: 6.9, y: 3.8),
            ]))
            disc.windingRule = .evenOdd
            disc.fill()
        }
    }
}

/// Control de las barras del editor y del panel Fondo. Nunca enseña el borde de `NSButton`:
/// una cápsula o un rectángulo con un punto de color, un grosor, un icono o un texto.
/// Con `chevron` avisa de que abre algo.
final class PillControl: NSButton {
    enum Content {
        case dot(NSColor)
        case stroke(CGFloat)
        case symbol(String)
        case icon(EditorIcon)
        case text(String)
        /// Texto pegado a la izquierda, como en la fila de ajustes guardados.
        case leadingText(String)
    }

    enum Surface {
        case pill, group, accent, clear
    }

    /// Aire alrededor de la forma para que quepa la sombra de `raised`.
    static let shadowRoom: CGFloat = 2

    var content: Content {
        didSet { needsDisplay = true }
    }

    /// Fondo azul e icono blanco.
    var isActive = false {
        didSet {
            setAccessibilityValue(isActive ? "Activo" : nil)
            needsDisplay = true
        }
    }

    /// Color del icono cuando no debe ser el del texto.
    var tint: NSColor? {
        didSet { needsDisplay = true }
    }

    var symbolSize: CGFloat = 14
    var symbolWeight: NSFont.Weight = .semibold
    var textWeight: NSFont.Weight = .medium

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }

    // El dibujo es propio: con origen abajo, como el resto de las vistas de Zas.
    override var isFlipped: Bool { false }

    private let surface: Surface
    private let radius: CGFloat
    private let raised: Bool
    private let showsChevron: Bool
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    private var room: CGFloat { raised ? Self.shadowRoom : 0 }
    private var shape: CGRect { bounds.insetBy(dx: room, dy: room) }

    init(
        content: Content,
        width: CGFloat,
        height: CGFloat = Design.pillHeight,
        radius: CGFloat? = nil,
        surface: Surface = .pill,
        raised: Bool = false,
        tooltip: String,
        chevron: Bool = true,
        target: AnyObject?,
        action: Selector?
    ) {
        self.content = content
        self.surface = surface
        self.radius = radius ?? height / 2
        self.raised = raised
        showsChevron = chevron
        let extra = raised ? PillControl.shadowRoom * 2 : 0
        super.init(frame: CGRect(x: 0, y: 0, width: width + extra, height: height + extra))
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

    /// Ancho de una cápsula con texto de 12, con su relleno a cada lado.
    static func width(for text: String, weight: NSFont.Weight, padding: CGFloat = 14) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: weight)])
        return (size.width + padding * 2).rounded(.up)
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
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    private var fillColor: NSColor? {
        if isActive {
            return Palette.accent
        }
        switch surface {
        case .pill: return Palette.pill
        case .group: return Palette.group
        case .accent: return Palette.accent
        case .clear: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)
        if let fill = fillColor {
            NSGraphicsContext.saveGraphicsState()
            if raised {
                let shadow = NSShadow()
                shadow.shadowColor = Palette.softShadow
                shadow.shadowOffset = CGSize(width: 0, height: -0.5)
                shadow.shadowBlurRadius = 1.5
                shadow.set()
            }
            fill.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if isHighlighted {
            Palette.pressed.setFill()
            path.fill()
        } else if hovering && isEnabled {
            Palette.hover.setFill()
            path.fill()
        }

        let onAccent = isActive || surface == .accent
        let foreground = tint ?? (onAccent ? Palette.onAccent : Palette.text)
        // Con flecha, el contenido se aparta hacia la izquierda y deja sitio a los 10 puntos de la derecha.
        let center = CGPoint(x: shape.minX + (shape.width - (showsChevron ? 10 : 0)) / 2, y: shape.midY)
        drawContent(at: center, color: foreground)

        if showsChevron {
            let chevron = NSBezierPath()
            let x = shape.maxX - 11
            chevron.move(to: CGPoint(x: x - 4, y: shape.midY + 2))
            chevron.line(to: CGPoint(x: x, y: shape.midY - 2))
            chevron.line(to: CGPoint(x: x + 4, y: shape.midY + 2))
            chevron.lineWidth = 1.5
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            Palette.secondaryText.setStroke()
            chevron.stroke()
        }
    }

    private func drawContent(at center: CGPoint, color: NSColor) {
        switch content {
        case .dot(let dotColor):
            let dot = CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
            dotColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
            // El anillo blanco desaparecería sobre la píldora blanca del modo claro.
            Palette.softEdge.setStroke()
            let edge = NSBezierPath(ovalIn: dot.insetBy(dx: -0.25, dy: -0.25))
            edge.lineWidth = 0.5
            edge.stroke()
        case .stroke(let value):
            let line = NSBezierPath()
            line.lineWidth = min(max(1.5 + value * 0.7, 2), 7)
            line.lineCapStyle = .round
            line.move(to: CGPoint(x: center.x - 6.5, y: center.y - 5.5))
            line.line(to: CGPoint(x: center.x + 6.5, y: center.y + 5.5))
            color.setStroke()
            line.stroke()
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: symbolWeight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = symbol.size
                symbol.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
            }
        case .icon(let icon):
            icon.draw(at: center, color: color)
        case .text(let text):
            let attributes = textAttributes(color: color)
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
        case .leadingText(let text):
            let attributes = textAttributes(color: color)
            let size = (text as NSString).size(withAttributes: attributes)
            let room = CGRect(x: shape.minX + 10, y: center.y - size.height / 2, width: shape.width - 32, height: size.height)
            (text as NSString).draw(with: room, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
        }
    }

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: textWeight),
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
        track.lineWidth = 0.5
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
        knob.lineWidth = 0.5
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
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Palette.text,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

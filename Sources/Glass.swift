import AppKit

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
    var activeColor: NSColor = .controlAccentColor {
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
    /// Barras superior e inferior del editor.
    static let editorBar: CGFloat = 44
    /// Botones sin marco dentro de esas barras.
    static let toolSize: CGFloat = 28

    /// Fondo liso y neutro detrás de la captura, en claro y en oscuro.
    static var canvasBackground: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? 0.11 : 0.9, alpha: 1)
        }
    }
}

/// Píldora gris de una barra del editor: un punto de color, un grosor, un símbolo o un texto.
/// Con `chevron` avisa de que abre algo. Con el mismo alto que ancho, es un botón redondo.
final class PillControl: NSButton {
    enum Content {
        case dot(NSColor)
        case stroke(CGFloat)
        case symbol(String)
        case text(String)
    }

    var content: Content {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }

    // El dibujo es propio: con origen abajo, como el resto de las vistas de Zas.
    override var isFlipped: Bool { false }

    private let showsChevron: Bool
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    init(content: Content, width: CGFloat, tooltip: String, chevron: Bool = true, target: AnyObject?, action: Selector?) {
        self.content = content
        showsChevron = chevron
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Design.toolSize))
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
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = isHighlighted || (hovering && isEnabled) ? .tertiaryLabelColor : .quaternaryLabelColor
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let room = showsChevron ? bounds.width - 12 : bounds.width
        let center = CGPoint(x: room / 2 + (showsChevron ? 2 : 0), y: bounds.midY)
        switch content {
        case .dot(let color):
            let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
            color.setFill()
            dot.fill()
            // Contorno visible: si no, el blanco desaparece sobre la barra clara.
            NSColor.tertiaryLabelColor.setStroke()
            dot.lineWidth = 1
            dot.stroke()
        case .stroke(let value):
            let line = NSBezierPath()
            line.lineWidth = min(max(value / 2.5, 1.5), 8)
            line.lineCapStyle = .round
            line.move(to: CGPoint(x: center.x - 8, y: center.y))
            line.line(to: CGPoint(x: center.x + 8, y: center.y))
            NSColor.labelColor.setStroke()
            line.stroke()
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = symbol.size
                symbol.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
            }
        case .text(let text):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
        }

        if showsChevron {
            let chevron = NSBezierPath()
            let x = bounds.maxX - 11
            chevron.move(to: CGPoint(x: x - 3, y: bounds.midY + 1.5))
            chevron.line(to: CGPoint(x: x, y: bounds.midY - 1.5))
            chevron.line(to: CGPoint(x: x + 3, y: bounds.midY + 1.5))
            chevron.lineWidth = 1.4
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.secondaryLabelColor.setStroke()
            chevron.stroke()
        }
    }
}

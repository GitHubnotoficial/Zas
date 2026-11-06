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

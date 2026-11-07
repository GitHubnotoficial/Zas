import AppKit

extension Design {
    /// La firma de Zas: un solo gesto en el instante de capturar.
    enum Signature {
        static let edgeWidth: CGFloat = 2
        /// Largo del filo, como parte del contorno.
        static let trail: CGFloat = 0.22
        static let flashOpacity: Float = 0.5
    }
}

/// Destello blanco y filo amarillo que recorre el contorno una vez.
private final class SignatureView: NSView {
    private let flashLayer = CALayer()
    private let edgeLayer = CAShapeLayer()

    init(frame: CGRect, showsEdge: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }

        let inset = Design.Signature.edgeWidth
        let zone = bounds.insetBy(dx: inset, dy: inset)
        flashLayer.frame = zone
        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        root.addSublayer(flashLayer)

        guard showsEdge else { return }
        edgeLayer.frame = bounds
        edgeLayer.path = CGPath(rect: zone, transform: nil)
        edgeLayer.fillColor = nil
        edgeLayer.strokeColor = Palette.bolt.cgColor
        edgeLayer.lineWidth = Design.Signature.edgeWidth
        edgeLayer.lineCap = .round
        edgeLayer.lineJoin = .round
        edgeLayer.strokeStart = 0
        edgeLayer.strokeEnd = 0
        root.addSublayer(edgeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func flash() {
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, Design.Signature.flashOpacity, 0]
        pulse.keyTimes = [0, 0.3, 1]
        pulse.duration = Design.flashDuration
        flashLayer.add(pulse, forKey: "destello")
    }

    /// De 0 a 1. Al llegar a 1 el filo ya salió del contorno: pasa una sola vez.
    func setEdge(progress: CGFloat) {
        let trail = Design.Signature.trail
        let head = min(max(progress, 0), 1) * (1 + trail)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeLayer.strokeEnd = min(head, 1)
        edgeLayer.strokeStart = min(max(head - trail, 0), 1)
        CATransaction.commit()
    }

    #if ZAS_TEST
    func testFreeze(progress: CGFloat) {
        flashLayer.opacity = Design.Signature.flashOpacity
        setEdge(progress: progress)
    }

    var testHasEdge: Bool { edgeLayer.superlayer != nil }
    #endif
}

/// El instante de la captura. Se dispara cuando la imagen ya existe, junto con el obturador,
/// y por eso no puede salir en ella. Tampoco en un video: Zas se excluye de la grabación
/// y mientras se graba no se puede capturar. El panel además se esconde de toda captura,
/// por si se cruza con otra herramienta. El amarillo no se usa en ningún otro sitio.
@MainActor
final class CaptureSignature {
    static let shared = CaptureSignature()

    private var panel: NSPanel?
    private var spring: Timer?
    private var endTask: Task<Void, Never>?

    private func makePanel(frame: CGRect, hiddenFromCapture: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if hiddenFromCapture {
            panel.sharingType = .none
        }
        return panel
    }

    /// `zone` en coordenadas de AppKit. Con Reducir movimiento queda solo el fundido del destello.
    func play(in zone: CGRect) {
        cancel()
        let inset = Design.Signature.edgeWidth
        let panel = makePanel(frame: zone.insetBy(dx: -inset, dy: -inset), hiddenFromCapture: true)
        let travels = !Design.reduceMotion
        let view = SignatureView(frame: CGRect(origin: .zero, size: panel.frame.size), showsEdge: travels)
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        view.flash()

        guard travels else {
            endTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Design.flashDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.cancel()
            }
            return
        }
        spring = Spring.run(damping: 1, step: { progress in
            view.setEdge(progress: progress)
        }, completion: { [weak self] in
            self?.cancel()
        })
    }

    func cancel() {
        spring?.invalidate()
        spring = nil
        endTask?.cancel()
        endTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    #if ZAS_TEST
    /// La firma detenida a medio camino, a la vista de `screencapture`, para la escena.
    func testFreeze(in zone: CGRect, progress: CGFloat) {
        cancel()
        let inset = Design.Signature.edgeWidth
        let panel = makePanel(frame: zone.insetBy(dx: -inset, dy: -inset), hiddenFromCapture: false)
        let view = SignatureView(frame: CGRect(origin: .zero, size: panel.frame.size), showsEdge: true)
        panel.contentView = view
        panel.orderFrontRegardless()
        view.testFreeze(progress: progress)
        self.panel = panel
    }

    var testIsShowing: Bool { panel?.isVisible == true }
    var testIsHiddenFromCapture: Bool { panel?.sharingType == NSWindow.SharingType.none }
    var testHasEdge: Bool { (panel?.contentView as? SignatureView)?.testHasEdge == true }
    #endif
}

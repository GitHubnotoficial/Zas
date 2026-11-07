import AppKit
import Carbon

extension Design {
    /// Cruz y coordenadas que siguen al cursor antes de empezar a arrastrar.
    enum Crosshair {
        static let dim = NSColor.black.withAlphaComponent(0.3)
        /// Dos líneas contiguas de un píxel: una se ve sobre lo oscuro y la otra sobre lo claro.
        static let lineColor = NSColor.white.withAlphaComponent(0.85)
        static let lineShade = NSColor.black.withAlphaComponent(0.35)
        static let labelFontSize: CGFloat = 10
        static let labelHeight: CGFloat = 18
        static let labelPadding: CGFloat = 7
        static let labelOffset = CGSize(width: 10, height: 10)
    }

    /// Lupa de la pantalla congelada.
    enum Loupe {
        static let side: CGFloat = 96
        /// Aro de material alrededor de los píxeles.
        static let rim: CGFloat = 3
        /// Impar, para que el píxel del cursor quede justo en el centro.
        static let pixels = 15
        /// Baja lo justo para no tapar las coordenadas.
        static let offset = CGSize(width: 16, height: 30)
        static let shadowOpacity: Float = 0.3
        static let shadowRadius: CGFloat = 10
    }
}

enum SelectionMode {
    case screenshot
    case recording
    case text
    case timed
    case scroll
}

extension NSScreen {
    static var underMouse: NSScreen {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main ?? screens[0]
    }

    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }

    /// Desplazamiento entre las coordenadas locales de la pantalla y las globales
    /// (con origen arriba a la izquierda de la pantalla principal).
    var globalTopLeftOrigin: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return NSScreen.topLeftOrigin(of: frame, primaryHeight: primaryHeight)
    }

    static func topLeftOrigin(of frame: CGRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
    }
}

/// Una ventana visible, con su marco en coordenadas globales (origen arriba a la izquierda).
struct WindowTarget {
    let id: CGWindowID
    let frame: CGRect
}

@MainActor
enum WindowFinder {
    /// Las pruebas lo activan para poder resaltar ventanas de este mismo proceso.
    static var includesOwnWindows = false

    /// Procesos del sistema con ventanas invisibles que no se deben resaltar.
    private static let systemOwners: Set<String> = ["Dock", "Window Server", "Wallpaper", "Control Center", "Notification Center"]

    /// Ventanas normales en pantalla, de la más cercana a la más lejana.
    static func onScreenWindows() -> [WindowTarget] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 60, bounds.height >= 40
            else { return nil }

            if let owner = info[kCGWindowOwnerName as String] as? String, systemOwners.contains(owner) {
                return nil
            }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 {
                return nil
            }
            if !includesOwnWindows, let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == ownPID {
                return nil
            }
            return WindowTarget(id: id, frame: bounds)
        }
    }
}

/// Lo que eligió el usuario. `rect` está en puntos, relativo a la pantalla,
/// con origen arriba a la izquierda.
@MainActor
struct Selection {
    let screen: NSScreen
    let rect: CGRect
    var windowID: CGWindowID?
    /// Tamaño completo de la ventana: `rect` solo cubre la parte que cabe en esta pantalla.
    var windowSize: CGSize?
    /// Recorte de la pantalla congelada: ya no hace falta capturar.
    var frozen: CGImage?

    static func fullScreen(_ screen: NSScreen) -> Selection {
        Selection(screen: screen, rect: CGRect(origin: .zero, size: screen.frame.size))
    }

    /// Tamaño real de la captura en puntos. No se deduce del archivo:
    /// `screencapture` no siempre anota la densidad de una pantalla Retina.
    var imagePointSize: CGSize {
        windowSize ?? rect.size
    }

    var isFullScreen: Bool {
        windowID == nil && rect.size == screen.frame.size
    }

    /// Coordenadas globales, que es lo que espera `screencapture -R`.
    var globalTopLeftRect: CGRect {
        rect.offsetBy(dx: screen.globalTopLeftOrigin.x, dy: screen.globalTopLeftOrigin.y)
    }

    /// Coordenadas de AppKit (origen abajo a la izquierda), para colocar ventanas.
    var appKitRect: CGRect {
        CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    var captureArguments: [String] {
        if let windowID {
            // -o quita la sombra para que la captura quede justa a la ventana.
            return ["-x", "-o", "-l\(windowID)"]
        }
        return ["-x", Capture.regionArgument(globalTopLeftRect)]
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Oscurece las pantallas y deja elegir: arrastrar marca un área, un clic toma la ventana.
/// Usa paneles que no activan la app, así la ventana de atrás no pierde el foco
/// y sale normal en la captura.
@MainActor
final class SelectionOverlay {
    private var panels: [KeyablePanel] = []
    private var escapeHotKey: UInt32?
    private var completion: (@MainActor (Selection?) -> Void)?

    /// Puede cambiar con la barra de vidrio mientras se elige.
    private(set) var mode: SelectionMode = .screenshot

    var isActive: Bool { completion != nil }

    func begin(mode: SelectionMode, completion: @escaping @MainActor (Selection?) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        self.mode = mode
        isFrozen = false

        let windows = WindowFinder.onScreenWindows()
        let target = NSScreen.underMouse

        for screen in NSScreen.screens {
            let panel = KeyablePanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.setFrame(screen.frame, display: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = OverlayView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                screen: screen,
                windows: windows,
                owner: self
            )
            panel.contentView = view
            panel.makeFirstResponder(view)
            panels.append(panel)

            if screen == target {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }

        NSCursor.crosshair.set()

        // Esc como atajo temporal: funciona aunque la app no sea la activa.
        escapeHotKey = HotKeys.shared.register(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
            self?.finish(nil)
        }
    }

    func cancel() {
        finish(nil)
    }

    private(set) var isFrozen = false

    /// Congela lo que se ve: sirve para capturar menús o algo que se mueve.
    /// Al congelar aparece la lupa, porque ya hay píxeles que ampliar.
    fileprivate func freeze() {
        guard !isFrozen else { return }
        isFrozen = true
        let current = panels
        current.forEach { ($0.contentView as? OverlayView)?.showFrozen() }
        Task { @MainActor in
            guard #available(macOS 14.0, *) else {
                await freezeHidingPanels(current)
                return
            }
            // La pantalla sigue a la vista: el filtro deja fuera solo esta capa oscura.
            let own = current.map { CGWindowID($0.windowNumber) }
            var missing: [KeyablePanel] = []
            for panel in current {
                guard let view = panel.contentView as? OverlayView else { continue }
                if let image = await Capture.screenImage(of: view.capturedScreen, excluding: own) {
                    view.setFrozen(image)
                } else {
                    missing.append(panel)
                }
            }
            await freezeHidingPanels(missing)
        }
    }

    /// Lo que queda antes de macOS 14 o si el sistema no entrega la imagen: esconder y capturar.
    private func freezeHidingPanels(_ hidden: [KeyablePanel]) async {
        guard !hidden.isEmpty else { return }
        hidden.forEach { $0.alphaValue = 0 }
        try? await Task.sleep(nanoseconds: 90_000_000)
        for panel in hidden {
            guard let view = panel.contentView as? OverlayView else { continue }
            let url = Capture.temporaryFileURL()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Capture.run(arguments: view.freezeArguments, to: url) { _ in
                    continuation.resume()
                }
            }
            let frozen = await Task.detached(priority: .userInitiated) {
                Unchecked(value: Capture.image(at: url))
            }.value
            view.setFrozen(frozen.value)
            try? FileManager.default.removeItem(at: url)
            panel.alphaValue = 1
        }
    }

    fileprivate func choose(mode: SelectionMode) {
        self.mode = mode
        for panel in panels {
            (panel.contentView as? OverlayView)?.refreshMode()
        }
    }

    fileprivate func finish(_ selection: Selection?) {
        guard let completion else { return }
        self.completion = nil

        if let escapeHotKey {
            HotKeys.shared.unregister(escapeHotKey)
            self.escapeHotKey = nil
        }
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()

        completion(selection)
    }

    #if ZAS_TEST
    func simulateDrag(from start: CGPoint, to end: CGPoint) {
        for panel in panels {
            (panel.contentView as? OverlayView)?.simulateDrag(from: start, to: end)
        }
    }

    func simulateHover(at point: CGPoint) {
        for panel in panels {
            (panel.contentView as? OverlayView)?.simulateHover(at: point)
        }
    }

    func testFreeze() {
        freeze()
    }

    /// La pantalla oscurecida ya está en pantalla.
    var testIsShowing: Bool { !panels.isEmpty && panels.allSatisfy(\.isVisible) }

    func testChoose(mode: SelectionMode) {
        choose(mode: mode)
    }

    private var testView: OverlayView? {
        panels.first { $0.screen == NSScreen.screens[0] }?.contentView as? OverlayView ?? panels.first?.contentView as? OverlayView
    }

    var testCoordinates: String? { testView?.testCoordinates }
    var testFreezeState: String? { testView?.testFreezeState }
    var testFreezeIsActive: Bool { testView?.testFreezeIsActive ?? false }
    var testHUDWidth: CGFloat? { testView?.testHUDWidth }
    var testCrossLines: Int { testView?.testCrossLines ?? 0 }
    var testFrozenImage: CGImage? { testView?.testFrozenImage }
    var testLoupeSide: CGFloat? { testView?.testLoupeSide }
    #endif
}

/// Se dibuja con capas: redibujar una pantalla 5K en cada movimiento del ratón pierde cuadros.
private final class OverlayView: NSView {
    private let screen: NSScreen
    private let windows: [WindowTarget]
    private weak var owner: SelectionOverlay?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var hoveredWindow: WindowTarget?
    private var trackingArea: NSTrackingArea?

    private let dimLayer = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    private let frozenLayer = CALayer()
    private let loupeShadow = CALayer()
    private let crossHorizontal = CALayer()
    private let crossVertical = CALayer()
    private let crossHorizontalShade = CALayer()
    private let crossVerticalShade = CALayer()
    private let loupe = GlassView(
        frame: CGRect(x: 0, y: 0, width: Design.Loupe.side, height: Design.Loupe.side),
        radius: Design.Loupe.side / 2,
        material: .hudWindow,
        blending: .withinWindow
    )
    private let loupePixels = NSView()
    private let coordinates = GlassView(frame: .zero, radius: Design.Crosshair.labelHeight / 2, material: .hudWindow)
    private let coordinatesLabel = NSTextField(labelWithString: "")
    private var frozenImage: CGImage?
    private var mousePoint: NSPoint?
    private let sizePill = GlassView(frame: .zero, radius: Design.radiusMedium)
    private let sizeLabel = NSTextField(labelWithString: "")
    private var hud: GlassView?
    private var modeButtons: [(SelectionMode, GlassButton)] = []
    private weak var freezeButton: GlassButton?

    init(frame: CGRect, screen: NSScreen, windows: [WindowTarget], owner: SelectionOverlay) {
        self.screen = screen
        self.windows = windows
        self.owner = owner
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Selección de captura. Arrastra para elegir un área.")
        buildLayers()
        buildLoupe()
        buildPill()
        buildHUD()
        refreshMode()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildLayers() {
        guard let root = layer else { return }
        frozenLayer.frame = bounds
        frozenLayer.contentsGravity = .resize
        root.addSublayer(frozenLayer)

        dimLayer.frame = bounds
        dimLayer.fillColor = Design.Crosshair.dim.cgColor
        dimLayer.fillRule = .evenOdd
        root.addSublayer(dimLayer)

        frameLayer.frame = bounds
        frameLayer.fillColor = nil
        frameLayer.lineWidth = 1.5
        root.addSublayer(frameLayer)

        // Un píxel de verdad, sin sombra, en cualquier densidad.
        for cross in [crossHorizontal, crossHorizontalShade] {
            cross.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: crossLine)
        }
        for cross in [crossVertical, crossVerticalShade] {
            cross.bounds = CGRect(x: 0, y: 0, width: crossLine, height: bounds.height)
        }
        for cross in crossLayers {
            cross.anchorPoint = .zero
            cross.backgroundColor = Design.Crosshair.lineColor.cgColor
            cross.isHidden = true
            root.addSublayer(cross)
        }
        crossHorizontalShade.backgroundColor = Design.Crosshair.lineShade.cgColor
        crossVerticalShade.backgroundColor = Design.Crosshair.lineShade.cgColor

        // La sombra va aparte: el círculo recorta todo lo que tiene dentro.
        let side = Design.Loupe.side
        loupeShadow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        loupeShadow.shadowPath = CGPath(ellipseIn: loupeShadow.bounds, transform: nil)
        loupeShadow.shadowColor = NSColor.black.cgColor
        loupeShadow.shadowOpacity = Design.Loupe.shadowOpacity
        loupeShadow.shadowRadius = Design.Loupe.shadowRadius
        loupeShadow.shadowOffset = CGSize(width: 0, height: 2)
        loupeShadow.isHidden = true
        root.addSublayer(loupeShadow)
    }

    /// Círculo de material con los píxeles ampliados y un cuadro de un punto, blanco y negro
    /// alternos, alrededor del píxel central: se lee sobre cualquier color.
    private func buildLoupe() {
        let inner = Design.Loupe.side - Design.Loupe.rim * 2
        loupePixels.frame = CGRect(x: Design.Loupe.rim, y: Design.Loupe.rim, width: inner, height: inner)
        loupePixels.wantsLayer = true
        if let pixels = loupePixels.layer {
            pixels.cornerRadius = inner / 2
            pixels.masksToBounds = true
            pixels.magnificationFilter = .nearest
            pixels.contentsGravity = .resize
            let pixel = inner / CGFloat(Design.Loupe.pixels)
            let box = CGRect(x: (inner - pixel) / 2 - 0.5, y: (inner - pixel) / 2 - 0.5, width: pixel + 1, height: pixel + 1)
            let strokes: [(color: NSColor, dashes: [NSNumber]?)] = [(.white, nil), (.black, [2, 2])]
            for (color, dashes) in strokes {
                let line = CAShapeLayer()
                line.frame = CGRect(x: 0, y: 0, width: inner, height: inner)
                line.path = CGPath(rect: box, transform: nil)
                line.fillColor = nil
                line.strokeColor = color.cgColor
                line.lineWidth = 1
                line.lineDashPattern = dashes
                pixels.addSublayer(line)
            }
        }
        loupe.addSubview(loupePixels)
        loupe.isHidden = true
        addSubview(loupe)
    }

    var freezeArguments: [String] {
        let origin = screen.globalTopLeftOrigin
        return ["-x", Capture.regionArgument(CGRect(origin: origin, size: bounds.size))]
    }

    func setFrozen(_ image: CGImage?) {
        frozenImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frozenLayer.contents = image
        CATransaction.commit()
        if image != nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Design.flashDuration
            frozenLayer.add(fade, forKey: "fundido")
        }
        refresh()
    }

    var capturedScreen: NSScreen { screen }

    /// Solo cambia el icono: la barra no se mueve. VoiceOver sigue anunciando el estado.
    func showFrozen() {
        guard let freezeButton, !freezeButton.isActive else { return }
        freezeButton.activeValue = "Congelada"
        freezeButton.isActive = true
    }

    private func crop(_ rect: CGRect) -> CGImage? {
        guard let frozenImage else { return nil }
        let scale = CGFloat(frozenImage.width) / max(bounds.width, 1)
        return frozenImage.cropping(to: CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ))
    }

    private func hideLoupe() {
        loupe.isHidden = true
        loupeShadow.isHidden = true
    }

    /// Quince píxeles reales alrededor del cursor, ampliados, para acertar al píxel.
    private func refreshMagnifier() {
        guard let frozenImage, let mousePoint else {
            hideLoupe()
            return
        }
        let scale = CGFloat(frozenImage.width) / max(bounds.width, 1)
        let count = CGFloat(Design.Loupe.pixels)
        let reach = (count / 2).rounded(.down)
        let left = (mousePoint.x * scale).rounded(.down) - reach
        let top = (mousePoint.y * scale).rounded(.down) - reach
        guard let piece = frozenImage.cropping(to: CGRect(
            x: min(max(left, 0), CGFloat(frozenImage.width) - count),
            y: min(max(top, 0), CGFloat(frozenImage.height) - count),
            width: count,
            height: count
        )) else {
            hideLoupe()
            return
        }
        loupePixels.layer?.contents = piece
        // Abajo a la derecha del cursor. Junto a un borde, pasa al otro lado.
        let side = Design.Loupe.side
        let offset = Design.Loupe.offset
        let x = mousePoint.x + offset.width + side > bounds.maxX ? mousePoint.x - offset.width - side : mousePoint.x + offset.width
        let y = mousePoint.y + offset.height + side > bounds.maxY ? mousePoint.y - offset.height - side : mousePoint.y + offset.height
        let origin = CGPoint(x: x.rounded(), y: y.rounded())
        loupe.frame.origin = origin
        loupeShadow.position = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
        loupe.isHidden = false
        loupeShadow.isHidden = false
    }

    /// Solo antes de arrastrar, y nunca sobre la barra de modos, donde el cursor es la flecha.
    /// Es parte del panel: se va con él antes de capturar y al congelar.
    private func refreshCrosshair() {
        guard startPoint == nil, let point = mousePoint, hud?.frame.contains(point) != true else {
            crossLayers.forEach { $0.isHidden = true }
            coordinates.isHidden = true
            return
        }
        let x = point.x.rounded(.down)
        let y = point.y.rounded(.down)
        crossHorizontal.position = CGPoint(x: 0, y: y)
        crossHorizontalShade.position = CGPoint(x: 0, y: y + crossLine)
        crossVertical.position = CGPoint(x: x, y: 0)
        crossVerticalShade.position = CGPoint(x: x + crossLine, y: 0)
        crossLayers.forEach { $0.isHidden = false }

        // En píxeles, igual que la píldora de tamaño.
        let scale = screen.backingScaleFactor
        coordinatesLabel.stringValue = "\(Int(point.x * scale)), \(Int(point.y * scale))"
        coordinatesLabel.sizeToFit()
        let height = Design.Crosshair.labelHeight
        let padding = Design.Crosshair.labelPadding
        let size = CGSize(width: (coordinatesLabel.frame.width + padding * 2).rounded(.up), height: height)
        let offset = Design.Crosshair.labelOffset
        coordinates.frame = CGRect(
            x: point.x + offset.width + size.width > bounds.maxX ? point.x - offset.width - size.width : point.x + offset.width,
            y: point.y + offset.height + size.height > bounds.maxY ? point.y - offset.height - size.height : point.y + offset.height,
            width: size.width,
            height: size.height
        )
        coordinatesLabel.frame.origin = CGPoint(x: padding, y: ((height - coordinatesLabel.frame.height) / 2).rounded())
        coordinates.isHidden = false
    }

    private var crossLayers: [CALayer] {
        [crossHorizontal, crossHorizontalShade, crossVertical, crossVerticalShade]
    }

    private var crossLine: CGFloat {
        1 / max(screen.backingScaleFactor, 1)
    }

    private func buildPill() {
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.textColor = Palette.text
        sizePill.addSubview(sizeLabel)
        sizePill.isHidden = true
        addSubview(sizePill)
        coordinatesLabel.font = .monospacedDigitSystemFont(ofSize: Design.Crosshair.labelFontSize, weight: .regular)
        coordinatesLabel.textColor = Palette.text
        coordinates.addSubview(coordinatesLabel)
        coordinates.isHidden = true
        addSubview(coordinates)
    }

    /// Barra de modos: lo demás no se muestra hasta que hace falta.
    private func buildHUD() {
        let entries: [(SelectionMode, String, String)] = [
            (.screenshot, HotKeyAction.region.symbol, HotKeyAction.region.title),
            (.text, HotKeyAction.text.symbol, HotKeyAction.text.title),
            (.timed, HotKeyAction.timed.symbol, HotKeyAction.timed.title),
            (.scroll, HotKeyAction.scroll.symbol, HotKeyAction.scroll.title),
            (.recording, HotKeyAction.record.symbol, HotKeyAction.record.title),
        ]
        let hint = NSTextField(labelWithString: "Esc para cancelar")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = Palette.secondaryText
        hint.sizeToFit()

        let padding = Design.barPadding
        let height = Design.actionSize + padding * 2
        let glass = GlassView(frame: CGRect(x: 0, y: 0, width: 0, height: height), radius: Design.barRadius)

        var x = padding
        for (mode, symbol, tooltip) in entries {
            let button = GlassButton(symbol: symbol, tooltip: tooltip, target: self, action: #selector(modePressed(_:)))
            button.frame.origin = CGPoint(x: x, y: padding)
            glass.addSubview(button)
            modeButtons.append((mode, button))
            x += Design.actionSize + 2
        }
        // Los modos se eligen; estas dos son acciones. El aire las separa, sin líneas.
        x += 10
        let full = GlassButton(symbol: HotKeyAction.fullScreen.symbol, tooltip: HotKeyAction.fullScreen.title, target: self, action: #selector(fullScreenPressed))
        full.frame.origin = CGPoint(x: x, y: padding)
        glass.addSubview(full)
        x += Design.actionSize + 2
        let still = GlassButton(symbol: "pause.circle", tooltip: "Congelar la pantalla (F)", target: self, action: #selector(freezePressed))
        freezeButton = still
        still.frame.origin = CGPoint(x: x, y: padding)
        glass.addSubview(still)
        x += Design.actionSize + 12

        hint.frame.origin = CGPoint(x: x, y: ((height - hint.frame.height) / 2).rounded())
        glass.addSubview(hint)
        let width = x + hint.frame.width + 14

        // Por encima del Dock, centrada en la zona visible.
        let visible = screen.visibleFrame
        let bottomInset = visible.minY - screen.frame.minY
        glass.frame = CGRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: (bounds.height - bottomInset - height - 22).rounded(),
            width: width,
            height: height
        )
        addSubview(glass)
        hud = glass
    }

    @objc private func modePressed(_ sender: GlassButton) {
        guard let entry = modeButtons.first(where: { $0.1 === sender }) else { return }
        owner?.choose(mode: entry.0)
    }

    @objc private func freezePressed() {
        owner?.freeze()
    }

    @objc private func fullScreenPressed() {
        var selection = Selection.fullScreen(screen)
        selection.frozen = frozenImage
        let owner = self.owner
        Task { @MainActor in
            owner?.finish(selection)
        }
    }

    func refreshMode() {
        let current = owner?.mode ?? .screenshot
        for (mode, button) in modeButtons {
            button.activeColor = mode == .recording ? .systemRed : Palette.accent
            button.isActive = mode == current
        }
        refresh()
    }

    private var accent: NSColor {
        owner?.mode == .recording ? .systemRed : .white
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Refleja la posición inicial del cursor sin esperar a que se mueva.
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point) {
            updateHover(at: point)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func setCursor(at point: NSPoint) {
        if hud?.frame.contains(point) == true {
            NSCursor.arrow.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        setCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setCursor(at: point)
        updateHover(at: point)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredWindow = nil
        mousePoint = nil
        refresh()
    }

    private func updateHover(at point: NSPoint) {
        mousePoint = point
        let origin = screen.globalTopLeftOrigin
        let global = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        hoveredWindow = hud?.frame.contains(point) == true ? nil : windows.first { $0.frame.contains(global) }
        refresh()
    }

    /// Marco de la ventana resaltada, recortado a esta pantalla.
    private var hoveredRect: CGRect? {
        guard let hoveredWindow else { return nil }
        let origin = screen.globalTopLeftOrigin
        let local = hoveredWindow.frame.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds)
        return local.isEmpty ? nil : local
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(for: event)
        startPoint = point
        currentPoint = point
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = clampedPoint(for: event)
        mousePoint = currentPoint
        NSCursor.crosshair.set()
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = clampedPoint(for: event)
        let rect = selectionRect
        startPoint = nil
        currentPoint = nil

        var selection: Selection
        if let rect, rect.width >= 4, rect.height >= 4 {
            selection = Selection(screen: screen, rect: rect.integral)
        } else if let hoveredWindow, let hoveredRect {
            selection = Selection(
                screen: screen,
                rect: hoveredRect.integral,
                windowID: hoveredWindow.id,
                windowSize: hoveredWindow.frame.size
            )
        } else {
            // Clic en el escritorio: toda la pantalla.
            selection = .fullScreen(screen)
        }
        if frozenImage != nil {
            selection.frozen = crop(selection.rect)
            selection.windowID = nil
            selection.windowSize = nil
        }

        let owner = self.owner
        Task { @MainActor in
            owner?.finish(selection)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let owner = self.owner
        Task { @MainActor in
            owner?.finish(nil)
        }
    }

    /// Respaldo por si otra app tiene ocupado el Esc como atajo global.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            owner?.finish(nil)
        } else if event.charactersIgnoringModifiers?.lowercased() == "f" {
            freezePressed()
        } else if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...modeButtons.count).contains(digit) {
            owner?.choose(mode: modeButtons[digit - 1].0)
        } else {
            super.keyDown(with: event)
        }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }

    private func clampedPoint(for event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// Solo cambian las capas afectadas, y sin las animaciones implícitas de Core Animation.
    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        refreshMagnifier()
        refreshCrosshair()

        let dragging = selectionRect.map { $0.width > 0 && $0.height > 0 } ?? false
        let isWindow = !dragging && hoveredRect != nil
        let rect = dragging ? selectionRect : hoveredRect
        // Una ventana casi fuera de la pantalla puede ser más estrecha que sus esquinas.
        let radius: CGFloat = isWindow ? min(Design.radiusMedium, min(rect?.width ?? 0, rect?.height ?? 0) / 2) : 0

        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let rect {
            dim.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        dimLayer.path = dim

        hud?.isHidden = startPoint != nil
        guard let rect else {
            frameLayer.path = nil
            sizePill.isHidden = true
            return
        }

        let inset = frameLayer.lineWidth / 2
        frameLayer.path = CGPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        frameLayer.strokeColor = accent.cgColor

        let scale = screen.backingScaleFactor
        sizeLabel.stringValue = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        sizeLabel.sizeToFit()
        let pill = CGSize(width: sizeLabel.frame.width + 24, height: 24)
        var y = rect.maxY + 10
        if y + pill.height > bounds.maxY - 8 {
            y = rect.maxY - pill.height - 10
        }
        sizePill.frame = CGRect(
            x: max(8, min(rect.minX, bounds.maxX - pill.width - 8)),
            y: y,
            width: pill.width,
            height: pill.height
        )
        sizeLabel.frame.origin = CGPoint(x: 12, y: ((pill.height - sizeLabel.frame.height) / 2).rounded())
        sizePill.isHidden = false
    }

    #if ZAS_TEST
    func simulateDrag(from start: CGPoint, to end: CGPoint) {
        startPoint = start
        currentPoint = end
        refresh()
    }

    func simulateHover(at point: CGPoint) {
        startPoint = nil
        currentPoint = nil
        updateHover(at: point)
    }

    var testCoordinates: String? { coordinates.isHidden ? nil : coordinatesLabel.stringValue }
    var testFreezeState: String? { freezeButton?.testActiveValue }
    var testFreezeIsActive: Bool { freezeButton?.isActive == true }
    var testHUDWidth: CGFloat? { hud?.frame.width }
    /// Líneas de la cruz a la vista, sin mezcla: deben leerse sobre cualquier fondo, también en vivo.
    var testCrossLines: Int { crossLayers.filter { !$0.isHidden && $0.compositingFilter == nil }.count }
    var testFrozenImage: CGImage? { frozenImage }
    var testLoupeSide: CGFloat? { loupe.isHidden ? nil : loupe.frame.width }
    #endif
}

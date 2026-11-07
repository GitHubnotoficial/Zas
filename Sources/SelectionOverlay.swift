import AppKit
import Carbon

extension Design {
    /// Cruz y coordenadas que siguen al cursor antes de empezar a arrastrar.
    enum Crosshair {
        static let dim = NSColor.black.withAlphaComponent(0.3)
        static let lineWidth: CGFloat = 1
        static let lineColor = NSColor.white.withAlphaComponent(0.5)
        /// La sombra oscura es lo que deja ver la línea blanca sobre una ventana clara.
        static let shadowColor = NSColor.black
        static let lineShadowOpacity: Float = 0.6
        static let lineShadowRadius: CGFloat = 0.75
        static let labelFontSize: CGFloat = 9
        static let labelLineHeight: CGFloat = 10
        static let labelSize = CGSize(width: 44, height: 24)
        /// Sitio para que la sombra del texto no se corte en el borde de la vista.
        static let labelInset: CGFloat = 2
        static let labelOffset = CGSize(width: 3, height: 1)
        static let labelColor = NSColor.white
        static let labelShadowRadius: CGFloat = 1.5
    }

    /// Lupa de la pantalla congelada.
    enum Loupe {
        static let side: CGFloat = 82
        static let radius: CGFloat = 8
        /// Impar, para que el píxel del cursor quede justo en el centro.
        static let pixels = 15
        /// Baja lo justo para no tapar las coordenadas.
        static let offset = CGSize(width: 16, height: 26)
        static let borderWidth: CGFloat = 1
        static let borderColor = NSColor.black.withAlphaComponent(0.55)
        static let armColor = NSColor.black.withAlphaComponent(0.4)
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
        current.forEach { $0.alphaValue = 0 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            for panel in current {
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
    #endif
}

/// Coordenadas del cursor, sin fondo. Los clics las atraviesan.
private final class CoordinatesView: NSView {
    private static let attributes: [NSAttributedString.Key: Any] = {
        let shadow = NSShadow()
        shadow.shadowColor = Design.Crosshair.shadowColor
        shadow.shadowBlurRadius = Design.Crosshair.labelShadowRadius
        shadow.shadowOffset = .zero
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Design.Crosshair.labelLineHeight
        paragraph.maximumLineHeight = Design.Crosshair.labelLineHeight
        return [
            .font: NSFont.monospacedSystemFont(ofSize: Design.Crosshair.labelFontSize, weight: .medium),
            .foregroundColor: Design.Crosshair.labelColor,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ]
    }()

    var text = "" {
        didSet {
            if text != oldValue {
                needsDisplay = true
            }
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let inset = Design.Crosshair.labelInset
        (text as NSString).draw(in: bounds.insetBy(dx: inset, dy: inset), withAttributes: Self.attributes)
    }
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
    private let magnifier = CALayer()
    private let crossHorizontal = CALayer()
    private let crossVertical = CALayer()
    private let coordinates = CoordinatesView(frame: CGRect(origin: .zero, size: Design.Crosshair.labelSize))
    private var frozenImage: CGImage?
    private var mousePoint: NSPoint?
    private let sizePill = GlassView(frame: .zero, radius: 13)
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

        let line = Design.Crosshair.lineWidth
        crossHorizontal.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: line)
        crossVertical.bounds = CGRect(x: 0, y: 0, width: line, height: bounds.height)
        for cross in [crossHorizontal, crossVertical] {
            cross.anchorPoint = .zero
            cross.backgroundColor = Design.Crosshair.lineColor.cgColor
            cross.shadowColor = Design.Crosshair.shadowColor.cgColor
            cross.shadowOpacity = Design.Crosshair.lineShadowOpacity
            cross.shadowRadius = Design.Crosshair.lineShadowRadius
            cross.shadowOffset = .zero
            // Con la forma dada, moverla no vuelve a calcular la sombra.
            cross.shadowPath = CGPath(rect: cross.bounds, transform: nil)
            cross.isHidden = true
            root.addSublayer(cross)
        }

        let side = Design.Loupe.side
        magnifier.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        magnifier.cornerRadius = Design.Loupe.radius
        magnifier.cornerCurve = .continuous
        magnifier.masksToBounds = true
        magnifier.borderWidth = Design.Loupe.borderWidth
        magnifier.borderColor = Design.Loupe.borderColor.cgColor
        // Cruz ancha de un píxel de grueso: sus cuatro brazos dejan libre el píxel central.
        let pixel = side / CGFloat(Design.Loupe.pixels)
        let low = (side - pixel) / 2
        let high = (side + pixel) / 2
        for frame in [
            CGRect(x: 0, y: low, width: low, height: pixel),
            CGRect(x: high, y: low, width: low, height: pixel),
            CGRect(x: low, y: 0, width: pixel, height: low),
            CGRect(x: low, y: high, width: pixel, height: low),
        ] {
            let arm = CALayer()
            arm.frame = frame
            arm.backgroundColor = Design.Loupe.armColor.cgColor
            magnifier.addSublayer(arm)
        }
        magnifier.magnificationFilter = .nearest
        magnifier.contentsGravity = .resize
        magnifier.isHidden = true
        root.addSublayer(magnifier)
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
        refresh()
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

    /// Quince píxeles reales alrededor del cursor, ampliados, para acertar al píxel.
    private func refreshMagnifier() {
        guard let frozenImage, let mousePoint else {
            magnifier.isHidden = true
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
            magnifier.isHidden = true
            return
        }
        magnifier.contents = piece
        // Abajo a la derecha del cursor. Junto a un borde, pasa al otro lado.
        let side = magnifier.bounds.width
        let offset = Design.Loupe.offset
        let x = mousePoint.x + offset.width + side > bounds.maxX ? mousePoint.x - offset.width - side / 2 : mousePoint.x + offset.width + side / 2
        let y = mousePoint.y + offset.height + side > bounds.maxY ? mousePoint.y - offset.height - side / 2 : mousePoint.y + offset.height + side / 2
        magnifier.position = CGPoint(x: x.rounded(), y: y.rounded())
        magnifier.isHidden = false
    }

    /// Solo antes de arrastrar, y nunca sobre la barra de modos, donde el cursor es la flecha.
    /// Es parte del panel: se va con él antes de capturar y al congelar.
    private func refreshCrosshair() {
        guard startPoint == nil, let point = mousePoint, hud?.frame.contains(point) != true else {
            crossHorizontal.isHidden = true
            crossVertical.isHidden = true
            coordinates.isHidden = true
            return
        }
        crossHorizontal.position = CGPoint(x: 0, y: point.y.rounded(.down))
        crossVertical.position = CGPoint(x: point.x.rounded(.down), y: 0)
        crossHorizontal.isHidden = false
        crossVertical.isHidden = false

        // En píxeles, igual que la píldora de tamaño.
        let scale = screen.backingScaleFactor
        coordinates.text = "\(Int(point.x * scale))\n\(Int(point.y * scale))"
        let size = coordinates.frame.size
        let offset = Design.Crosshair.labelOffset
        coordinates.frame.origin = CGPoint(
            x: point.x + offset.width + size.width > bounds.maxX ? point.x - offset.width - size.width : point.x + offset.width,
            y: point.y + offset.height + size.height > bounds.maxY ? point.y - offset.height - size.height : point.y + offset.height
        )
        coordinates.isHidden = false
    }

    private func buildPill() {
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = Palette.text
        sizePill.addSubview(sizeLabel)
        sizePill.isHidden = true
        addSubview(sizePill)
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
        let width = padding + CGFloat(entries.count + 2) * (Design.actionSize + 2) + 18 + hint.frame.width + 14
        let height = Design.actionSize + padding * 2
        let glass = GlassView(frame: CGRect(x: 0, y: 0, width: width, height: height), radius: Design.barRadius)

        var x = padding
        for (mode, symbol, tooltip) in entries {
            let button = GlassButton(symbol: symbol, tooltip: tooltip, target: self, action: #selector(modePressed(_:)))
            button.frame.origin = CGPoint(x: x, y: padding)
            glass.addSubview(button)
            modeButtons.append((mode, button))
            x += Design.actionSize + 2
        }
        // Los modos se eligen; estas dos son acciones, por eso van separadas.
        x += 3
        let divider = NSBox(frame: CGRect(x: x, y: padding + 7, width: 1, height: Design.actionSize - 14))
        divider.boxType = .separator
        glass.addSubview(divider)
        x += 6
        let full = GlassButton(symbol: HotKeyAction.fullScreen.symbol, tooltip: HotKeyAction.fullScreen.title, target: self, action: #selector(fullScreenPressed))
        full.frame.origin = CGPoint(x: x, y: padding)
        glass.addSubview(full)
        x += Design.actionSize + 2
        let still = GlassButton(symbol: "pause", tooltip: "Congelar la pantalla (F)", target: self, action: #selector(freezePressed))
        freezeButton = still
        still.frame.origin = CGPoint(x: x, y: padding)
        glass.addSubview(still)
        x += Design.actionSize + 12

        hint.frame.origin = CGPoint(x: x, y: ((height - hint.frame.height) / 2).rounded())
        glass.addSubview(hint)

        // Por encima del Dock, centrada en la zona visible.
        let visible = screen.visibleFrame
        let bottomInset = visible.minY - screen.frame.minY
        glass.frame.origin = CGPoint(
            x: ((bounds.width - width) / 2).rounded(),
            y: (bounds.height - bottomInset - height - 22).rounded()
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
        freezeButton?.isActive = true
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
        let radius: CGFloat = isWindow ? 10 : 2

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
        let pill = CGSize(width: sizeLabel.frame.width + 24, height: 26)
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
    #endif
}

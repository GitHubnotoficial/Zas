import AppKit
import Carbon

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
                view.setFrozen(Capture.image(at: url))
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

    func testChoose(mode: SelectionMode) {
        choose(mode: mode)
    }
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
    private let handles = (0..<4).map { _ in CALayer() }
    private let frozenLayer = CALayer()
    private let magnifier = CALayer()
    private var frozenImage: CGImage?
    private var mousePoint: NSPoint?
    private let sizePill = GlassView(frame: .zero, radius: 13)
    private let sizeLabel = NSTextField(labelWithString: "")
    private var hud: GlassView?
    private var modeButtons: [(SelectionMode, GlassButton)] = []

    init(frame: CGRect, screen: NSScreen, windows: [WindowTarget], owner: SelectionOverlay) {
        self.screen = screen
        self.windows = windows
        self.owner = owner
        super.init(frame: frame)
        wantsLayer = true
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildLayers() {
        guard let root = layer else { return }
        frozenLayer.frame = bounds
        frozenLayer.contentsGravity = .resize
        root.addSublayer(frozenLayer)

        dimLayer.frame = bounds
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.3).cgColor
        dimLayer.fillRule = .evenOdd
        root.addSublayer(dimLayer)

        frameLayer.frame = bounds
        frameLayer.fillColor = nil
        frameLayer.lineWidth = 1.5
        root.addSublayer(frameLayer)

        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
            handle.cornerRadius = 4.5
            handle.backgroundColor = NSColor.white.cgColor
            handle.shadowColor = NSColor.black.cgColor
            handle.shadowOpacity = 0.35
            handle.shadowRadius = 2
            handle.shadowOffset = .zero
            root.addSublayer(handle)
        }

        magnifier.bounds = CGRect(x: 0, y: 0, width: 132, height: 132)
        magnifier.cornerRadius = 66
        magnifier.masksToBounds = true
        magnifier.borderWidth = 3
        magnifier.borderColor = NSColor.white.cgColor
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

    /// Doce puntos alrededor del cursor, ampliados, para acertar al píxel.
    private func refreshMagnifier() {
        guard frozenImage != nil, let mousePoint,
              let piece = crop(CGRect(x: mousePoint.x - 6, y: mousePoint.y - 6, width: 12, height: 12))
        else {
            magnifier.isHidden = true
            return
        }
        magnifier.contents = piece
        let side = magnifier.bounds.width
        let x = mousePoint.x + 28 + side > bounds.maxX ? mousePoint.x - 28 - side / 2 : mousePoint.x + 28 + side / 2
        let y = mousePoint.y + 28 + side > bounds.maxY ? mousePoint.y - 28 - side / 2 : mousePoint.y + 28 + side / 2
        magnifier.position = CGPoint(x: x, y: y)
        magnifier.isHidden = false
    }

    private func buildPill() {
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = .labelColor
        sizePill.addSubview(sizeLabel)
        sizePill.isHidden = true
        addSubview(sizePill)
    }

    /// Barra de modos: lo demás no se muestra hasta que hace falta.
    private func buildHUD() {
        let entries: [(SelectionMode, String, String)] = [
            (.screenshot, "viewfinder", "Capturar área o ventana"),
            (.text, "text.viewfinder", "Copiar texto"),
            (.timed, "timer", "Capturar en 3 segundos"),
            (.scroll, "arrow.up.and.down", "Capturar con desplazamiento"),
            (.recording, "record.circle", "Grabar video"),
        ]
        let hint = NSTextField(labelWithString: "Esc para salir")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.sizeToFit()

        let padding: CGFloat = 6
        let width = padding + CGFloat(entries.count + 2) * (Design.actionSize + 2) + 10 + hint.frame.width + 14
        let height = Design.actionSize + padding * 2
        let glass = GlassView(frame: CGRect(x: 0, y: 0, width: width, height: height), radius: 14)

        var x = padding
        for (mode, symbol, tooltip) in entries {
            let button = GlassButton(symbol: symbol, tooltip: tooltip, target: self, action: #selector(modePressed(_:)))
            button.frame.origin = CGPoint(x: x, y: padding)
            glass.addSubview(button)
            modeButtons.append((mode, button))
            x += Design.actionSize + 2
        }
        let full = GlassButton(symbol: "macwindow", tooltip: "Capturar toda la pantalla", target: self, action: #selector(fullScreenPressed))
        full.frame.origin = CGPoint(x: x, y: padding)
        glass.addSubview(full)
        x += Design.actionSize + 2
        let still = GlassButton(symbol: "pause.circle", tooltip: "Congelar la pantalla (F)", target: self, action: #selector(freezePressed))
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
            button.activeColor = mode == .recording ? .systemRed : .controlAccentColor
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
            owner?.freeze()
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
            handles.forEach { $0.isHidden = true }
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

        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        for (handle, corner) in zip(handles, corners) {
            handle.isHidden = !dragging
            handle.position = corner
        }

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

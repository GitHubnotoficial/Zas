import AppKit
import Carbon

enum SelectionMode {
    case screenshot
    case recording
    case text
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

    static func fullScreen(_ screen: NSScreen) -> Selection {
        Selection(screen: screen, rect: CGRect(origin: .zero, size: screen.frame.size))
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

    var isActive: Bool { completion != nil }

    func begin(mode: SelectionMode, completion: @escaping @MainActor (Selection?) -> Void) {
        guard !isActive else { return }
        self.completion = completion

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
                mode: mode,
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
    #endif
}

private final class OverlayView: NSView {
    private let mode: SelectionMode
    private let screen: NSScreen
    private let windows: [WindowTarget]
    private weak var owner: SelectionOverlay?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var mousePoint: NSPoint?
    private var hoveredWindow: WindowTarget?
    private var trackingArea: NSTrackingArea?

    init(frame: CGRect, mode: SelectionMode, screen: NSScreen, windows: [WindowTarget], owner: SelectionOverlay) {
        self.mode = mode
        self.screen = screen
        self.windows = windows
        self.owner = owner
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        mousePoint = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    private func updateHover(at point: NSPoint) {
        mousePoint = point
        let origin = screen.globalTopLeftOrigin
        let global = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        hoveredWindow = windows.first { $0.frame.contains(global) }
        needsDisplay = true
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
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = clampedPoint(for: event)
        mousePoint = currentPoint
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = clampedPoint(for: event)
        let rect = selectionRect
        startPoint = nil
        currentPoint = nil

        let selection: Selection
        if let rect, rect.width >= 4, rect.height >= 4 {
            selection = Selection(screen: screen, rect: rect.integral)
        } else if let hoveredWindow, let hoveredRect {
            selection = Selection(screen: screen, rect: hoveredRect.integral, windowID: hoveredWindow.id)
        } else {
            // Clic en el escritorio: toda la pantalla.
            selection = .fullScreen(screen)
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

    private var accent: NSColor {
        mode == .recording ? .systemRed : .white
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill(using: .copy)

        if let rect = selectionRect, rect.width > 0, rect.height > 0 {
            drawCutout(rect, lineWidth: 1)
            drawSizeLabel(for: rect)
            return
        }

        if let rect = hoveredRect {
            drawCutout(rect, lineWidth: 2)
            drawSizeLabel(for: rect)
        }
        drawCrosshair()
        drawHint()
    }

    private func drawCutout(_ rect: CGRect, lineWidth: CGFloat) {
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        accent.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        border.lineWidth = lineWidth
        border.stroke()
    }

    private func drawCrosshair() {
        guard let mousePoint else { return }
        let x = mousePoint.x.rounded() + 0.5
        let y = mousePoint.y.rounded() + 0.5

        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: x, y: bounds.minY))
        path.line(to: NSPoint(x: x, y: bounds.maxY))
        path.move(to: NSPoint(x: bounds.minX, y: y))
        path.line(to: NSPoint(x: bounds.maxX, y: y))
        NSColor.white.withAlphaComponent(0.45).setStroke()
        path.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        let scale = screen.backingScaleFactor
        let label = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let size = pillSize(for: label)

        var y = rect.maxY + 8
        if y + size.height > bounds.maxY - 8 {
            y = rect.maxY - size.height - 8
        }
        let x = max(8, min(rect.minX, bounds.maxX - size.width - 8))
        drawPill(label, at: NSPoint(x: x, y: y))
    }

    private func drawHint() {
        let hint: String
        switch mode {
        case .screenshot:
            hint = "Arrastra para elegir un área  ·  Clic para una ventana  ·  Esc para cancelar"
        case .recording:
            hint = "Arrastra para grabar un área  ·  Clic para una ventana  ·  Esc para cancelar"
        case .text:
            hint = "Arrastra sobre el texto que quieres copiar  ·  Esc para cancelar"
        }
        let size = pillSize(for: hint)
        drawPill(hint, at: NSPoint(x: bounds.midX - size.width / 2, y: 56))
    }

    private var pillAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    }

    private func pillSize(for text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: pillAttributes)
        return CGSize(width: size.width + 20, height: size.height + 10)
    }

    private func drawPill(_ text: String, at origin: NSPoint) {
        let rect = CGRect(origin: origin, size: pillSize(for: text))
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        (text as NSString).draw(
            at: NSPoint(x: origin.x + 10, y: origin.y + 5),
            withAttributes: pillAttributes
        )
    }

    #if ZAS_TEST
    func simulateDrag(from start: CGPoint, to end: CGPoint) {
        startPoint = start
        currentPoint = end
        needsDisplay = true
    }

    func simulateHover(at point: CGPoint) {
        startPoint = nil
        currentPoint = nil
        updateHover(at: point)
    }
    #endif
}

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
}

/// Área elegida. `rect` está en puntos, relativo a la pantalla, con origen arriba a la izquierda.
@MainActor
struct Selection {
    let screen: NSScreen
    let rect: CGRect

    static func fullScreen(_ screen: NSScreen) -> Selection {
        Selection(screen: screen, rect: CGRect(origin: .zero, size: screen.frame.size))
    }

    var isFullScreen: Bool {
        rect.size == screen.frame.size
    }

    /// Coordenadas globales (origen arriba a la izquierda de la pantalla principal),
    /// que es lo que espera `screencapture -R`.
    var globalTopLeftRect: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(
            x: screen.frame.minX + rect.minX,
            y: primaryHeight - screen.frame.maxY + rect.minY,
            width: rect.width,
            height: rect.height
        )
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
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Oscurece todas las pantallas y deja elegir un área arrastrando.
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
        escapeHotKey = HotKeys.shared.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in
            self?.finish(nil)
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
}

private final class OverlayView: NSView {
    private let mode: SelectionMode
    private let screen: NSScreen
    private weak var owner: SelectionOverlay?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var trackingArea: NSTrackingArea?

    init(frame: CGRect, mode: SelectionMode, screen: NSScreen, owner: SelectionOverlay) {
        self.mode = mode
        self.screen = screen
        self.owner = owner
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate],
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
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(for: event)
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = clampedPoint(for: event)
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
        } else if mode == .recording {
            // En video, un clic sin arrastrar graba la pantalla completa.
            selection = .fullScreen(screen)
        } else {
            needsDisplay = true
            return
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill(using: .copy)

        guard let rect = selectionRect, rect.width > 0, rect.height > 0 else {
            drawHint()
            return
        }

        NSColor.clear.setFill()
        rect.fill(using: .copy)

        let accent: NSColor = mode == .recording ? .systemRed : .white
        accent.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        let scale = screen.backingScaleFactor
        let label = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let size = pillSize(for: label)
        var y = rect.maxY + 8
        if y + size.height > bounds.maxY {
            y = rect.maxY - size.height - 8
        }
        let x = min(rect.minX, bounds.maxX - size.width - 8)
        drawPill(label, at: NSPoint(x: x, y: y))
    }

    private func drawHint() {
        let hint: String
        switch mode {
        case .screenshot:
            hint = "Arrastra para capturar  ·  Esc para cancelar"
        case .recording:
            hint = "Arrastra para grabar un área  ·  Clic para toda la pantalla  ·  Esc para cancelar"
        case .text:
            hint = "Arrastra sobre el texto que quieres copiar  ·  Esc para cancelar"
        }
        let size = pillSize(for: hint)
        drawPill(hint, at: NSPoint(x: bounds.midX - size.width / 2, y: 64))
    }

    private var pillAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    }

    private func pillSize(for text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: pillAttributes)
        return CGSize(width: size.width + 16, height: size.height + 8)
    }

    private func drawPill(_ text: String, at origin: NSPoint) {
        let rect = CGRect(origin: origin, size: pillSize(for: text))
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(
            at: NSPoint(x: origin.x + 8, y: origin.y + 4),
            withAttributes: pillAttributes
        )
    }
}

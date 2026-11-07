@preconcurrency import AVFoundation
import AppKit
import ApplicationServices

/// Capa transparente que sí sale en el video: anillos de clic y teclas pulsadas.
/// El resto de ventanas de Zas se excluyen de la grabación.
@MainActor
final class RecordingEffects {
    private let panel: NSPanel
    private let surface: NSView
    private let screen: NSScreen
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var keyLayer: CALayer?
    private var keyTask: Task<Void, Never>?
    private var camera: CameraBubble?

    init(screen: NSScreen) {
        self.screen = screen
        panel = NSPanel(
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
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        surface = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        surface.wantsLayer = true
        panel.contentView = surface
    }

    /// Ventanas de Zas que deben aparecer en el video.
    var windowIDs: [CGWindowID] {
        [CGWindowID(panel.windowNumber)] + (camera.map { [$0.windowID] } ?? [])
    }

    func start(clicks: Bool, keys: Bool, showsCamera: Bool) async {
        panel.orderFrontRegardless()
        if clicks {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let location = NSEvent.mouseLocation
                MainActor.assumeIsolated {
                    self?.showClick(at: location)
                }
            }
        }
        if keys {
            startKeys()
        }
        if showsCamera {
            let bubble = CameraBubble()
            if await bubble.start(on: screen) {
                camera = bubble
            } else {
                Toast.shared.show("No se pudo abrir la cámara.")
            }
        }
    }

    func stop() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        mouseMonitor = nil
        keyMonitor = nil
        keyTask?.cancel()
        camera?.stop()
        camera = nil
        panel.orderOut(nil)
    }

    private func startKeys() {
        // Ver las teclas de otras apps exige el permiso de Accesibilidad.
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else {
            Toast.shared.show("Activa Zas en Accesibilidad para mostrar las teclas.")
            return
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let label = Self.label(for: event)
            MainActor.assumeIsolated {
                self?.showKeys(label)
            }
        }
    }

    nonisolated static func label(for event: NSEvent) -> String {
        var text = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        switch event.keyCode {
        case 36: return text + "↩"
        case 48: return text + "⇥"
        case 49: return text + "␣"
        case 51: return text + "⌫"
        case 53: return text + "⎋"
        default: return text + (event.charactersIgnoringModifiers?.uppercased() ?? "")
        }
    }

    func showClick(at location: CGPoint) {
        guard let root = surface.layer else { return }
        let point = CGPoint(x: location.x - screen.frame.minX, y: location.y - screen.frame.minY)
        let ring = CAShapeLayer()
        let radius: CGFloat = 26
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.position = point
        ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        ring.strokeColor = NSColor.systemYellow.cgColor
        ring.lineWidth = 3
        root.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.35
        scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Design.clickRingDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        ring.add(group, forKey: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            ring.removeFromSuperlayer()
        }
    }

    func showKeys(_ label: String) {
        guard let root = surface.layer, !label.isEmpty else { return }
        keyTask?.cancel()
        keyLayer?.removeFromSuperlayer()

        let text = CATextLayer()
        text.string = label
        text.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
        text.fontSize = 30
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        text.contentsScale = screen.backingScaleFactor
        let width = max(CGFloat(label.count) * 26 + 40, 76)
        let badge = CALayer()
        badge.frame = CGRect(x: surface.bounds.midX - width / 2, y: 90, width: width, height: 62)
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        badge.cornerRadius = 16
        badge.cornerCurve = .continuous
        text.frame = CGRect(x: 0, y: 12, width: width, height: 40)
        badge.addSublayer(text)
        root.addSublayer(badge)
        keyLayer = badge

        keyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            badge.removeFromSuperlayer()
            if self?.keyLayer === badge {
                self?.keyLayer = nil
            }
        }
    }
}

/// Burbuja redonda con la cámara. Se puede arrastrar mientras se graba.
@MainActor
final class CameraBubble {
    private let panel: NSPanel
    private let session = AVCaptureSession()

    init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 190, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    func start(on screen: NSScreen) async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video),
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return false }
        session.addInput(input)

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 190, height: 190))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = 95
        preview.masksToBounds = true
        view.layer?.addSublayer(preview)
        panel.contentView = view

        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.minX + Design.edgeMargin, y: visible.minY + Design.edgeMargin))
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        let running = session
        DispatchQueue.global(qos: .userInitiated).async {
            running.startRunning()
        }
        return true
    }

    func stop() {
        let running = session
        DispatchQueue.global(qos: .userInitiated).async {
            running.stopRunning()
        }
        panel.orderOut(nil)
    }
}

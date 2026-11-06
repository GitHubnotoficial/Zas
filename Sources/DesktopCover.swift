import AppKit
import ImageIO

/// Esconde los iconos del escritorio con una copia del fondo de pantalla, justo encima de ellos.
/// No toca los ajustes de Finder ni lo reinicia: al salir de Zas, todo queda como estaba.
/// Sale en las capturas a propósito: lo que se busca es un escritorio limpio en la imagen.
@MainActor
final class DesktopCover {
    private static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    private struct Decoded: @unchecked Sendable {
        let image: CGImage?
    }

    private var windows: [NSWindow] = []
    private var isOn = false
    /// Sube en cada recarga: una lectura lenta del fondo no debe pisar a una más nueva.
    private var generation = 0
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    /// Identificadores para el video, que por lo demás excluye las ventanas de Zas.
    var windowIDs: [CGWindowID] {
        windows.map { CGWindowID($0.windowNumber) }
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        generation += 1
        if on {
            listen()
            refresh()
        } else {
            stopListening()
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()
        }
    }

    /// Cambia si se conecta una pantalla, y cada Espacio puede tener su propio fondo.
    private func listen() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func stopListening() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }

    /// Las ventanas viejas siguen hasta tener las nuevas: así los iconos no parpadean.
    private func refresh() {
        generation += 1
        let current = generation
        Task { @MainActor in
            var fresh: [NSWindow] = []
            for screen in NSScreen.screens {
                let url = NSWorkspace.shared.desktopImageURL(for: screen)
                let longestSide = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
                let decoded = await Self.decode(url, longestSide: Int(longestSide))
                guard current == self.generation, self.isOn else { return }
                fresh.append(self.makeWindow(for: screen, image: decoded.image))
            }
            let previous = self.windows
            self.windows = fresh
            fresh.forEach { $0.orderFrontRegardless() }
            previous.forEach { $0.orderOut(nil) }
        }
    }

    private nonisolated static func decode(_ url: URL?, longestSide: Int) async -> Decoded {
        await Task.detached(priority: .userInitiated) { () -> Decoded in
            guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return Decoded(image: nil)
            }
            return Decoded(image: CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longestSide,
            ] as CFDictionary))
        }.value
    }

    /// Copia el modo de ajuste que tiene el fondo en Ajustes del Sistema.
    static func gravity(scaling: NSImageScaling, allowsClipping: Bool) -> CALayerContentsGravity {
        switch scaling {
        case .scaleAxesIndependently: return .resize
        case .scaleNone: return .center
        default: return allowsClipping ? .resizeAspectFill : .resizeAspect
        }
    }

    private func makeWindow(for screen: NSScreen, image: CGImage?) -> NSWindow {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
        let allowsClipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true

        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = Self.level
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.backgroundColor = options[.fillColor] as? NSColor ?? .black
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = Self.gravity(
            scaling: scaling ?? .scaleProportionallyUpOrDown,
            allowsClipping: allowsClipping
        )
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        return window
    }

    #if ZAS_TEST
    var testWindows: [NSWindow] { windows }
    #endif
}

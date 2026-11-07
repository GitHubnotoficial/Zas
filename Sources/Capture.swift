import AppKit
@preconcurrency import ScreenCaptureKit

/// Caja para pasar entre hilos algo que ya no va a cambiar.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Una captura lista para usar: leída, con su densidad corregida y con una copia pequeña
/// para la tarjeta. Se prepara fuera del hilo principal.
struct PreparedCapture: @unchecked Sendable {
    let data: Data
    let image: NSImage
    let preview: NSImage?
}

/// Genera el TIFF solo si la app que pega lo pide: convertirlo siempre retrasaría cada captura
/// y dejaría decenas de MB en el portapapeles. Casi todas las apps usan el PNG.
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: type)
        }
    }
}

/// Captura con la herramienta del sistema (`screencapture`) y maneja archivos y portapapeles.
@MainActor
enum Capture {
    private static var tiffProvider: TIFFProvider?

    /// Carpeta del historial. Si la elegida ya no sirve (un disco que se desconectó),
    /// se usa la de siempre: perder la captura sería peor que guardarla en otro sitio.
    static var folder: URL {
        let fileManager = FileManager.default
        let chosen = Settings.shared.saveFolder
        try? fileManager.createDirectory(at: chosen, withIntermediateDirectories: true)
        if fileManager.isWritableFile(atPath: chosen.path) {
            return chosen
        }
        let fallback = Settings.defaultFolder
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Archivos de paso: se borran al abrir y al cerrar Zas.
    static var scratchFolder: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Zas-capturas", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Dónde van las imágenes. Los videos siempre van a `folder`: tardan en hacerse
    /// y se copian como archivo, así que deben seguir ahí al pegarlos.
    static var imageFolder: URL {
        Settings.shared.saveCaptures ? folder : scratchFolder
    }

    static func clearScratch() {
        try? FileManager.default.removeItem(at: scratchFolder)
    }

    static func isScratch(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(scratchFolder.standardizedFileURL.path)
    }

    static func newFileURL(extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Zas \(formatter.string(from: Date()))"
        let destination = ext == "mp4" ? folder : imageFolder

        var url = destination.appendingPathComponent("\(base).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = destination.appendingPathComponent("\(base) \(suffix).\(ext)")
            suffix += 1
        }
        return url
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(suffix).\(ext)")
            suffix += 1
        }
        return url
    }

    /// Guarda una imagen ya compuesta con su tamaño real en puntos.
    nonisolated static func writePNG(_ image: CGImage, to url: URL, pointSize: CGSize) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Lo mismo, sin frenar la interfaz: codificar una pantalla 5K tarda casi un segundo.
    nonisolated static func writePNGInBackground(_ image: CGImage, to url: URL, pointSize: CGSize) async -> Bool {
        let box = Unchecked(value: image)
        return await Task.detached(priority: .userInitiated) {
            writePNG(box.value, to: url, pointSize: pointSize)
        }.value
    }

    nonisolated static func encodePNG(_ bitmap: NSBitmapImageRep) async -> Data? {
        let box = Unchecked(value: bitmap)
        return await Task.detached(priority: .userInitiated) {
            box.value.representation(using: .png, properties: [:])
        }.value
    }

    nonisolated static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Se decodifica ya: el archivo puede borrarse enseguida.
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Archivo para capturas que no van al historial.
    static func temporaryFileURL() -> URL {
        scratchFolder
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
    }

    static func regionArgument(_ rect: CGRect) -> String {
        let x = Int(rect.minX.rounded())
        let y = Int(rect.minY.rounded())
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        return "-R\(x),\(y),\(width),\(height)"
    }

    /// La pantalla sin las ventanas indicadas: congelar no necesita esconder la capa oscura.
    @available(macOS 14.0, *)
    static func screenImage(of screen: NSScreen, excluding windowIDs: [CGWindowID]) async -> CGImage? {
        guard let displayID = screen.displayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }
        let hidden = content.windows.filter { windowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: hidden)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Corre `screencapture` en segundo plano. Devuelve `false` si no quedó archivo.
    static func run(
        arguments: [String],
        to url: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments + [url.path]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("Zas: screencapture falló: %@", error.localizedDescription)
            }
            let succeeded = FileManager.default.fileExists(atPath: url.path)
            Task { @MainActor in
                completion(succeeded)
            }
        }
    }

    /// Lee el archivo. Con `pointSize`, corrige la densidad si no coincide:
    /// de lo contrario una captura Retina se vería al doble de su tamaño.
    private nonisolated static func readFixingDensity(at url: URL, pointSize: CGSize?) -> Data? {
        guard var data = try? Data(contentsOf: url) else { return nil }
        if let pointSize, let rep = NSBitmapImageRep(data: data),
           abs(rep.size.width - pointSize.width) > 0.5 || abs(rep.size.height - pointSize.height) > 0.5 {
            rep.size = pointSize
            if let fixed = rep.representation(using: .png, properties: [:]) {
                data = fixed
                try? data.write(to: url)
            }
        }
        return data
    }

    /// Copia reducida al doble del tamaño de la tarjeta: redibujar la captura entera en cada
    /// cuadro del resorte perdería cuadros. Una imagen muy alta se recorta, y pide más pixeles.
    private nonisolated static func cardPreview(of data: Data, size: CGSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let ratio = min(max(448 / max(size.width, 1), 336 / max(size.height, 1)), 1)
        let side = min(max(size.width, size.height) * ratio, 4096)
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(side, 1)),
        ] as CFDictionary) else { return nil }
        return NSImage(cgImage: preview, size: size)
    }

    /// Todo lo lento de terminar una captura, fuera del hilo principal.
    nonisolated static func prepare(at url: URL, pointSize: CGSize? = nil) async -> PreparedCapture? {
        await Task.detached(priority: .userInitiated) { () -> PreparedCapture? in
            guard let data = readFixingDensity(at: url, pointSize: pointSize),
                  let image = NSImage(data: data)
            else { return nil }
            return PreparedCapture(data: data, image: image, preview: cardPreview(of: data, size: image.size))
        }.value
    }

    /// Copia la imagen como PNG, y como TIFF para las apps que lo piden.
    static func copyImage(at url: URL, pointSize: CGSize? = nil) -> NSImage? {
        guard let data = readFixingDensity(at: url, pointSize: pointSize),
              let image = NSImage(data: data)
        else { return nil }
        publish(data)
        return image
    }

    /// Deja un PNG en el portapapeles.
    static func publish(_ data: Data) {
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        let provider = TIFFProvider(png: data)
        item.setDataProvider(provider, forTypes: [.tiff])
        tiffProvider = provider

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copia el archivo en sí (se usa para los videos).
    static func copyFile(at url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}

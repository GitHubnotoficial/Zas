import AppKit

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

    /// Copia la imagen como PNG, y como TIFF para las apps que lo piden.
    /// Con `pointSize`, corrige la densidad del archivo si no coincide:
    /// de lo contrario una captura Retina se vería al doble de su tamaño.
    static func copyImage(at url: URL, pointSize: CGSize? = nil) -> NSImage? {
        guard var data = try? Data(contentsOf: url) else { return nil }
        if let pointSize, let rep = NSBitmapImageRep(data: data),
           abs(rep.size.width - pointSize.width) > 0.5 || abs(rep.size.height - pointSize.height) > 0.5 {
            rep.size = pointSize
            if let fixed = rep.representation(using: .png, properties: [:]) {
                data = fixed
                try? data.write(to: url)
            }
        }
        guard let image = NSImage(data: data) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        let provider = TIFFProvider(png: data)
        item.setDataProvider(provider, forTypes: [.tiff])
        tiffProvider = provider

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return image
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

    static func playSound() {
        guard Settings.shared.playSound else { return }
        NSSound(named: NSSound.Name("Tink"))?.play()
    }
}

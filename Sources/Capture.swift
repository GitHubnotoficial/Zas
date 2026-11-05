import AppKit

/// Captura con la herramienta del sistema (`screencapture`) y maneja archivos y portapapeles.
enum Capture {
    /// Carpeta donde queda el historial: ~/Pictures/Zas
    static var folder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let url = pictures.appendingPathComponent("Zas", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newFileURL(extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return folder.appendingPathComponent("Zas \(formatter.string(from: Date())).\(ext)")
    }

    static func regionArgument(_ rect: CGRect) -> String {
        let x = Int(rect.minX.rounded())
        let y = Int(rect.minY.rounded())
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        return "-R\(x),\(y),\(width),\(height)"
    }

    /// Corre `screencapture` en segundo plano. Devuelve `false` si no quedó archivo
    /// (por ejemplo, si el usuario canceló la selección de ventana).
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

    /// Copia la imagen como PNG y TIFF para que se pueda pegar en cualquier app.
    static func copyImage(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
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

    /// Archivo temporal para capturas que no van al historial.
    static func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
    }

    /// Copia el archivo en sí (se usa para los videos).
    static func copyFile(at url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}

@preconcurrency import AVFoundation
import AppKit
import ImageIO

/// Las últimas capturas, para recuperar una aunque su tarjeta ya se haya cerrado.
@MainActor
enum Recents {
    static func files(limit: Int = 8) -> [URL] {
        let fileManager = FileManager.default
        var found: [(url: URL, date: Date)] = []
        for folder in Set([Capture.folder, Capture.scratchFolder]) {
            let names = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in names where ["png", "mp4"].contains(url.pathExtension.lowercased()) {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                found.append((url, date ?? .distantPast))
            }
        }
        return found
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.url)
    }

    static func title(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("Zas ") {
            name.removeFirst(4)
        }
        return name
    }

    private nonisolated static let previewSize = 400
    private nonisolated(unsafe) static let previews = NSCache<NSString, NSImage>()

    /// Imagen pequeña sin cargar el archivo completo en memoria. Un video usa un cuadro propio.
    nonisolated static func preview(of url: URL) -> NSImage? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(date?.timeIntervalSince1970 ?? 0)" as NSString
        if let saved = previews.object(forKey: key) {
            return saved
        }
        guard let image = url.pathExtension.lowercased() == "mp4" ? videoFrame(of: url) : imageFrame(of: url) else {
            return nil
        }
        let preview = NSImage(cgImage: image, size: .zero)
        previews.setObject(preview, forKey: key)
        return preview
    }

    /// Para que quinientas capturas no traben una ventana.
    nonisolated static func previewInBackground(of url: URL) async -> PreviewResult {
        await Task.detached(priority: .utility) { PreviewResult(image: preview(of: url)) }.value
    }

    private nonisolated static func imageFrame(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: previewSize,
        ] as CFDictionary)
    }

    private nonisolated static func videoFrame(of url: URL) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: previewSize, height: previewSize)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }
}

/// NSImage no es Sendable, pero esta imagen ya no cambia al cruzar de hilo.
struct PreviewResult: @unchecked Sendable {
    let image: NSImage?
}

/// Franja del menú con las cuatro capturas más recientes.
final class RecentsStripView: NSView {
    var onPick: ((URL) -> Void)?

    private final class Tile: NSButton {
        var file: URL?
    }

    private let label = NSTextField(labelWithString: "Recientes")
    private var tiles: [Tile] = []

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 280, height: 86))
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame.origin = CGPoint(x: 14, y: 66)
        label.sizeToFit()
        addSubview(label)

        let side: CGFloat = 14
        let gap: CGFloat = 6
        let width = (280 - side * 2 - gap * 3) / 4
        for index in 0..<4 {
            let tile = Tile(frame: CGRect(x: side + CGFloat(index) * (width + gap), y: 8, width: width, height: 52))
            tile.title = ""
            tile.isBordered = false
            tile.imagePosition = .imageOnly
            tile.imageScaling = .scaleProportionallyUpOrDown
            tile.target = self
            tile.action = #selector(tilePressed(_:))
            tile.setAccessibilityLabel("Captura reciente \(index + 1)")
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 7
            tile.layer?.cornerCurve = .continuous
            tile.layer?.masksToBounds = true
            tile.layer?.borderWidth = 0.5
            tile.layer?.borderColor = NSColor.separatorColor.cgColor
            addSubview(tile)
            tiles.append(tile)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func reload(_ files: [URL]) {
        label.stringValue = files.isEmpty ? "Aún no hay capturas" : "Recientes"
        label.sizeToFit()
        for (index, tile) in tiles.enumerated() {
            let file = index < files.count ? files[index] : nil
            tile.file = file
            tile.isHidden = file == nil
            tile.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            guard let file else { continue }
            tile.image = Recents.preview(of: file)
                ?? NSImage(systemSymbolName: "film", accessibilityDescription: "Video")
            tile.toolTip = Recents.title(for: file)
        }
    }

    @objc private func tilePressed(_ sender: Tile) {
        guard let file = sender.file else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onPick?(file)
    }
}

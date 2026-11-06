import AVFoundation
import AppKit

/// Convierte un video en una sola imagen con momentos clave y su minuto.
/// Claude no suele poder ver un video, pero sí lee esta imagen al pegarla.
enum VideoSheet {
    /// Claude reduce las imágenes con un lado mayor a este, y el texto dejaría de leerse.
    private static let maximumSide: CGFloat = 1568
    private static let margin: CGFloat = 10

    private static let perPage = 12
    private static let maximumMoments = 120

    /// Un momento cada `every` segundos, más el final del video.
    static func frameTimes(duration: Double, every: Double = 2) -> [Double] {
        guard duration > 0.1 else { return [0] }
        let last = max(duration - 0.1, 0)
        var times = Array(stride(from: 0, to: last, by: max(every, 0.5)))
        if last - (times.last ?? 0) > 0.4 || times.count < 2 {
            times.append(last)
        }
        guard times.count > maximumMoments else { return times }
        // En videos muy largos se reparte para no pasar del tope.
        return (0..<maximumMoments).map { last * Double($0) / Double(maximumMoments - 1) }
    }

    static func columns(for count: Int) -> Int {
        count <= 4 ? 2 : 3
    }

    static func timeLabel(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func outputName(for video: URL, page: Int = 1) -> String {
        let suffix = page > 1 ? " \(page)" : ""
        return "\(video.deletingPathExtension().lastPathComponent) resumen\(suffix).png"
    }

    /// Una hoja por cada doce momentos. Devuelve los archivos y cuántos momentos entraron.
    static func pages(from video: URL, folder: URL, every: Double) async -> (files: [URL], moments: Int) {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else {
            return ([], 0)
        }
        let times = frameTimes(duration: duration, every: every)
        var files: [URL] = []
        var moments = 0
        var start = 0
        while start < times.count {
            let slice = Array(times[start..<min(start + perPage, times.count)])
            let url = folder.appendingPathComponent(outputName(for: video, page: files.count + 1))
            let count = await sheet(asset: asset, times: slice, to: url)
            guard count > 0 else { break }
            files.append(url)
            moments += count
            start += perPage
        }
        return (files, moments)
    }

    /// Devuelve cuántos momentos quedaron en la imagen, o 0 si no se pudo crear.
    static func make(from video: URL, to output: URL) async -> Int {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else {
            return 0
        }
        let times = frameTimes(duration: duration)
        return await sheet(asset: asset, times: Array(times.prefix(perPage)), to: output)
    }

    private static func sheet(asset: AVURLAsset, times: [Double], to output: URL) async -> Int {
        let columnCount = columns(for: times.count)
        let cellWidth = ((maximumSide - margin * CGFloat(columnCount + 1)) / CGFloat(columnCount)).rounded(.down)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: cellWidth, height: cellWidth)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        var frames: [(image: CGImage, time: Double)] = []
        for time in times {
            let target = CMTime(seconds: time, preferredTimescale: 600)
            if let result = try? await generator.image(at: target) {
                frames.append((result.image, time))
            }
        }
        guard let data = compose(frames: frames), (try? data.write(to: output)) != nil else {
            return 0
        }
        return frames.count
    }

    private static func compose(frames: [(image: CGImage, time: Double)]) -> Data? {
        guard let first = frames.first?.image else { return nil }
        let columnCount = columns(for: frames.count)
        let rows = Int((Double(frames.count) / Double(columnCount)).rounded(.up))
        let cell = CGSize(width: first.width, height: first.height)
        let width = CGFloat(columnCount) * cell.width + CGFloat(columnCount + 1) * margin
        let height = CGFloat(rows) * cell.height + CGFloat(rows + 1) * margin

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width),
            pixelsHigh: Int(height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.12, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()

        for (index, frame) in frames.enumerated() {
            let column = index % columnCount
            let row = index / columnCount
            let rect = CGRect(
                x: margin + CGFloat(column) * (cell.width + margin),
                y: height - margin - cell.height - CGFloat(row) * (cell.height + margin),
                width: cell.width,
                height: cell.height
            )
            context.cgContext.draw(frame.image, in: rect)
            drawLabel(timeLabel(frame.time), in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    /// El minuto va en cada imagen para que Claude pueda decir cuándo pasó algo.
    private static func drawLabel(_ text: String, in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let background = CGRect(x: rect.minX + 8, y: rect.maxY - size.height - 16, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        string.draw(at: NSPoint(x: background.minX + 8, y: background.minY + 4), withAttributes: attributes)
    }
}

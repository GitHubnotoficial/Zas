import AppKit

/// Une tramos de una pantalla que se desplaza hacia abajo en una sola imagen larga.
/// Compara filas de píxeles para encontrar cuánto se movió el contenido entre dos tramos.
struct ScrollStitcher {
    private(set) var pieces: [CGImage] = []
    private var lastRows: [UInt64] = []
    private let maximumHeight = 30_000

    var height: Int { pieces.reduce(0) { $0 + $1.height } }
    var width: Int { pieces.first?.width ?? 0 }

    /// Devuelve `true` si entró contenido nuevo.
    @discardableResult
    mutating func add(_ image: CGImage) -> Bool {
        let rows = Self.rowHashes(image)
        guard !pieces.isEmpty else {
            pieces.append(image)
            lastRows = rows
            return true
        }
        guard image.width == width, height < maximumHeight,
              let shift = Self.shift(from: lastRows, to: rows), shift > 0,
              let slice = image.cropping(to: CGRect(x: 0, y: image.height - shift, width: image.width, height: shift))
        else { return false }
        pieces.append(slice)
        lastRows = rows
        return true
    }

    /// Cuántas filas subió el contenido. `nil` si los tramos no se parecen.
    static func shift(from previous: [UInt64], to next: [UInt64]) -> Int? {
        guard previous.count == next.count, previous.count > 16 else { return nil }
        if previous == next { return 0 }
        let count = previous.count
        var best: (shift: Int, score: Double)?
        for shift in 1..<(count - 8) {
            let overlap = count - shift
            var matches = 0
            for row in 0..<overlap where previous[row + shift] == next[row] {
                matches += 1
            }
            let score = Double(matches) / Double(overlap)
            if score >= 0.9, score > (best?.score ?? 0) {
                best = (shift, score)
            }
        }
        return best?.shift
    }

    static func rowHashes(_ image: CGImage) -> [UInt64] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { row in
            var hash: UInt64 = 14_695_981_039_346_656_037
            var column = 0
            while column < bytesPerRow {
                let index = row * bytesPerRow + column
                hash = (hash ^ UInt64(pixels[index])) &* 1_099_511_628_211
                hash = (hash ^ UInt64(pixels[index + 1])) &* 1_099_511_628_211
                hash = (hash ^ UInt64(pixels[index + 2])) &* 1_099_511_628_211
                column += 16
            }
            return hash
        }
    }

    func composed() -> CGImage? {
        guard !pieces.isEmpty else { return nil }
        let total = height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var top = total
        for piece in pieces {
            top -= piece.height
            context.draw(piece, in: CGRect(x: 0, y: top, width: piece.width, height: piece.height))
        }
        return context.makeImage()
    }
}

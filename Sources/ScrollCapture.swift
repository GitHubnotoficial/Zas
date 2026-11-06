import AppKit

/// Une tramos de una pantalla que se desplaza hacia abajo en una sola imagen larga.
/// Compara filas de píxeles para encontrar cuánto se movió el contenido entre dos tramos.
struct ScrollStitcher {
    private(set) var pieces: [CGImage] = []
    private var lastRows: [UInt64] = []
    private let maximumHeight = 30_000
    /// Filas fijas abajo, como una barra o un cuadro de texto: se añaden una sola vez al final.
    private var footerRows = 0
    private var lastImage: CGImage?
    /// El contenido saltó más que un tramo completo: hay que volver un poco atrás.
    private(set) var lostTrack = false

    var height: Int { pieces.reduce(0) { $0 + $1.height } }
    var width: Int { pieces.first?.width ?? 0 }

    /// Devuelve `true` si entró contenido nuevo.
    @discardableResult
    mutating func add(_ image: CGImage) -> Bool {
        let rows = Self.rowHashes(image)
        guard !pieces.isEmpty else {
            pieces.append(image)
            lastRows = rows
            lastImage = image
            return true
        }
        guard image.width == width, height < maximumHeight, rows.count == lastRows.count else { return false }
        if rows == lastRows { return false }

        let (top, bottom) = Self.staticBands(lastRows, rows)
        let previous = Array(lastRows[top..<(rows.count - bottom)])
        let next = Array(rows[top..<(rows.count - bottom)])
        guard let shift = Self.shift(from: previous, to: next), shift > 0 else {
            lostTrack = true
            return false
        }
        let cut = CGRect(x: 0, y: rows.count - bottom - shift, width: image.width, height: shift)
        guard let slice = Self.copy(image, cut) else { return false }
        lostTrack = false
        footerRows = bottom
        pieces.append(slice)
        lastRows = rows
        lastImage = image
        return true
    }

    /// Filas iguales arriba y abajo en dos tramos: no se mueven al desplazar.
    static func staticBands(_ a: [UInt64], _ b: [UInt64]) -> (top: Int, bottom: Int) {
        let limit = a.count / 2
        var top = 0
        while top < limit, a[top] == b[top] { top += 1 }
        var bottom = 0
        while bottom < limit, a[a.count - 1 - bottom] == b[b.count - 1 - bottom] { bottom += 1 }
        return (top, bottom)
    }

    /// Copia independiente: un recorte normal retiene en memoria el tramo entero.
    private static func copy(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        guard let crop = image.cropping(to: rect) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context?.makeImage()
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
        guard let first = pieces.first else { return nil }
        // El pie del primer tramo se quita: va una sola vez, al final de todo.
        var parts = pieces
        if footerRows > 0, pieces.count > 1,
           let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - footerRows)) {
            parts[0] = trimmed
            if let last = lastImage,
               let footer = last.cropping(to: CGRect(x: 0, y: last.height - footerRows, width: last.width, height: footerRows)) {
                parts.append(footer)
            }
        }
        let total = parts.reduce(0) { $0 + $1.height }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var top = total
        for piece in parts {
            top -= piece.height
            context.draw(piece, in: CGRect(x: 0, y: top, width: piece.width, height: piece.height))
        }
        return context.makeImage()
    }
}

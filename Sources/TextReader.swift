import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Lo que se encontró en una imagen: su texto y, si hay, el contenido de sus códigos QR.
struct TextScan: Sendable {
    let text: String
    let code: String?

    /// Un código QR manda sobre el texto que lo rodea: es lo que se quería leer.
    var clipboardText: String { code ?? text }
}

/// Un trozo de texto y su caja, de 0 a 1 con origen abajo a la izquierda, como los entrega Vision.
struct TextPiece: Equatable {
    let text: String
    let box: CGRect
}

/// Pone en orden lo que entrega Vision. No reordena columnas: solo arregla lo que se puede saber
/// con certeza, que es una línea antes que la de arriba y una fila partida en trozos.
enum TextLayout {
    static func ordered(_ pieces: [TextPiece]) -> String {
        var sorted: [TextPiece] = []
        for piece in pieces {
            var index = sorted.count
            while index > 0, isAbove(piece, sorted[index - 1]) {
                index -= 1
            }
            sorted.insert(piece, at: index)
        }

        var rows: [[TextPiece]] = []
        for piece in sorted {
            if let last = rows.last?.last, isSameRow(last, piece) {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows
            .map { row in
                row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    /// `first` está en la misma columna que `second` y claramente por encima.
    private static func isAbove(_ first: TextPiece, _ second: TextPiece) -> Bool {
        let shared = min(first.box.maxX, second.box.maxX) - max(first.box.minX, second.box.minX)
        return shared > min(first.box.width, second.box.width) * 0.3 && first.box.minY >= second.box.midY
    }

    private static func isSameRow(_ first: TextPiece, _ second: TextPiece) -> Bool {
        let shared = min(first.box.maxY, second.box.maxY) - max(first.box.minY, second.box.minY)
        return shared > min(first.box.height, second.box.height) * 0.6
    }
}

/// Reconoce texto y códigos QR dentro de una imagen. Todo ocurre en el Mac, sin enviar nada a internet.
enum TextReader {
    /// Los mismos idiomas para copiar y para seleccionar sobre la imagen.
    static let languages = ["es-ES", "en-US"]

    /// Hasta este lado largo la imagen se duplica: Vision pierde letras con el texto de una pantalla 1x.
    private static let doublingLimit = 2_600
    /// Una tira de una sola línea, como un menú, necesita al menos este alto.
    private static let shortestSide = 120
    private static let largestSide = 6_000
    private static let maximumFactor = 4
    /// Aire alrededor, en pixeles de la imagen original: una letra pegada al borde se pierde.
    private static let margin = 12

    static func read(image: CGImage, completion: @escaping @MainActor (String) -> Void) {
        scan(image: image) { completion($0.text) }
    }

    static func scan(image: CGImage, completion: @escaping @MainActor (TextScan) -> Void) {
        let box = Unchecked(value: image)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = recognize(box.value)
            Task { @MainActor in
                completion(result)
            }
        }
    }

    static func scan(from url: URL, completion: @escaping @MainActor (TextScan) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = load(url).map(recognize) ?? TextScan(text: "", code: nil)
            Task { @MainActor in
                completion(result)
            }
        }
    }

    private static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Bloquea hasta terminar: llámala fuera del hilo principal.
    static func recognize(_ image: CGImage) -> TextScan {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = languages

        let codeRequest = VNDetectBarcodesRequest()
        codeRequest.symbologies = [.qr]

        // Por separado: si falla la lectura de códigos, el texto debe llegar igual.
        // El código se busca en la imagen tal cual: ampliarla le suaviza los bordes.
        try? VNImageRequestHandler(cgImage: prepared(image), options: [:]).perform([textRequest])
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([codeRequest])

        let pieces = (textRequest.results ?? []).compactMap { observation -> TextPiece? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return TextPiece(text: text, box: observation.boundingBox)
        }
        var codes: [String] = []
        for observation in codeRequest.results ?? [] {
            if let payload = observation.payloadStringValue, !payload.isEmpty, !codes.contains(payload) {
                codes.append(payload)
            }
        }
        return TextScan(
            text: TextLayout.ordered(pieces),
            code: codes.isEmpty ? nil : codes.joined(separator: "\n")
        )
    }

    /// Cuánto hay que ampliar una imagen de este tamaño antes de leerla.
    static func enlargement(width: Int, height: Int) -> Int {
        let long = max(width, height)
        let short = max(min(width, height), 1)
        guard long > 0 else { return 1 }
        var factor = long <= doublingLimit ? 2 : 1
        if short * factor < shortestSide {
            factor = (shortestSide + short - 1) / short
        }
        return max(min(factor, maximumFactor, largestSide / long), 1)
    }

    /// Amplía sin cambiar la forma: las posiciones relativas siguen siendo las de la imagen original.
    static func enlarged(_ image: CGImage) -> CGImage {
        let factor = enlargement(width: image.width, height: image.height)
        guard factor > 1,
              let context = canvas(width: image.width * factor, height: image.height * factor)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage() ?? image
    }

    /// Lo que recibe Vision: la imagen ampliada y con aire del color de su borde.
    static func prepared(_ image: CGImage) -> CGImage {
        let large = enlarged(image)
        let factor = max(large.width / max(image.width, 1), 1)
        let room = margin * factor
        guard let context = canvas(width: large.width + room * 2, height: large.height + room * 2) else {
            return large
        }
        if let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) {
            context.draw(corner, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
        context.draw(large, in: CGRect(x: room, y: room, width: large.width, height: large.height))
        return context.makeImage() ?? large
    }

    private static func canvas(width: Int, height: Int) -> CGContext? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.interpolationQuality = .high
        return context
    }
}

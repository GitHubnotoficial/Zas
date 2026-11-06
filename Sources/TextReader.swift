import Foundation
import Vision

/// Lo que se encontró en una imagen: su texto y, si hay, el contenido de sus códigos QR.
struct TextScan: Sendable {
    let text: String
    let code: String?
}

/// Reconoce texto y códigos QR dentro de una imagen. Todo ocurre en el Mac, sin enviar nada a internet.
enum TextReader {
    static func read(from url: URL, completion: @escaping @MainActor (String) -> Void) {
        scan(from: url) { completion($0.text) }
    }

    static func scan(from url: URL, completion: @escaping @MainActor (TextScan) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.recognitionLanguages = ["es-ES", "en-US"]

            let codeRequest = VNDetectBarcodesRequest()
            codeRequest.symbologies = [.qr]

            // Por separado: si falla la lectura de códigos, el texto debe llegar igual.
            let handler = VNImageRequestHandler(url: url, options: [:])
            try? handler.perform([textRequest])
            try? handler.perform([codeRequest])

            let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            var codes: [String] = []
            for observation in codeRequest.results ?? [] {
                if let payload = observation.payloadStringValue, !payload.isEmpty, !codes.contains(payload) {
                    codes.append(payload)
                }
            }
            let result = TextScan(
                text: lines.joined(separator: "\n"),
                code: codes.isEmpty ? nil : codes.joined(separator: "\n")
            )
            Task { @MainActor in
                completion(result)
            }
        }
    }
}

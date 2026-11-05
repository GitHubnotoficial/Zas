import Foundation
import Vision

/// Reconoce texto dentro de una imagen. Todo ocurre en el Mac, sin enviar nada a internet.
enum TextReader {
    static func read(from url: URL, completion: @escaping @MainActor (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["es-ES", "en-US"]

            let handler = VNImageRequestHandler(url: url, options: [:])
            try? handler.perform([request])

            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            Task { @MainActor in
                completion(text)
            }
        }
    }
}

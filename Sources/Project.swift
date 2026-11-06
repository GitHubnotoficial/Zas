import AppKit
import UniformTypeIdentifiers

/// Proyecto editable `.zas`: la imagen y cada marca por separado, para retocarlas otro día.
struct ZasProject: Codable {
    static let fileType = UTType(exportedAs: "local.zas.project", conformingTo: .json)

    struct Mark: Codable {
        var tool: Int
        var color: [CGFloat]
        var lineWidth: CGFloat
        var points: [CGPoint]
        var text: String
        var number: Int
        var pixelBrush: Bool
        var blockSize: CGFloat
        var filled: Bool
        var plainLine: Bool
        var smoothBlur: Bool
        var picture: Data?
    }

    var version = 1
    var image: Data
    var width: CGFloat
    var height: CGFloat
    var crop: CGRect?
    var marks: [Mark]
    /// Fondo no destructivo. Los proyectos anteriores no lo tienen.
    var backdrop: Backdrop?

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    init?(image: NSImage, document: AnnotationDocument) {
        guard let data = Self.png(image) else { return nil }
        self.image = data
        width = image.size.width
        height = image.size.height
        crop = document.crop
        backdrop = document.backdrop
        marks = document.annotations.map { mark in
            let color = mark.color.usingColorSpace(.sRGB) ?? .black
            return Mark(
                tool: mark.tool.rawValue,
                color: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent],
                lineWidth: mark.lineWidth,
                points: mark.points,
                text: mark.text,
                number: mark.number,
                pixelBrush: mark.pixelBrush,
                blockSize: mark.blockSize,
                filled: mark.filled,
                plainLine: mark.plainLine,
                smoothBlur: mark.smoothBlur,
                picture: mark.picture.flatMap(Self.png)
            )
        }
    }

    func baseImage() -> NSImage? {
        guard let result = NSImage(data: image) else { return nil }
        result.size = CGSize(width: width, height: height)
        return result
    }

    func document() -> AnnotationDocument {
        var document = AnnotationDocument()
        document.crop = crop
        document.backdrop = backdrop
        document.annotations = marks.compactMap { mark in
            guard let tool = AnnotationTool(rawValue: mark.tool), mark.color.count == 4 else { return nil }
            return Annotation(
                tool: tool,
                color: NSColor(srgbRed: mark.color[0], green: mark.color[1], blue: mark.color[2], alpha: mark.color[3]),
                lineWidth: mark.lineWidth,
                points: mark.points,
                text: mark.text,
                number: mark.number,
                pixelBrush: mark.pixelBrush,
                blockSize: mark.blockSize,
                filled: mark.filled,
                plainLine: mark.plainLine,
                smoothBlur: mark.smoothBlur,
                picture: mark.picture.flatMap { NSImage(data: $0) }
            )
        }
        return document
    }
}

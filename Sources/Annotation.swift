import AppKit
import CoreImage

enum AnnotationTool: Int, CaseIterable {
    case select, arrow, rectangle, ellipse, highlight, pencil, text, counter, pixelate, crop, eraser

    var label: String {
        switch self {
        case .select: return "Mover"
        case .arrow: return "Flecha"
        case .rectangle: return "Cuadro"
        case .ellipse: return "Círculo"
        case .highlight: return "Resaltar"
        case .pencil: return "Lápiz"
        case .text: return "Texto"
        case .counter: return "Número"
        case .pixelate: return "Pixelar"
        case .crop: return "Recortar"
        case .eraser: return "Borrador"
        }
    }

    var key: String {
        switch self {
        case .select: return "V"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .highlight: return "H"
        case .pencil: return "P"
        case .text: return "T"
        case .counter: return "N"
        case .pixelate: return "X"
        case .crop: return "C"
        case .eraser: return "E"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .eraser: return "eraser"
        case .pencil: return "scribble"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "square.grid.3x3.square"
        case .crop: return "crop"
        }
    }
}

/// Una marca sobre la imagen. Los puntos están en coordenadas de la imagen.
struct Annotation {
    var tool: AnnotationTool
    var color: NSColor
    var lineWidth: CGFloat
    var points: [CGPoint]
    var text: String = ""
    var number: Int = 0

    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
    }

    /// Las figuras y el texto se dimensionan a partir del grosor elegido.
    var fontSize: CGFloat { 12 + lineWidth * 2.4 }
    var counterRadius: CGFloat { 12 + lineWidth * 1.2 }

    var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color,
            // Borde blanco para que se lea sobre cualquier fondo.
            .strokeColor: NSColor.white,
            .strokeWidth: -3,
        ]
    }

    /// Caja para seleccionar la marca con el cursor.
    var bounds: CGRect {
        switch tool {
        case .text:
            let size = (text as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: points.first ?? .zero, size: size)
        case .counter:
            let center = points.first ?? .zero
            return CGRect(
                x: center.x - counterRadius,
                y: center.y - counterRadius,
                width: counterRadius * 2,
                height: counterRadius * 2
            )
        case .pencil, .highlight, .eraser:
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
                return .zero
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        default:
            return rect
        }
    }

    func hitTest(_ point: CGPoint) -> Bool {
        let slack = max(lineWidth, 6)
        guard bounds.insetBy(dx: -slack, dy: -slack).contains(point) else { return false }

        switch tool {
        case .arrow:
            guard points.count > 1 else { return false }
            return Annotation.distance(from: point, toSegment: points[0], points[1]) <= slack + lineWidth
        case .rectangle, .ellipse:
            // Hueco por dentro: se puede tocar lo que hay debajo.
            let inner = rect.insetBy(dx: slack + lineWidth, dy: slack + lineWidth)
            return inner.isEmpty || !inner.contains(point)
        case .eraser:
            return false
        case .pencil, .highlight:
            guard points.count > 1 else { return false }
            for index in 1..<points.count
            where Annotation.distance(from: point, toSegment: points[index - 1], points[index]) <= slack + lineWidth {
                return true
            }
            return false
        default:
            return true
        }
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}

/// Todo lo que se puede deshacer en el editor.
struct AnnotationDocument: Equatable {
    var annotations: [Annotation] = []
    var crop: CGRect?

    static func == (lhs: AnnotationDocument, rhs: AnnotationDocument) -> Bool {
        lhs.crop == rhs.crop && lhs.annotations.count == rhs.annotations.count
            && zip(lhs.annotations, rhs.annotations).allSatisfy {
                $0.points == $1.points && $0.color == $1.color && $0.lineWidth == $1.lineWidth
            }
    }

    var nextCounter: Int {
        (annotations.map(\.number).max() ?? 0) + 1
    }
}

/// Dibuja las marcas en coordenadas de la imagen. Se usa en pantalla y al exportar.
@MainActor
enum AnnotationRenderer {
    static func draw(_ annotation: Annotation, pixelated: NSImage?, imageSize: CGSize) {
        switch annotation.tool {
        case .select, .crop:
            break
        case .arrow:
            drawArrow(annotation)
        case .rectangle:
            annotation.color.setStroke()
            let path = NSBezierPath(roundedRect: annotation.rect, xRadius: 3, yRadius: 3)
            path.lineWidth = annotation.lineWidth
            path.stroke()
        case .ellipse:
            annotation.color.setStroke()
            let path = NSBezierPath(ovalIn: annotation.rect)
            path.lineWidth = annotation.lineWidth
            path.stroke()
        case .highlight:
            // Se traza entero de una vez: así los cruces no quedan más oscuros, como con un marcador.
            annotation.color.withAlphaComponent(0.42).setStroke()
            let marker = strokePath(annotation)
            marker.lineCapStyle = .butt
            marker.stroke()
        case .eraser:
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSColor.black.setStroke()
            strokePath(annotation).stroke()
            NSGraphicsContext.restoreGraphicsState()
        case .pencil:
            drawPencil(annotation)
        case .text:
            let point = annotation.points.first ?? .zero
            (annotation.text as NSString).draw(at: point, withAttributes: annotation.textAttributes)
        case .counter:
            drawCounter(annotation)
        case .pixelate:
            guard let pixelated else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: annotation.rect).addClip()
            pixelated.draw(in: CGRect(origin: .zero, size: imageSize))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawArrow(_ annotation: Annotation) {
        guard annotation.points.count > 1 else { return }
        let start = annotation.points[0]
        let end = annotation.points[1]
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = hypot(end.x - start.x, end.y - start.y)
        let headLength = min(12 + annotation.lineWidth * 3, length * 0.7)
        let headAngle: CGFloat = 0.46

        annotation.color.set()

        let line = NSBezierPath()
        line.lineWidth = annotation.lineWidth
        line.lineCapStyle = .round
        line.move(to: start)
        line.line(to: CGPoint(
            x: end.x - cos(angle) * headLength * 0.8,
            y: end.y - sin(angle) * headLength * 0.8
        ))
        line.stroke()

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(
            x: end.x - cos(angle - headAngle) * headLength,
            y: end.y - sin(angle - headAngle) * headLength
        ))
        head.line(to: CGPoint(
            x: end.x - cos(angle + headAngle) * headLength,
            y: end.y - sin(angle + headAngle) * headLength
        ))
        head.close()
        head.lineJoinStyle = .round
        head.lineWidth = 1
        head.fill()
        head.stroke()
    }

    private static func strokePath(_ annotation: Annotation) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = annotation.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = annotation.points.first else { return path }
        path.move(to: first)
        for point in annotation.points.dropFirst() {
            path.line(to: point)
        }
        return path
    }

    private static func drawPencil(_ annotation: Annotation) {
        guard let first = annotation.points.first else { return }
        annotation.color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = annotation.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for point in annotation.points.dropFirst() {
            path.line(to: point)
        }
        path.stroke()
    }

    private static func drawCounter(_ annotation: Annotation) {
        let circle = annotation.bounds
        annotation.color.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = 2
        ring.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: annotation.counterRadius * 1.05, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let label = "\(annotation.number)" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    /// Versión de toda la imagen en bloques, de la que se recorta cada zona pixelada.
    static func makePixelated(_ image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let source = CIImage(cgImage: cgImage)
        let blockSize = max(CGFloat(cgImage.width) / max(image.size.width, 1), 1) * 12
        guard let filter = CIFilter(
            name: "CIPixellate",
            parameters: [kCIInputImageKey: source, kCIInputScaleKey: blockSize]
        ),
            let output = filter.outputImage?.cropped(to: source.extent),
            let result = CIContext().createCGImage(output, from: source.extent)
        else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }
}

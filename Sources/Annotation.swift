import AppKit
import CoreImage

enum AnnotationTool: Int, CaseIterable {
    case select, arrow, rectangle, ellipse, highlight, pencil, text, counter, pixelate, crop, eraser, spotlight, picture

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
        case .spotlight: return "Foco"
        case .picture: return "Imagen"
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
        case .spotlight: return "F"
        case .picture: return ""
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
        case .spotlight: return "scope"
        case .picture: return "photo"
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
    /// Censurar con pincel en vez de con un recuadro.
    var pixelBrush = false
    /// Tamaño de los bloques al censurar: más grande, más ilegible.
    var blockSize: CGFloat = 14
    /// Rectángulo relleno en vez de contorno.
    var filled = false
    /// Línea sin punta en vez de flecha.
    var plainLine = false
    /// Desenfoque suave en vez de bloques.
    var smoothBlur = false
    /// Imagen añadida encima de la captura.
    var picture: NSImage?

    /// Se dibuja siguiendo el cursor, no entre dos puntos.
    var isFreehand: Bool {
        tool == .pencil || tool == .highlight || tool == .eraser || (tool == .pixelate && pixelBrush)
    }

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
            .font: Annotation.markFont(ofSize: fontSize),
            .foregroundColor: color,
        ]
    }

    /// Letra de las marcas: negrita redondeada.
    static func markFont(ofSize size: CGFloat) -> NSFont {
        let bold = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let rounded = bold.fontDescriptor.withDesign(.rounded) else { return bold }
        return NSFont(descriptor: rounded, size: size) ?? bold
    }

    /// Punto de control de la flecha. Las largas se arquean un poco, siempre hacia su izquierda,
    /// y el arco sale de los dos extremos: no hay nada que guardar y sirve igual para marcas antiguas.
    var arrowControl: CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let start = points[0]
        let end = points[1]
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let length = hypot(end.x - start.x, end.y - start.y)
        guard !plainLine, length > 160 else { return middle }
        let ramp = min((length - 160) / 140, 1)
        // El control dista el doble que la curva: esta se separa un 6 % del largo, como mucho.
        let reach = length * 0.12 * ramp
        return CGPoint(
            x: middle.x - (end.y - start.y) / length * reach,
            y: middle.y + (end.x - start.x) / length * reach
        )
    }

    /// Punto de la curva de la flecha, de 0 en la cola a 1 en la punta.
    func arrowPoint(at t: CGFloat) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let control = arrowControl
        let rest = 1 - t
        return CGPoint(
            x: rest * rest * points[0].x + 2 * rest * t * control.x + t * t * points[1].x,
            y: rest * rest * points[0].y + 2 * rest * t * control.y + t * t * points[1].y
        )
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
        case .pencil, .highlight, .eraser,
             .pixelate where isFreehand:
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
        // El arco de una flecha larga puede salirse del rectángulo de sus extremos.
        let reach = tool == .arrow ? bounds.union(CGRect(origin: arrowControl, size: .zero)) : bounds
        guard reach.insetBy(dx: -slack, dy: -slack).contains(point) else { return false }

        switch tool {
        case .arrow:
            guard points.count > 1 else { return false }
            let curve = (0...16).map { arrowPoint(at: CGFloat($0) / 16) }
            return zip(curve, curve.dropFirst()).contains {
                Annotation.distance(from: point, toSegment: $0, $1) <= slack + lineWidth
            }
        case .rectangle, .ellipse:
            // Hueco por dentro: se puede tocar lo que hay debajo.
            let inner = rect.insetBy(dx: slack + lineWidth, dy: slack + lineWidth)
            return inner.isEmpty || !inner.contains(point)
        case .eraser:
            return false
        case .pencil, .highlight,
             .pixelate where isFreehand:
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

    /// Cambia el tamaño desde un punto fijo. Texto y números crecen sin deformarse.
    mutating func scale(from anchor: CGPoint, x: CGFloat, y: CGFloat) {
        if tool == .text || tool == .counter {
            let factor = max(abs(x), abs(y), 0.2)
            let start = points.first ?? .zero
            points = [CGPoint(x: anchor.x + (start.x - anchor.x) * factor, y: anchor.y + (start.y - anchor.y) * factor)]
            lineWidth = max(lineWidth * factor, 0.5)
            return
        }
        points = points.map {
            CGPoint(x: anchor.x + ($0.x - anchor.x) * x, y: anchor.y + ($0.y - anchor.y) * y)
        }
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}

/// Todo lo que se puede deshacer en el editor.
struct AnnotationDocument: Equatable {
    var annotations: [Annotation] = []
    var crop: CGRect?
    /// Imagen transformada (rotada, con fondo...). `nil` es la captura original.
    var base: NSImage?
    /// Fondo alrededor de la captura. No cambia ninguna coordenada.
    var backdrop: Backdrop?

    static func == (lhs: AnnotationDocument, rhs: AnnotationDocument) -> Bool {
        lhs.crop == rhs.crop && lhs.base === rhs.base && lhs.backdrop == rhs.backdrop
            && lhs.annotations.count == rhs.annotations.count
            && zip(lhs.annotations, rhs.annotations).allSatisfy {
                $0.points == $1.points && $0.color == $1.color && $0.lineWidth == $1.lineWidth
                    && $0.blockSize == $1.blockSize && $0.text == $1.text
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
            let path = NSBezierPath(roundedRect: annotation.rect, xRadius: 3, yRadius: 3)
            if annotation.filled {
                annotation.color.setFill()
                path.fill()
            } else {
                annotation.color.setStroke()
                path.lineWidth = annotation.lineWidth
                path.stroke()
            }
        case .spotlight:
            let shade = NSBezierPath(rect: CGRect(origin: .zero, size: imageSize))
            shade.append(NSBezierPath(roundedRect: annotation.rect, xRadius: 8, yRadius: 8))
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            shade.fill()
        case .picture:
            annotation.picture?.draw(in: annotation.rect)
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
            guard let pixelated, let context = NSGraphicsContext.current?.cgContext else { return }
            NSGraphicsContext.saveGraphicsState()
            if annotation.pixelBrush {
                // El pincel recorta lo pixelado con la forma del trazo.
                let path = CGMutablePath()
                path.addLines(between: annotation.points)
                context.addPath(path.copy(strokingWithWidth: annotation.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
                context.clip()
            } else {
                NSBezierPath(rect: annotation.rect).addClip()
            }
            pixelated.draw(in: CGRect(origin: .zero, size: imageSize))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawArrow(_ annotation: Annotation) {
        guard annotation.points.count > 1 else { return }
        let start = annotation.points[0]
        let end = annotation.points[1]
        if annotation.plainLine {
            annotation.color.setStroke()
            let line = NSBezierPath()
            line.lineWidth = annotation.lineWidth
            line.lineCapStyle = .round
            line.move(to: start)
            line.line(to: end)
            line.stroke()
            return
        }
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.5 else { return }

        let width = annotation.lineWidth
        let headLength = min(14 + width * 2.6, length * 0.6)
        let headHalf = headLength * 0.56
        let baseT = max(1 - headLength / length, 0.05)
        let base = annotation.arrowPoint(at: baseT)
        let angle = atan2(end.y - base.y, end.x - base.x)
        let axis = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: -axis.y, y: axis.x)
        annotation.color.setFill()

        // Trazo: nace fino y engorda hasta perderse dentro de la cabeza.
        let tailHalf = max(width * 0.2, 0.5)
        let neckHalf = max(width * 0.62, 1.2)
        let neckT = baseT + (1 - baseT) * 0.3
        let steps = 32
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for step in 0...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let t = neckT * progress
            let point = annotation.arrowPoint(at: t)
            let ahead = annotation.arrowPoint(at: min(t + 0.01, 1))
            let behind = annotation.arrowPoint(at: max(t - 0.01, 0))
            let run = max(hypot(ahead.x - behind.x, ahead.y - behind.y), 0.001)
            let side = CGPoint(x: -(ahead.y - behind.y) / run, y: (ahead.x - behind.x) / run)
            let half = tailHalf + (neckHalf - tailHalf) * pow(progress, 0.85)
            left.append(CGPoint(x: point.x + side.x * half, y: point.y + side.y * half))
            right.append(CGPoint(x: point.x - side.x * half, y: point.y - side.y * half))
        }
        let body = NSBezierPath()
        body.move(to: left[0])
        left.dropFirst().forEach { body.line(to: $0) }
        right.reversed().forEach { body.line(to: $0) }
        body.close()
        body.fill()
        NSBezierPath(ovalIn: CGRect(x: start.x - tailHalf, y: start.y - tailHalf, width: tailHalf * 2, height: tailHalf * 2)).fill()

        // Cabeza llena de esquinas algo redondeadas, con la espalda apenas hundida.
        // La punta se adelanta lo que le quita el redondeo: sigue llegando al sitio exacto.
        let radius = min(1.2 + width * 0.22, headLength * 0.14)
        let spread = atan2(headHalf, headLength)
        let overshoot = radius * (1 / sin(spread) - 1)
        func onHead(along: CGFloat, across: CGFloat) -> CGPoint {
            CGPoint(
                x: end.x - axis.x * along + normal.x * across,
                y: end.y - axis.y * along + normal.y * across
            )
        }
        roundedPolygon([
            onHead(along: -overshoot, across: 0),
            onHead(along: headLength, across: headHalf),
            onHead(along: headLength * 0.82, across: 0),
            onHead(along: headLength, across: -headHalf),
        ], radius: radius).fill()
    }

    private static func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for (index, corner) in points.enumerated() {
            path.appendArc(from: corner, to: points[(index + 1) % points.count], radius: radius)
        }
        path.close()
        return path
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

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Annotation.markFont(ofSize: annotation.counterRadius * 1.15),
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
    static func makePixelated(_ image: NSImage, block: CGFloat = 14, smooth: Bool = false) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let source = CIImage(cgImage: cgImage)
        let blockSize = max(CGFloat(cgImage.width) / max(image.size.width, 1), 1) * block
        let filter = smooth
            ? CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: source.clampedToExtent(), kCIInputRadiusKey: blockSize * 0.6])
            : CIFilter(name: "CIPixellate", parameters: [kCIInputImageKey: source, kCIInputScaleKey: blockSize])
        guard let output = filter?.outputImage?.cropped(to: source.extent),
            let result = CIContext().createCGImage(output, from: source.extent)
        else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }
}

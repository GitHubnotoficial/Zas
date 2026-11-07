import AppKit
import CoreImage

/// Crear un `CIContext` cuesta decenas de milisegundos y mucha memoria.
/// Hay uno solo para toda la app, y se puede usar desde cualquier hilo.
enum ImageContext {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}

/// Cambios sobre la imagen completa. Conservan la densidad Retina.
@MainActor
enum ImageTools {
    private nonisolated static func pixels(of image: NSImage) -> (CGImage, CGFloat)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cgImage, CGFloat(cgImage.width) / max(image.size.width, 1))
    }

    private static func render(width: Int, height: Int, scale: CGFloat, _ draw: (CGContext) -> Void) -> NSImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        draw(context)
        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }

    static func rotated(_ image: NSImage, clockwise: Bool) -> NSImage? {
        guard let (source, scale) = pixels(of: image) else { return nil }
        return render(width: source.height, height: source.width, scale: scale) { context in
            context.translateBy(x: CGFloat(source.height) / 2, y: CGFloat(source.width) / 2)
            context.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
            context.draw(source, in: CGRect(
                x: -CGFloat(source.width) / 2,
                y: -CGFloat(source.height) / 2,
                width: CGFloat(source.width),
                height: CGFloat(source.height)
            ))
        }
    }

    static func flipped(_ image: NSImage, horizontally: Bool) -> NSImage? {
        guard let (source, scale) = pixels(of: image) else { return nil }
        return render(width: source.width, height: source.height, scale: scale) { context in
            if horizontally {
                context.translateBy(x: CGFloat(source.width), y: 0)
                context.scaleBy(x: -1, y: 1)
            } else {
                context.translateBy(x: 0, y: CGFloat(source.height))
                context.scaleBy(x: 1, y: -1)
            }
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        }
    }

    static func resized(_ image: NSImage, factor: CGFloat) -> NSImage? {
        guard let (source, scale) = pixels(of: image) else { return nil }
        let width = max(Int(CGFloat(source.width) * factor), 1)
        let height = max(Int(CGFloat(source.height) * factor), 1)
        return render(width: width, height: height, scale: scale) { context in
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Fondos propios, en degradado, para presentar una captura.
    static let backgrounds: [(name: String, colors: [NSColor])] = [
        ("Amanecer", [NSColor(srgbRed: 1, green: 0.62, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.93, green: 0.27, blue: 0.5, alpha: 1)]),
        ("Océano", [NSColor(srgbRed: 0.13, green: 0.55, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.2, green: 0.2, blue: 0.75, alpha: 1)]),
        ("Lavanda", [NSColor(srgbRed: 0.72, green: 0.62, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.97, green: 0.75, blue: 0.82, alpha: 1)]),
        ("Grafito", [NSColor(srgbRed: 0.24, green: 0.25, blue: 0.3, alpha: 1), NSColor(srgbRed: 0.07, green: 0.07, blue: 0.1, alpha: 1)]),
    ]

    static func withBackground(_ image: NSImage, colors: [NSColor], padding: CGFloat = 56) -> NSImage? {
        guard let (source, scale) = pixels(of: image) else { return nil }
        let inset = padding * scale
        let width = source.width + Int(inset * 2)
        let height = source.height + Int(inset * 2)
        return render(width: width, height: height, scale: scale) { context in
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colors.map(\.cgColor) as CFArray,
                locations: [0, 1]
            )
            if let gradient {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            }
            let frame = CGRect(x: inset, y: inset, width: CGFloat(source.width), height: CGFloat(source.height))
            let radius = 12 * scale
            let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 44 * scale, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            context.addPath(path)
            context.setFillColor(NSColor.white.cgColor)
            context.fillPath()
            context.restoreGState()
            context.addPath(path)
            context.clip()
            context.draw(source, in: frame)
        }
    }

    /// Pasa un recorte en puntos, con origen abajo, a pixeles con origen arriba.
    private nonisolated static func pixelRect(_ rect: CGRect, in image: NSImage, scale: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: (image.size.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
    }

    /// La propia captura, reducida y muy difuminada, para usarla como fondo.
    static func blurredBackdrop(of image: NSImage, crop: CGRect? = nil) -> NSImage? {
        guard let (source, scale) = pixels(of: image) else { return nil }
        var working = source
        if let crop, let cropped = source.cropping(to: pixelRect(crop, in: image, scale: scale)) {
            working = cropped
        }
        return blurred(working).map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
    }

    /// Un difuminado no necesita detalle: a este tamaño se calcula al instante.
    nonisolated static func blurred(_ image: CGImage) -> CGImage? {
        let factor = min(1, 480 / CGFloat(max(image.width, image.height, 1)))
        let reduced = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let extent = reduced.extent.integral
        let filter = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: reduced.clampedToExtent(),
            kCIInputRadiusKey: 26,
        ])
        guard let output = filter?.outputImage?.cropped(to: extent) else { return nil }
        return ImageContext.shared.createCGImage(output, from: extent)
    }

    /// Velo de una tarjeta: la captura pequeña y difuminada, para que los botones se lean sobre cualquier imagen.
    nonisolated static func veil(from image: CGImage) -> CGImage? {
        let scale = min(320 / max(CGFloat(image.width), 1), 1)
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: small.extent)
        return ImageContext.shared.createCGImage(blurred, from: small.extent)
    }

    /// Copia reducida para enseñarla pequeña.
    nonisolated static func reduced(_ image: CGImage, longestSide: Int) -> CGImage? {
        let factor = min(CGFloat(longestSide) / CGFloat(max(image.width, image.height, 1)), 1)
        let width = max(Int(CGFloat(image.width) * factor), 1)
        let height = max(Int(CGFloat(image.height) * factor), 1)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Lee el color del borde y cuánto espacio liso deja la captura en cada lado.
    nonisolated static func edgeInfo(of image: NSImage, crop: CGRect) -> EdgeInfo {
        let fallback = EdgeInfo(color: [1, 1, 1], left: 0, right: 0, top: 0, bottom: 0)
        guard let (source, scale) = pixels(of: image),
              let cropped = source.cropping(to: pixelRect(crop, in: image, scale: scale))
        else { return fallback }

        let factor = min(1, 320 / CGFloat(max(cropped.width, cropped.height, 1)))
        let width = max(Int(CGFloat(cropped.width) * factor), 1)
        let height = max(Int(CGFloat(cropped.height) * factor), 1)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let painted: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard painted else { return fallback }
        let snapshot = bytes

        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(snapshot[index]), Int(snapshot[index + 1]), Int(snapshot[index + 2]))
        }

        // El color que más se repite en el contorno.
        var counts: [Int: Int] = [:]
        var samples: [Int: (Int, Int, Int)] = [:]
        func vote(_ x: Int, _ y: Int) {
            let color = pixel(x, y)
            let key = (color.0 / 16) << 8 | (color.1 / 16) << 4 | (color.2 / 16)
            counts[key, default: 0] += 1
            samples[key] = color
        }
        for x in 0..<width {
            vote(x, 0)
            vote(x, height - 1)
        }
        for y in 0..<height {
            vote(0, y)
            vote(width - 1, y)
        }
        guard let winner = counts.max(by: { $0.value < $1.value })?.key, let edge = samples[winner] else {
            return fallback
        }

        func isEdge(_ x: Int, _ y: Int) -> Bool {
            let color = pixel(x, y)
            return abs(color.0 - edge.0) + abs(color.1 - edge.1) + abs(color.2 - edge.2) <= 24
        }
        var left = 0
        while left < width, (0..<height).allSatisfy({ isEdge(left, $0) }) {
            left += 1
        }
        let color = [CGFloat(edge.0) / 255, CGFloat(edge.1) / 255, CGFloat(edge.2) / 255]
        // Una imagen lisa no tiene contenido que centrar.
        guard left < width else {
            return EdgeInfo(color: color, left: 0, right: 0, top: 0, bottom: 0)
        }
        var right = 0
        while right < width, (0..<height).allSatisfy({ isEdge(width - 1 - right, $0) }) {
            right += 1
        }
        var top = 0
        while top < height, (0..<width).allSatisfy({ isEdge($0, top) }) {
            top += 1
        }
        var bottom = 0
        while bottom < height, (0..<width).allSatisfy({ isEdge($0, height - 1 - bottom) }) {
            bottom += 1
        }
        let perPixel = crop.width / CGFloat(width)
        return EdgeInfo(
            color: color,
            left: (CGFloat(left) * perPixel).rounded(),
            right: (CGFloat(right) * perPixel).rounded(),
            top: (CGFloat(top) * perPixel).rounded(),
            bottom: (CGFloat(bottom) * perPixel).rounded()
        )
    }

    /// Una imagen de fondo elegida por la persona, reducida para que el proyecto no pese de más.
    static func backdropPicture(from image: NSImage) -> Data? {
        guard let (source, _) = pixels(of: image) else { return nil }
        let factor = min(1, 2000 / CGFloat(max(source.width, source.height, 1)))
        let width = max(Int(CGFloat(source.width) * factor), 1)
        let height = max(Int(CGFloat(source.height) * factor), 1)
        let reduced = render(width: width, height: height, scale: 1) { context in
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cgImage = reduced?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

extension NSColor {
    /// Color sRGB escrito en hexadecimal.
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Lo que se sabe del contorno de una captura: su color y el espacio liso de cada lado, en puntos.
struct EdgeInfo: Equatable, Sendable {
    var color: [CGFloat]
    var left: CGFloat
    var right: CGFloat
    var top: CGFloat
    var bottom: CGFloat
}

/// Dónde cae cada pieza del fondo, en coordenadas de la imagen.
/// La captura no se mueve: el fondo crece hacia afuera, también a coordenadas negativas.
struct BackdropLayout: Equatable {
    /// Tarjeta redondeada que contiene la captura y su interior.
    var card: CGRect
    /// Imagen final completa.
    var outer: CGRect
}

/// Fondo no destructivo: se guarda como receta y se compone al dibujar y al exportar.
struct Backdrop: Codable, Equatable {
    enum Kind: String, Codable {
        case gradient, picture, ownBlur, softWhite, softGray, solid
    }

    var kind: Kind = .gradient
    /// Posición en `BackdropArt.gradients`.
    var gradient = 0
    /// Color liso en sRGB: rojo, verde y azul. Un cuarto valor en 0 deja el fondo transparente.
    var color: [CGFloat] = [1, 1, 1]
    /// Imagen propia, ya reducida.
    var picture: Data?
    /// Espacio entre el borde de la imagen final y la tarjeta.
    var margin: CGFloat = 64
    /// Espacio entre la tarjeta y la captura, con el color de su borde.
    var inset: CGFloat = 0
    /// De 0 a 1.
    var shadow: CGFloat = 0.5
    var corners: CGFloat = 12
    /// Centra el contenido igualando el espacio liso de cada lado.
    var autoBalance = false

    func layout(content: CGRect, edge: EdgeInfo) -> BackdropLayout {
        var card = content.insetBy(dx: -inset, dy: -inset)
        if autoBalance {
            card.origin.x -= max(0, edge.right - edge.left)
            card.size.width += abs(edge.right - edge.left)
            card.origin.y -= max(0, edge.top - edge.bottom)
            card.size.height += abs(edge.top - edge.bottom)
        }
        return BackdropLayout(card: card, outer: card.insetBy(dx: -margin, dy: -margin))
    }
}

/// Un degradado propio de Zas: una mezcla lineal y un brillo suave encima.
struct BackdropGradient {
    let name: String
    let colors: [UInt32]
    /// Dirección en radianes.
    let angle: CGFloat
    let glow: UInt32
    /// Centro del brillo, de 0 a 1 dentro del rectángulo.
    let glowCenter: CGPoint
}

/// Pinta los fondos. Lo usan el lienzo, la exportación y las muestras del panel.
@MainActor
enum BackdropArt {
    static let gradients: [BackdropGradient] = [
        BackdropGradient(name: "Brasa", colors: [0xFF7A45, 0xE8336D, 0x6D2BD9], angle: 0.9, glow: 0xFFC46B, glowCenter: CGPoint(x: 0.15, y: 0.85)),
        BackdropGradient(name: "Marea", colors: [0x12C2C9, 0x1A7BE0, 0x2A2F9E], angle: 1.2, glow: 0x7CF2D6, glowCenter: CGPoint(x: 0.8, y: 0.8)),
        BackdropGradient(name: "Pradera", colors: [0xB7E36B, 0x35B779, 0x0E7C7B], angle: 0.5, glow: 0xF4F58A, glowCenter: CGPoint(x: 0.2, y: 0.2)),
        BackdropGradient(name: "Lirio", colors: [0xC9A7FF, 0x8E6CF0, 0x4A3BC7], angle: 2.2, glow: 0xFFB8E0, glowCenter: CGPoint(x: 0.85, y: 0.3)),
        BackdropGradient(name: "Melocotón", colors: [0xFFE0B5, 0xFFB08A, 0xF2779C], angle: 1.0, glow: 0xFFF3C4, glowCenter: CGPoint(x: 0.25, y: 0.75)),
        BackdropGradient(name: "Noche clara", colors: [0x27304F, 0x1B4F8C, 0x2FA3B5], angle: 1.4, glow: 0x7A5CFF, glowCenter: CGPoint(x: 0.75, y: 0.15)),
        BackdropGradient(name: "Cítrico", colors: [0xFFE45C, 0xFFA92B, 0xF2542D], angle: 0.3, glow: 0xFFF7A8, glowCenter: CGPoint(x: 0.7, y: 0.9)),
        BackdropGradient(name: "Bruma", colors: [0xDCE8F5, 0xB6C8E8, 0xA4A9E0], angle: 1.8, glow: 0xFFFFFF, glowCenter: CGPoint(x: 0.3, y: 0.8)),
        BackdropGradient(name: "Coral", colors: [0xFF9A8B, 0xFF6A88, 0xC850C0], angle: 0.7, glow: 0xFFD3A5, glowCenter: CGPoint(x: 0.9, y: 0.75)),
        BackdropGradient(name: "Bosque", colors: [0x1F4037, 0x2C7A5B, 0x8FBF6A], angle: 2.6, glow: 0xCFE88B, glowCenter: CGPoint(x: 0.8, y: 0.2)),
        BackdropGradient(name: "Cielo", colors: [0xA8E6FF, 0x6BB8FF, 0x5C7CFA], angle: 1.5, glow: 0xFFFFFF, glowCenter: CGPoint(x: 0.5, y: 0.95)),
        BackdropGradient(name: "Ciruela", colors: [0x4B1D52, 0x8A2C7A, 0xE0527E], angle: 0.8, glow: 0xFF9E7A, glowCenter: CGPoint(x: 0.1, y: 0.15)),
        BackdropGradient(name: "Menta", colors: [0xD8F8E4, 0x9BE8C9, 0x5CCFC4], angle: 1.1, glow: 0xFFFBD0, glowCenter: CGPoint(x: 0.2, y: 0.85)),
        BackdropGradient(name: "Arena", colors: [0xF3E5CF, 0xDFC49C, 0xB98F6B], angle: 2.0, glow: 0xFFF4DE, glowCenter: CGPoint(x: 0.75, y: 0.8)),
        BackdropGradient(name: "Aurora", colors: [0x0F2B46, 0x176B6B, 0x3FD8A2], angle: 1.3, glow: 0xB46CFF, glowCenter: CGPoint(x: 0.85, y: 0.85)),
        BackdropGradient(name: "Chicle", colors: [0xFFB3E6, 0xD9A6FF, 0x8FC7FF], angle: 0.4, glow: 0xFFFFFF, glowCenter: CGPoint(x: 0.5, y: 0.1)),
        BackdropGradient(name: "Volcán", colors: [0x1C1C24, 0x7A1F2B, 0xF2552C], angle: 1.0, glow: 0xFFB347, glowCenter: CGPoint(x: 0.95, y: 0.05)),
        BackdropGradient(name: "Hielo", colors: [0xF2FBFF, 0xC6E9F7, 0x8CC4E8], angle: 2.4, glow: 0xE6DCFF, glowCenter: CGPoint(x: 0.15, y: 0.3)),
        BackdropGradient(name: "Pizarra", colors: [0x4A5568, 0x2D3442, 0x171B24], angle: 1.6, glow: 0x6B7A99, glowCenter: CGPoint(x: 0.25, y: 0.9)),
        BackdropGradient(name: "Tarde", colors: [0xFDC27A, 0xF0768A, 0x5B5FC7], angle: 1.7, glow: 0xFFE9A8, glowCenter: CGPoint(x: 0.8, y: 0.9)),
    ]

    private static func cgGradient(_ colors: [NSColor]) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors.map(\.cgColor) as CFArray,
            locations: nil
        )
    }

    /// Mezcla lineal que cruza todo el rectángulo en la dirección pedida.
    private static func fillLinear(_ colors: [NSColor], angle: CGFloat, in rect: CGRect, context: CGContext) {
        guard let gradient = cgGradient(colors) else { return }
        let reach = (abs(cos(angle)) * rect.width + abs(sin(angle)) * rect.height) / 2
        let shift = CGPoint(x: cos(angle) * reach, y: sin(angle) * reach)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX - shift.x, y: rect.midY - shift.y),
            end: CGPoint(x: rect.midX + shift.x, y: rect.midY + shift.y),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    static func drawGradient(_ index: Int, in rect: CGRect, context: CGContext) {
        let entry = gradients[min(max(index, 0), gradients.count - 1)]
        context.saveGState()
        context.clip(to: rect)
        fillLinear(entry.colors.map { NSColor.hex($0) }, angle: entry.angle, in: rect, context: context)
        if let glow = cgGradient([NSColor.hex(entry.glow, alpha: 0.75), NSColor.hex(entry.glow, alpha: 0)]) {
            let center = CGPoint(
                x: rect.minX + rect.width * entry.glowCenter.x,
                y: rect.minY + rect.height * entry.glowCenter.y
            )
            context.drawRadialGradient(
                glow,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: max(rect.width, rect.height) * 0.7,
                options: []
            )
        }
        context.restoreGState()
    }

    static func drawSoft(white: Bool, in rect: CGRect, context: CGContext) {
        let colors = white ? [NSColor.hex(0xFCFCFD), NSColor.hex(0xE9EAEE)] : [NSColor.hex(0xC9CBD1), NSColor.hex(0x9EA1A9)]
        context.saveGState()
        context.clip(to: rect)
        fillLinear(colors, angle: 1.3, in: rect, context: context)
        context.restoreGState()
    }

    /// Llena el rectángulo sin deformar la imagen. Lo que sobra queda fuera.
    static func drawCover(_ image: NSImage, in rect: CGRect) {
        let size = image.size
        let ratio = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let width = size.width * ratio
        let height = size.height * ratio
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        image.draw(in: CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawFill(_ backdrop: Backdrop, in rect: CGRect, blurred: NSImage?, picture: NSImage?, context: CGContext) {
        switch backdrop.kind {
        case .gradient:
            drawGradient(backdrop.gradient, in: rect, context: context)
        case .softWhite:
            drawSoft(white: true, in: rect, context: context)
        case .softGray:
            drawSoft(white: false, in: rect, context: context)
        case .solid:
            guard backdrop.color.count < 4 || backdrop.color[3] > 0 else { break }
            context.setFillColor(color(backdrop.color).cgColor)
            context.fill(rect)
        case .ownBlur:
            if let blurred {
                drawCover(blurred, in: rect)
            } else {
                drawSoft(white: false, in: rect, context: context)
            }
        case .picture:
            if let picture {
                drawCover(picture, in: rect)
            } else {
                drawSoft(white: false, in: rect, context: context)
            }
        }
    }

    static func color(_ components: [CGFloat]) -> NSColor {
        guard components.count >= 3 else { return .white }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
    }

    /// Compone el fondo, la sombra y la tarjeta. `inside` dibuja la captura y sus marcas ya recortadas.
    static func compose(
        _ backdrop: Backdrop,
        layout: BackdropLayout,
        content: CGRect,
        edge: EdgeInfo,
        blurred: NSImage?,
        picture: NSImage?,
        inside: () -> Void
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawFill(backdrop, in: layout.outer, blurred: blurred, picture: picture, context: context)

        let card = layout.card
        let radius = max(min(backdrop.corners, min(card.width, card.height) / 2), 0)
        let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let fill = color(edge.color).cgColor

        if backdrop.shadow > 0.001 {
            // La sombra de Core Graphics se mide en pixeles reales: no sigue la escala del dibujo.
            let transform = context.userSpaceToDeviceSpaceTransform
            let device = hypot(transform.a, transform.b)
            let strength = min(backdrop.shadow, 1)
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -(4 + 18 * strength) * device),
                blur: (10 + 50 * strength) * device,
                color: NSColor.black.withAlphaComponent(0.16 + 0.36 * strength).cgColor
            )
            context.addPath(path)
            context.setFillColor(fill)
            context.fillPath()
            context.restoreGState()
        }

        NSGraphicsContext.saveGraphicsState()
        context.addPath(path)
        context.clip()
        context.setFillColor(fill)
        context.fill(card)
        let innerRadius = max(radius - backdrop.inset, 0)
        NSBezierPath(roundedRect: content, xRadius: innerRadius, yRadius: innerRadius).addClip()
        inside()
        NSGraphicsContext.restoreGraphicsState()
    }
}

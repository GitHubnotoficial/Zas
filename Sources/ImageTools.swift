import AppKit

/// Cambios sobre la imagen completa. Conservan la densidad Retina.
@MainActor
enum ImageTools {
    private static func pixels(of image: NSImage) -> (CGImage, CGFloat)? {
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
}

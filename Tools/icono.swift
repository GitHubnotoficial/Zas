// Genera el icono de Zas. Uso: swift Tools/icono.swift <carpeta.iconset> <vista-previa.png>
import AppKit

func render(size pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // Retícula de iconos de macOS: 824 de contenido dentro de 1024.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    NSGradient(
        starting: NSColor(srgbRed: 0.19, green: 0.19, blue: 0.25, alpha: 1),
        ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.10, alpha: 1)
    )?.draw(in: shape, angle: -90)

    let yellow = NSColor(srgbRed: 1.0, green: 0.81, blue: 0.06, alpha: 1)

    // Esquinas del visor.
    let box = body.insetBy(dx: 158, dy: 158)
    let arm: CGFloat = 132
    let corners = NSBezierPath()
    corners.lineWidth = 50
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    let segments: [[NSPoint]] = [
        [NSPoint(x: box.minX, y: box.minY + arm), NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.minX + arm, y: box.minY)],
        [NSPoint(x: box.maxX - arm, y: box.minY), NSPoint(x: box.maxX, y: box.minY), NSPoint(x: box.maxX, y: box.minY + arm)],
        [NSPoint(x: box.maxX, y: box.maxY - arm), NSPoint(x: box.maxX, y: box.maxY), NSPoint(x: box.maxX - arm, y: box.maxY)],
        [NSPoint(x: box.minX + arm, y: box.maxY), NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.minX, y: box.maxY - arm)],
    ]
    for segment in segments {
        corners.move(to: segment[0])
        corners.line(to: segment[1])
        corners.line(to: segment[2])
    }
    NSColor.white.withAlphaComponent(0.92).setStroke()
    corners.stroke()

    // Rayo central.
    let bolt = NSBezierPath()
    let points: [NSPoint] = [
        NSPoint(x: 566, y: 716), NSPoint(x: 380, y: 480), NSPoint(x: 494, y: 480),
        NSPoint(x: 458, y: 308), NSPoint(x: 644, y: 544), NSPoint(x: 530, y: 544),
    ]
    bolt.move(to: points[0])
    for point in points.dropFirst() {
        bolt.line(to: point)
    }
    bolt.close()
    bolt.lineJoinStyle = .round
    bolt.lineWidth = 14
    yellow.setFill()
    yellow.setStroke()
    bolt.fill()
    bolt.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: folder.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: folder.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try render(size: 512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}

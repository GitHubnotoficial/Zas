// Video de lanzamiento de Zas: imagen y sonido se generan aquí, sin plantillas ni grabaciones.
// La interfaz que aparece es una animación basada en la app.
// Uso: promo <carpeta-de-salida>
import AVFoundation
import AppKit
import CoreImage

let width = 1920
let height = 1080
let W = CGFloat(width)
let H = CGFloat(height)
let fps = 30
let subframes = 4
let duration: CGFloat = 30

let yellow = NSColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1)
let ink = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)
let red = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let imageContext = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])

var ctx: CGContext!

// MARK: - Tiempo

func span(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { min(max((t - a) / (b - a), 0), 1) }
func easeOut(_ x: CGFloat) -> CGFloat { 1 - pow(1 - x, 3) }
func expoOut(_ x: CGFloat) -> CGFloat { x >= 1 ? 1 : 1 - pow(2, -10 * x) }
func expoIn(_ x: CGFloat) -> CGFloat { x <= 0 ? 0 : pow(2, 10 * x - 10) }
func easeInOut(_ x: CGFloat) -> CGFloat { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeBack(_ x: CGFloat) -> CGFloat {
    let c: CGFloat = 1.70158
    return 1 + (c + 1) * pow(x - 1, 3) + c * pow(x - 1, 2)
}
func mix(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat { a + (b - a) * x }
func mix(_ a: CGRect, _ b: CGRect, _ x: CGFloat) -> CGRect {
    CGRect(x: mix(a.minX, b.minX, x), y: mix(a.minY, b.minY, x), width: mix(a.width, b.width, x), height: mix(a.height, b.height, x))
}

// MARK: - Dibujo básico

func rounded(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func stroked(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor, _ width: CGFloat) {
    color.setStroke()
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.lineWidth = width
    path.stroke()
}

enum Align { case left, center, right }

func attributed(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, mono: Bool) -> NSAttributedString {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: mono ? 0 : -size * 0.022])
}

@discardableResult
func text(
    _ string: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
    at point: CGPoint, align: Align = .left, mono: Bool = false
) -> CGSize {
    let line = attributed(string, size, weight, color, mono: mono)
    let measured = line.size()
    var x = point.x
    if align == .center { x -= measured.width / 2 }
    if align == .right { x -= measured.width }
    line.draw(at: CGPoint(x: x, y: point.y))
    return measured
}

func withAlpha(_ alpha: CGFloat, _ body: () -> Void) {
    guard alpha > 0.001 else { return }
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func scaled(_ scale: CGFloat, around center: CGPoint, _ body: () -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -center.x, y: -center.y)
    body()
    ctx.restoreGState()
}

func shadow(_ blur: CGFloat, _ y: CGFloat, _ alpha: CGFloat, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -y), blur: blur, color: NSColor.black.withAlphaComponent(alpha).cgColor)
    body()
    ctx.restoreGState()
}

func glow(_ point: CGPoint, _ radius: CGFloat, _ color: NSColor, _ alpha: CGFloat) {
    guard alpha > 0.001 else { return }
    let colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: [])
}

func symbol(_ name: String, _ rect: CGRect, _ color: NSColor) {
    let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium)
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return }
    let size = image.size
    let ratio = min(rect.width / size.width, rect.height / size.height)
    let drawn = CGSize(width: size.width * ratio, height: size.height * ratio)
    let target = CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
    let tinted = NSImage(size: size, flipped: false) { bounds in
        image.draw(in: bounds)
        color.setFill()
        bounds.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

/// Dibuja en una imagen aparte, para poder inclinarla en perspectiva.
func layer(_ size: CGSize, scale: CGFloat = 1.6, _ body: () -> Void) -> CGImage {
    let pixelWidth = Int(size.width * scale)
    let pixelHeight = Int(size.height * scale)
    let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)
    let saved = ctx
    ctx = context
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
    ctx = saved
    return context.makeImage()!
}

/// Coloca una imagen en el espacio: `yaw` gira a los lados y `pitch` hacia atrás.
func tilted(_ image: CGImage, center: CGPoint, size: CGSize, yaw: CGFloat, pitch: CGFloat, zoom: CGFloat = 1) {
    let focal: CGFloat = 2100
    func project(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let x1 = x * cos(yaw)
        let z1 = -x * sin(yaw)
        let y2 = y * cos(pitch) - z1 * sin(pitch)
        let z2 = y * sin(pitch) + z1 * cos(pitch)
        let s = focal / (focal + z2) * zoom
        return CGPoint(x: center.x + x1 * s, y: center.y + y2 * s)
    }
    let halfW = size.width / 2
    let halfH = size.height / 2
    let topLeft = project(-halfW, -halfH)
    let topRight = project(halfW, -halfH)
    let bottomRight = project(halfW, halfH)
    let bottomLeft = project(-halfW, halfH)

    let quad = NSBezierPath()
    quad.move(to: topLeft)
    quad.line(to: topRight)
    quad.line(to: bottomRight)
    quad.line(to: bottomLeft)
    quad.close()
    shadow(120, 60, 0.75) {
        NSColor(white: 0.1, alpha: 1).setFill()
        quad.fill()
    }

    func vector(_ point: CGPoint) -> CIVector { CIVector(x: point.x, y: H - point.y) }
    guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return }
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    filter.setValue(vector(topLeft), forKey: "inputTopLeft")
    filter.setValue(vector(topRight), forKey: "inputTopRight")
    filter.setValue(vector(bottomRight), forKey: "inputBottomRight")
    filter.setValue(vector(bottomLeft), forKey: "inputBottomLeft")
    guard let output = filter.outputImage,
          let result = imageContext.createCGImage(output, from: output.extent)
    else { return }

    let extent = output.extent
    let rect = CGRect(x: extent.minX, y: H - extent.maxY, width: extent.width, height: extent.height)
    ctx.saveGState()
    ctx.translateBy(x: 0, y: rect.minY * 2 + rect.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(result, in: rect)
    ctx.restoreGState()
}

// MARK: - Fondo

/// Golpes de la música: la imagen reacciona a ellos.
let impacts: [CGFloat] = [4, 8, 16.5, 26]

func background(_ t: CGFloat) {
    NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: W, height: H).fill()
    let drop = span(t, 3.9, 4.3)
    let warm = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.08, alpha: 1)
    let cool = NSColor(srgbRed: 0.22, green: 0.3, blue: 0.95, alpha: 1)
    glow(CGPoint(x: W * 0.72 + cos(t * 0.4) * 240, y: H * 0.34 + sin(t * 0.5) * 150), 1050, warm, 0.05 + 0.2 * drop)
    glow(CGPoint(x: W * 0.16 + sin(t * 0.35) * 200, y: H * 0.86 + cos(t * 0.3) * 90), 950, cool, 0.03 + 0.15 * drop)
    let beat = t >= 4 && t < 26 ? pow(1 - (t.truncatingRemainder(dividingBy: 0.5) / 0.5), 3) : 0
    glow(CGPoint(x: W / 2, y: H * 1.1), 900, warm, beat * 0.07)
}

func vignette() {
    let colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.62).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0.55, 1])!
    let center = CGPoint(x: W / 2, y: H / 2)
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: W * 0.68, options: [.drawsAfterEndLocation])
}

// MARK: - Tipografía

func gradientText(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight, at point: CGPoint, align: Align, top: NSColor, bottom: NSColor) {
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let measured = text(string, size, weight, .white, at: point, align: align)
    ctx.setBlendMode(.sourceAtop)
    let colors = [top.cgColor, bottom.cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0.2, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: point.y), end: CGPoint(x: 0, y: point.y + measured.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// La línea sube desde detrás de una máscara, y sale hacia arriba.
func reveal(
    _ string: String, _ size: CGFloat, _ weight: NSFont.Weight = .heavy, at point: CGPoint, align: Align = .left,
    start: CGFloat, end: CGFloat, _ t: CGFloat,
    top: NSColor = .white, bottom: NSColor = NSColor(white: 0.66, alpha: 1)
) {
    let enter = expoOut(span(t, start, start + 0.5))
    let leave = expoIn(span(t, end - 0.25, end))
    guard enter > 0, leave < 1 else { return }
    let lineHeight = size * 1.28
    let offset = (1 - enter) * lineHeight - leave * lineHeight
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: point.y, width: W, height: lineHeight))
    gradientText(string, size, weight, at: CGPoint(x: point.x, y: point.y + offset), align: align, top: top, bottom: bottom)
    ctx.restoreGState()
}

func keycaps(_ keys: [String], origin: CGPoint, start: CGFloat, _ t: CGFloat, size: CGFloat = 84) {
    var x = origin.x
    for (index, key) in keys.enumerated() {
        let at = start + CGFloat(index) * 0.1
        let local = span(t, at, at + 0.36)
        let keyWidth = key.count > 1 ? size * 1.45 : size
        defer { x += keyWidth + 12 }
        guard local > 0 else { continue }
        let press = span(t, at, at + 0.06) - span(t, at + 0.08, at + 0.24)
        let rect = CGRect(x: x, y: origin.y + press * 8, width: keyWidth, height: size)
        scaled(easeBack(local), around: CGPoint(x: rect.midX, y: rect.midY)) {
            shadow(20, 10, 0.6) {
                rounded(rect, 16, NSColor(white: 0.15, alpha: 1))
            }
            stroked(rect.insetBy(dx: 0.75, dy: 0.75), 15.5, NSColor(white: 1, alpha: 0.22), 1.5)
            let fontSize = key.count > 1 ? size * 0.34 : size * 0.48
            text(key, fontSize, .semibold, .white, at: CGPoint(x: rect.midX, y: rect.midY - fontSize * 0.62), align: .center)
        }
    }
}

// MARK: - Logo

func logo(center: CGPoint, size: CGFloat, _ progress: CGFloat) {
    let box = easeBack(span(progress, 0, 0.5))
    guard box > 0 else { return }
    let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    scaled(box, around: center) {
        shadow(size * 0.28, size * 0.1, 0.8) {
            rounded(rect, size * 0.225, NSColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1))
        }
        stroked(rect.insetBy(dx: 1.5, dy: 1.5), size * 0.225, NSColor(white: 1, alpha: 0.16), 2.5)

        let inset = size * 0.22
        let frame = rect.insetBy(dx: inset, dy: inset)
        let arm = size * 0.15
        let corners: [[CGPoint]] = [
            [CGPoint(x: frame.minX, y: frame.minY + arm), CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX + arm, y: frame.minY)],
            [CGPoint(x: frame.maxX - arm, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY + arm)],
            [CGPoint(x: frame.maxX, y: frame.maxY - arm), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.maxX - arm, y: frame.maxY)],
            [CGPoint(x: frame.minX + arm, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY - arm)],
        ]
        NSColor.white.setStroke()
        for (index, corner) in corners.enumerated() {
            let drawn = expoOut(span(progress, 0.1 + CGFloat(index) * 0.06, 0.5 + CGFloat(index) * 0.06))
            guard drawn > 0 else { continue }
            let path = NSBezierPath()
            path.lineWidth = size * 0.052
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: corner[0])
            path.line(to: corner[1])
            path.line(to: corner[2])
            let dash = arm * 2.05
            path.setLineDash([dash * drawn, dash], count: 2, phase: 0)
            path.stroke()
        }
        let bolt = easeBack(span(progress, 0, 0.4))
        if bolt > 0 {
            glow(center, size * 0.5, yellow, 0.35)
            scaled(bolt, around: center) {
                let unit = size / 18
                let points: [(CGFloat, CGFloat)] = [(10.2, 4), (5.8, 9.7), (8.6, 9.7), (7.8, 14), (12.2, 8.3), (9.4, 8.3)]
                let path = NSBezierPath()
                for (index, point) in points.enumerated() {
                    let position = CGPoint(x: rect.minX + point.0 * unit, y: rect.minY + point.1 * unit)
                    index == 0 ? path.move(to: position) : path.line(to: position)
                }
                path.close()
                yellow.setFill()
                path.fill()
            }
        }
    }
}

// MARK: - La ventana de ejemplo

let rows: [(String, String, String, NSColor)] = [
    ("Pedido 1042", "María Pérez", "$ 128.000", .systemGreen),
    ("Pedido 1043", "Carlos Rojas", "$ 54.500", .systemOrange),
    ("Pedido 1044", "Ana Gómez", "$ 312.900", .systemGreen),
    ("Pedido 1045", "Luis Torres", "Error al guardar", .systemRed),
]

let designSize = CGSize(width: 900, height: 480)
let stageSize = CGSize(width: 1090, height: 581)
let stageCenter = CGPoint(x: 1365, y: 540)

func appContent(_ size: CGSize, overlay: (() -> Void)? = nil) {
    ctx.saveGState()
    NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 18, yRadius: 18).addClip()
    ctx.scaleBy(x: size.width / designSize.width, y: size.height / designSize.height)
    NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
    CGRect(origin: .zero, size: designSize).fill()
    NSColor(srgbRed: 0.1, green: 0.11, blue: 0.16, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: 190, height: designSize.height).fill()
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: 16 + CGFloat(index) * 20, y: 14, width: 12, height: 12)).fill()
    }
    for (index, title) in ["Inicio", "Pedidos", "Clientes", "Reportes", "Ajustes"].enumerated() {
        text(title, 15, .medium, .white, at: CGPoint(x: 26, y: 58 + CGFloat(index) * 38))
    }
    text("Pedidos de hoy", 26, .bold, .black, at: CGPoint(x: 220, y: 26))
    for (index, row) in rows.enumerated() {
        let y = 86 + CGFloat(index) * 66
        rounded(CGRect(x: 220, y: y, width: 650, height: 54), 8, .white)
        text(row.0, 15, .regular, .darkGray, at: CGPoint(x: 240, y: y + 17))
        text(row.1, 15, .regular, .darkGray, at: CGPoint(x: 400, y: y + 17))
        text(row.2, 15, .medium, row.3, at: CGPoint(x: 640, y: y + 17))
    }
    overlay?()
    ctx.restoreGState()
}

let errorRow = CGRect(x: 214, y: 278, width: 662, height: 66)

func arrow(from a: CGPoint, to b: CGPoint, _ progress: CGFloat, _ color: NSColor, width: CGFloat) {
    guard progress > 0 else { return }
    let end = CGPoint(x: mix(a.x, b.x, progress), y: mix(a.y, b.y, progress))
    let angle = atan2(end.y - a.y, end.x - a.x)
    let head = width * 3.6
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.move(to: a)
    path.line(to: CGPoint(x: end.x - cos(angle) * head * 0.7, y: end.y - sin(angle) * head * 0.7))
    color.setStroke()
    path.stroke()
    let tip = NSBezierPath()
    tip.move(to: end)
    tip.line(to: CGPoint(x: end.x - cos(angle - 0.45) * head, y: end.y - sin(angle - 0.45) * head))
    tip.line(to: CGPoint(x: end.x - cos(angle + 0.45) * head, y: end.y - sin(angle + 0.45) * head))
    tip.close()
    color.setFill()
    tip.fill()
}

func cursor(at point: CGPoint, scale s: CGFloat = 1.1) {
    let path = NSBezierPath()
    path.move(to: point)
    path.line(to: CGPoint(x: point.x, y: point.y + 17 * s))
    path.line(to: CGPoint(x: point.x + 4.4 * s, y: point.y + 13 * s))
    path.line(to: CGPoint(x: point.x + 7.2 * s, y: point.y + 19 * s))
    path.line(to: CGPoint(x: point.x + 10 * s, y: point.y + 17.8 * s))
    path.line(to: CGPoint(x: point.x + 7.3 * s, y: point.y + 12 * s))
    path.line(to: CGPoint(x: point.x + 12.5 * s, y: point.y + 12 * s))
    path.close()
    shadow(6, 2, 0.5) {
        NSColor.black.setFill()
        path.fill()
    }
    NSColor.white.setStroke()
    path.lineWidth = 1.1
    path.stroke()
}

/// Título a la izquierda: número, palabra y detalle.
func headline(_ number: String, _ word: String, _ detail: String, start: CGFloat, end: CGFloat, _ t: CGFloat, size: CGFloat = 110) {
    reveal(number, 30, .bold, at: CGPoint(x: 96, y: 300), start: start, end: end, t, top: yellow, bottom: yellow)
    reveal(word, size, .heavy, at: CGPoint(x: 90, y: 342), start: start + 0.05, end: end, t)
    reveal(detail, 34, .medium, at: CGPoint(x: 96, y: 522), start: start + 0.2, end: end, t, top: NSColor(white: 0.72, alpha: 1), bottom: NSColor(white: 0.62, alpha: 1))
}

func stage(yaw: CGFloat, pitch: CGFloat, zoom: CGFloat, enter: CGFloat, overlay: (() -> Void)? = nil) {
    let image = layer(stageSize) { appContent(stageSize, overlay: overlay) }
    let settle = expoOut(enter)
    tilted(
        image,
        center: CGPoint(x: stageCenter.x + (1 - settle) * 460, y: stageCenter.y),
        size: stageSize,
        yaw: yaw + (1 - settle) * -0.5,
        pitch: pitch,
        zoom: zoom
    )
}

// MARK: - Escenas

/// 0 a 4: la promesa, sobre negro, mientras la música sube.
func sceneHook(_ t: CGFloat) {
    reveal("Tu agente", 136, at: CGPoint(x: W / 2, y: 370), align: .center, start: 0.25, end: 2.35, t)
    reveal("no ve tu pantalla.", 136, at: CGPoint(x: W / 2, y: 530), align: .center, start: 0.75, end: 2.35, t)
    reveal("Ahora sí.", 176, at: CGPoint(x: W / 2, y: 430), align: .center, start: 2.5, end: 3.95, t, top: yellow, bottom: NSColor(srgbRed: 1, green: 0.55, blue: 0.05, alpha: 1))
}

/// 4 a 6: el golpe.
func sceneLogo(_ t: CGFloat) {
    let local = t - 4
    for ring in 0..<3 {
        let wave = easeOut(span(local, CGFloat(ring) * 0.07, 0.9 + CGFloat(ring) * 0.07))
        guard wave > 0, wave < 1 else { continue }
        let side = 300 + wave * 1400
        let rect = CGRect(x: W / 2 - side / 2, y: 430 - side / 2, width: side, height: side)
        stroked(rect, side * 0.26, yellow.withAlphaComponent((1 - wave) * 0.55), 5 * (1 - wave) + 1)
    }
    glow(CGPoint(x: W / 2, y: 430), 760, yellow, (1 - span(local, 0, 0.8)) * 0.55)
    logo(center: CGPoint(x: W / 2, y: 420), size: 300, span(local, 0, 0.7))
    reveal("Zas", 128, at: CGPoint(x: W / 2, y: 610), align: .center, start: 4.3, end: 6.0, t)
    reveal("Capturas y video para trabajar con Claude.", 42, .medium, at: CGPoint(x: W / 2, y: 790), align: .center, start: 4.75, end: 6.0, t, top: NSColor(white: 0.85, alpha: 1), bottom: NSColor(white: 0.7, alpha: 1))
}

/// 6 a 8: seleccionar.
func sceneSelect(_ t: CGFloat) {
    headline("01", "Selecciona.", "Un atajo. Un arrastre.", start: 6, end: 8, t)
    keycaps(["⇧", "⌘", "2"], origin: CGPoint(x: 96, y: 610), start: 6.25, t)
    let dim = span(t, 6.55, 6.7)
    let grow = easeInOut(span(t, 6.7, 7.75))
    stage(yaw: -0.2 - span(t, 6, 8) * 0.04, pitch: 0.06, zoom: 1 + span(t, 6, 8) * 0.07, enter: span(t, 6, 6.6)) {
        let target = errorRow
        let rect = CGRect(x: target.minX, y: target.minY, width: max(target.width * grow, 1), height: max(target.height * grow, 1))
        if dim > 0 {
            let path = NSBezierPath(rect: CGRect(origin: .zero, size: designSize))
            if grow > 0 {
                path.append(NSBezierPath(rect: rect))
                path.windingRule = .evenOdd
            }
            NSColor.black.withAlphaComponent(0.55 * dim).setFill()
            path.fill()
        }
        if grow > 0 {
            stroked(rect, 0, .white, 1.6)
            let pill = CGRect(x: rect.minX, y: rect.maxY + 10, width: 118, height: 30)
            rounded(pill, 15, NSColor.black.withAlphaComponent(0.85))
            text("\(Int(rect.width * 2)) × \(Int(rect.height * 2))", 14, .medium, .white, at: CGPoint(x: pill.midX, y: pill.minY + 6), align: .center, mono: true)
            cursor(at: CGPoint(x: rect.maxX, y: rect.maxY))
        }
    }
}

/// 8 a 10: copiado.
func sceneCopied(_ t: CGFloat) {
    let local = t - 8
    headline("02", "Copiado.", "Sin menús. Sin pasos de más.", start: 8.05, end: 10, t)
    withAlpha(1 - span(local, 0.1, 0.5) * 0.55) {
        stage(yaw: -0.24, pitch: 0.06, zoom: 1.07 + local * 0.012, enter: 1)
    }
    let fly = expoOut(span(local, 0.04, 0.6))
    let start = CGRect(x: 900, y: 610, width: 800, height: 80)
    let target = CGRect(x: 820, y: 390, width: 1000, height: 288)
    let card = mix(start, target, fly)
    let tilt = sin(local * 1.6) * 4
    ctx.saveGState()
    ctx.translateBy(x: 0, y: tilt)
    glow(CGPoint(x: card.midX, y: card.midY), card.width * 0.7, yellow, 0.22 * fly)
    shadow(90, 40, 0.8) {
        rounded(card, 26, .white)
    }
    let scale = card.width / 1040
    scaled(scale, around: card.origin) {
        text("Pedido 1045", 50, .regular, .darkGray, at: CGPoint(x: card.minX + 56, y: card.minY + 56))
        text("Luis Torres", 50, .regular, .gray, at: CGPoint(x: card.minX + 380, y: card.minY + 56))
        text("Error al guardar", 50, .semibold, .systemRed, at: CGPoint(x: card.minX + 660, y: card.minY + 56))
        let badge = easeBack(span(local, 0.5, 0.85))
        if badge > 0 {
            let pill = CGRect(x: card.minX + 56, y: card.minY + 170, width: 262, height: 76)
            scaled(badge, around: CGPoint(x: pill.midX, y: pill.midY)) {
                rounded(pill, 38, yellow)
                symbol("checkmark", CGRect(x: pill.minX + 28, y: pill.minY + 22, width: 32, height: 32), ink)
                text("Copiado", 37, .bold, ink, at: CGPoint(x: pill.minX + 76, y: pill.minY + 15))
            }
        }
    }
    ctx.restoreGState()
    let flash = 1 - span(local, 0, 0.22)
    NSColor.white.withAlphaComponent(flash * 0.8).setFill()
    CGRect(x: 0, y: 0, width: W, height: H).fill()
}

/// 10 a 12: marcar.
func sceneAnnotate(_ t: CGFloat) {
    headline("03", "Márcalo.", "Flechas, cuadros y texto.", start: 10, end: 12, t)
    stage(yaw: -0.17, pitch: 0.05, zoom: 1.02 + span(t, 10, 12) * 0.06, enter: span(t, 10, 10.55)) {
        // Barra del editor, para que se vea la herramienta en uso.
        let bar = CGRect(x: 214, y: 424, width: 662, height: 46)
        shadow(14, 4, 0.3) {
            rounded(bar, 12, NSColor(white: 0.96, alpha: 1))
        }
        let names = ["cursorarrow", "arrow.up.right", "rectangle", "circle", "highlighter", "scribble", "textformat", "1.circle", "crop"]
        for (index, name) in names.enumerated() {
            let box = CGRect(x: 226 + CGFloat(index) * 36, y: 433, width: 28, height: 28)
            let active = (index == 1 && t < 11) || (index == 2 && t >= 11 && t < 11.5) || (index == 6 && t >= 11.5)
            if active { rounded(box, 7, .systemBlue) }
            symbol(name, box.insetBy(dx: 6, dy: 6), active ? .white : NSColor(white: 0.25, alpha: 1))
        }
        let copy = CGRect(x: 790, y: 433, width: 76, height: 28)
        rounded(copy, 7, .systemBlue)
        text("Copiar", 14, .semibold, .white, at: CGPoint(x: copy.midX, y: copy.minY + 5), align: .center)

        arrow(from: CGPoint(x: 845, y: 70), to: CGPoint(x: 806, y: 296), expoOut(span(t, 10.5, 10.95)), .systemRed, width: 5.5)
        let box = expoOut(span(t, 11, 11.4))
        if box > 0 {
            let rect = CGRect(x: 628, y: 288, width: 172 * box, height: 46 * box)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            path.lineWidth = 4
            NSColor.systemRed.setStroke()
            path.stroke()
        }
        let note = easeBack(span(t, 11.5, 11.85))
        if note > 0 {
            let origin = CGPoint(x: 640, y: 56)
            scaled(note, around: origin) {
                text("Esto debería guardar", 19, .bold, .systemRed, at: origin)
            }
        }
    }
}

/// 12 a 14.5: grabar.
func sceneRecord(_ t: CGFloat) {
    headline("04", "Graba.", "Muéstrale lo que pasa.", start: 12, end: 14.5, t)
    keycaps(["⇧", "⌘", "6"], origin: CGPoint(x: 96, y: 610), start: 12.25, t)
    let travel = easeInOut(span(t, 12.6, 14.3))
    stage(yaw: -0.2 + span(t, 12, 14.5) * 0.05, pitch: 0.06, zoom: 1 + span(t, 12, 14.5) * 0.08, enter: span(t, 12, 12.55)) {
        let live = span(t, 12.5, 12.65)
        if live > 0 {
            let border = NSBezierPath(rect: CGRect(x: 4, y: 4, width: designSize.width - 8, height: designSize.height - 8))
            border.lineWidth = 6
            red.withAlphaComponent(live).setStroke()
            border.stroke()
            let pill = CGRect(x: 738, y: 18, width: 132, height: 40)
            rounded(pill, 20, NSColor.black.withAlphaComponent(0.85))
            red.withAlphaComponent(live * (0.65 + 0.35 * sin(t * 8))).setFill()
            NSBezierPath(ovalIn: CGRect(x: pill.minX + 14, y: pill.minY + 12, width: 16, height: 16)).fill()
            text(String(format: "0:%02d", Int(max(t - 12.5, 0) * 3)), 19, .semibold, .white, at: CGPoint(x: pill.minX + 42, y: pill.minY + 9), mono: true)
        }
        cursor(at: CGPoint(x: mix(300, 700, travel), y: mix(140, 306, travel) - sin(travel * .pi) * 60), scale: 1.3)
    }
}

/// 14.5 a 16: el video se vuelve imágenes.
func sceneMoments(_ t: CGFloat) {
    headline("05", "Claude lo ve.", "Cada video, en imágenes con su minuto.", start: 14.5, end: 16, t, size: 104)
    let grid = layer(CGSize(width: 1200, height: 760), scale: 1.3) {
        let moments = ["0:00", "0:02", "0:04", "0:06", "0:08", "0:10"]
        let cell = CGSize(width: 384, height: 240)
        for (index, moment) in moments.enumerated() {
            let rect = CGRect(x: 8 + CGFloat(index % 3) * 396, y: 130 + CGFloat(index / 3) * 252, width: cell.width, height: cell.height)
            let pop = easeBack(span(t, 14.55 + CGFloat(index) * 0.075, 14.9 + CGFloat(index) * 0.075))
            guard pop > 0 else { continue }
            scaled(pop, around: CGPoint(x: rect.midX, y: rect.midY)) {
                ctx.saveGState()
                ctx.translateBy(x: rect.minX, y: rect.minY)
                appContent(cell) {
                    let step = CGFloat(index) / 5
                    cursor(at: CGPoint(x: mix(280, 700, step), y: mix(120, 306, step)), scale: 2.8)
                }
                ctx.restoreGState()
                let label = CGRect(x: rect.minX + 12, y: rect.minY + 12, width: 88, height: 38)
                rounded(label, 9, NSColor.black.withAlphaComponent(0.85))
                text(moment, 21, .bold, .white, at: CGPoint(x: label.midX, y: label.minY + 7), align: .center, mono: true)
            }
        }
    }
    let image = grid
    ctx.saveGState()
    tiltedPlain(image, center: stageCenter, size: CGSize(width: 1040, height: 659), yaw: -0.18, pitch: 0.05, zoom: 1 + span(t, 14.5, 16) * 0.05)
    ctx.restoreGState()
}

/// Igual que `tilted`, sin el bloque de sombra: la imagen tiene partes transparentes.
func tiltedPlain(_ image: CGImage, center: CGPoint, size: CGSize, yaw: CGFloat, pitch: CGFloat, zoom: CGFloat) {
    let focal: CGFloat = 2100
    func project(_ x: CGFloat, _ y: CGFloat) -> CIVector {
        let x1 = x * cos(yaw)
        let z1 = -x * sin(yaw)
        let y2 = y * cos(pitch) - z1 * sin(pitch)
        let z2 = y * sin(pitch) + z1 * cos(pitch)
        let s = focal / (focal + z2) * zoom
        return CIVector(x: center.x + x1 * s, y: H - (center.y + y2 * s))
    }
    let halfW = size.width / 2
    let halfH = size.height / 2
    guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return }
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    filter.setValue(project(-halfW, -halfH), forKey: "inputTopLeft")
    filter.setValue(project(halfW, -halfH), forKey: "inputTopRight")
    filter.setValue(project(halfW, halfH), forKey: "inputBottomRight")
    filter.setValue(project(-halfW, halfH), forKey: "inputBottomLeft")
    guard let output = filter.outputImage, let result = imageContext.createCGImage(output, from: output.extent) else { return }
    let extent = output.extent
    let rect = CGRect(x: extent.minX, y: H - extent.maxY, width: extent.width, height: extent.height)
    ctx.saveGState()
    ctx.translateBy(x: 0, y: rect.minY * 2 + rect.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(result, in: rect)
    ctx.restoreGState()
}

/// 16 a 18: pegar.
func scenePaste(_ t: CGFloat) {
    headline("06", "Pégalo.", "Directo en Claude Code.", start: 16, end: 18, t)
    keycaps(["Ctrl", "V"], origin: CGPoint(x: 96, y: 610), start: 16.25, t)
    let size = CGSize(width: 1240, height: 560)
    let shown = CGSize(width: 1080, height: 488)
    let image = layer(size) {
        rounded(CGRect(origin: .zero, size: size), 18, NSColor(srgbRed: 0.075, green: 0.075, blue: 0.095, alpha: 1))
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 24 + CGFloat(index) * 26, y: 22, width: 15, height: 15)).fill()
        }
        text("$ claude", 32, .medium, NSColor(white: 1, alpha: 0.6), at: CGPoint(x: 48, y: 104), mono: true)
        let box = CGRect(x: 44, y: 330, width: size.width - 88, height: 110)
        stroked(box, 14, NSColor(white: 1, alpha: 0.32), 2)
        var x = box.minX + 26
        let y = box.minY + 33
        x += text(">", 32, .semibold, yellow, at: CGPoint(x: x, y: y), mono: true).width + 20
        let chip = easeBack(span(t, 16.5, 16.8))
        if chip > 0 {
            let rect = CGRect(x: x, y: y - 4, width: 216, height: 50)
            scaled(chip, around: CGPoint(x: rect.midX, y: rect.midY)) {
                rounded(rect, 10, yellow)
                text("[Image #1]", 29, .bold, ink, at: CGPoint(x: rect.minX + 16, y: rect.minY + 7), mono: true)
            }
            x += rect.width + 20
        }
        let sentence = "¿Por qué no guarda?"
        let typed = String(sentence.prefix(Int(CGFloat(sentence.count) * span(t, 16.85, 17.6))))
        if t > 16.8 {
            let measured = text(typed, 32, .regular, .white, at: CGPoint(x: x, y: y), mono: true)
            if sin(t * 9) > -0.2 {
                yellow.setFill()
                CGRect(x: x + measured.width + 3, y: y + 2, width: 15, height: 36).fill()
            }
        }
    }
    let settle = expoOut(span(t, 16, 16.55))
    tilted(
        image,
        center: CGPoint(x: stageCenter.x + (1 - settle) * 460, y: 540),
        size: shown,
        yaw: -0.17 - (1 - settle) * 0.5,
        pitch: 0.05,
        zoom: 1 + span(t, 16, 18) * 0.05
    )
}

/// 18 a 20: el texto se selecciona sobre la imagen, con el azul del sistema.
func sceneLiveText(_ t: CGFloat) {
    headline("07", "Toma el texto.", "Sobre la imagen. Se copia solo.", start: 18, end: 20, t, size: 92)
    stage(yaw: -0.18, pitch: 0.05, zoom: 1 + span(t, 18, 20) * 0.06, enter: span(t, 18, 18.5)) {
        let sweep = easeInOut(span(t, 18.5, 19.4))
        let row = CGRect(x: 236, y: 298, width: 600 * sweep, height: 28)
        if sweep > 0 {
            NSColor.systemBlue.withAlphaComponent(0.32).setFill()
            NSBezierPath(roundedRect: row, xRadius: 4, yRadius: 4).fill()
        }
        cursor(at: CGPoint(x: row.maxX, y: row.midY), scale: 1.3)
    }
    let badge = easeBack(span(t, 19.4, 19.75))
    if badge > 0 {
        let pill = CGRect(x: 96, y: 620, width: 250, height: 62)
        scaled(badge, around: CGPoint(x: pill.midX, y: pill.midY)) {
            rounded(pill, 31, yellow)
            symbol("checkmark", CGRect(x: pill.minX + 24, y: pill.minY + 18, width: 26, height: 26), ink)
            text("Texto copiado", 25, .bold, ink, at: CGPoint(x: pill.minX + 60, y: pill.minY + 15))
        }
    }
}

/// 20 a 26: lo demás, a golpe de compás.
func sceneMontage(_ t: CGFloat) {
    let tiles: [(String, String, String)] = [
        ("arrow.up.and.down", "Desplaza", "páginas enteras en una imagen"),
        ("pause.circle", "Congela", "menús y todo lo que se mueve"),
        ("timer", "3 segundos", "para abrir lo que necesites"),
        ("highlighter", "Resalta", "como un marcador de verdad"),
        ("scope", "Enfoca", "lo demás se oscurece"),
        ("square.grid.3x3.square", "Censura", "con recuadro o pincel"),
        ("photo.on.rectangle", "Presenta", "fondos listos para compartir"),
        ("scissors", "Recorta", "tus videos al instante"),
        ("speaker.wave.2", "Con sonido", "el del Mac y tu voz"),
        ("clock", "Historial", "nada se pierde"),
        ("arrow.clockwise", "Repite", "la misma área, con un atajo"),
        ("lock", "Solo en tu Mac", "nada sale de tu equipo"),
    ]
    let index = min(Int((t - 20) / 0.5), tiles.count - 1)
    let local = (t - 20) - CGFloat(index) * 0.5
    let tile = tiles[index]
    let pop = expoOut(span(local, 0, 0.22))
    scaled(0.9 + pop * 0.1 + local * 0.05, around: CGPoint(x: W / 2, y: H / 2)) {
        glow(CGPoint(x: W / 2, y: 330), 460, yellow, 0.14)
        symbol(tile.0, CGRect(x: W / 2 - 75, y: 240, width: 150, height: 150), yellow)
        text(tile.1, 118, .heavy, .white, at: CGPoint(x: W / 2, y: 460), align: .center)
        text(tile.2, 42, .medium, NSColor(white: 0.72, alpha: 1), at: CGPoint(x: W / 2, y: 626), align: .center)
    }
}

/// 26 a 30: cierre.
func sceneEnd(_ t: CGFloat) {
    let local = t - 26
    glow(CGPoint(x: W / 2, y: 400), 800, yellow, 0.1 + (1 - span(local, 0, 0.7)) * 0.4)
    logo(center: CGPoint(x: W / 2, y: 350), size: 240, span(local, 0, 0.7))
    reveal("Zas", 118, at: CGPoint(x: W / 2, y: 496), align: .center, start: 26.25, end: 40, t)
    reveal("Tu pantalla, lista para Claude.", 50, .semibold, at: CGPoint(x: W / 2, y: 652), align: .center, start: 26.6, end: 40, t, top: NSColor(white: 0.95, alpha: 1), bottom: NSColor(white: 0.75, alpha: 1))
    let link = expoOut(span(local, 1, 1.5))
    withAlpha(link) {
        let pill = CGRect(x: W / 2 - 370, y: 766 + (1 - link) * 30, width: 740, height: 74)
        rounded(pill, 37, yellow)
        text("github.com/GitHubnotoficial/Zas", 35, .bold, ink, at: CGPoint(x: W / 2, y: pill.minY + 16), align: .center)
    }
}

let scenes: [(start: CGFloat, end: CGFloat, draw: (CGFloat) -> Void)] = [
    (0, 4, sceneHook),
    (4, 6, sceneLogo),
    (6, 8, sceneSelect),
    (8, 10, sceneCopied),
    (10, 12, sceneAnnotate),
    (12, 14.5, sceneRecord),
    (14.5, 16, sceneMoments),
    (16, 18, scenePaste),
    (18, 20, sceneLiveText),
    (20, 26, sceneMontage),
    (26, 30.1, sceneEnd),
]

func renderFrame(_ t: CGFloat) {
    background(t)
    // Temblor corto en cada golpe de la música.
    var shakeX: CGFloat = 0
    var shakeY: CGFloat = 0
    for hit in impacts where t >= hit && t < hit + 0.4 {
        let force = pow(1 - (t - hit) / 0.4, 2) * 15
        shakeX += sin(t * 91) * force
        shakeY += cos(t * 73) * force
    }
    ctx.saveGState()
    ctx.translateBy(x: shakeX, y: shakeY)
    for scene in scenes where t >= scene.start && t < scene.end {
        // Entrada y salida con empuje de cámara, en vez de un fundido plano.
        let enter = expoOut(span(t, scene.start, scene.start + 0.3))
        let leave = expoIn(span(t, scene.end - 0.14, scene.end))
        let last = scene.end > 30
        let zoom = (scene.start == 0 ? 1 : mix(0.965, 1, enter)) * (last ? 1 : 1 + leave * 0.09)
        withAlpha((last ? 1 : 1 - leave) * (scene.start == 0 ? 1 : min(enter * 2, 1))) {
            scaled(zoom, around: CGPoint(x: W / 2, y: H / 2)) {
                scene.draw(t)
            }
        }
    }
    ctx.restoreGState()
    vignette()
    let fade = span(t, 29.3, 30)
    if fade > 0 {
        NSColor.black.withAlphaComponent(fade).setFill()
        CGRect(x: 0, y: 0, width: W, height: H).fill()
    }
}

// MARK: - Sonido

let sampleRate = 44100
let audioSeconds = 30.0
let sampleCount = Int(audioSeconds * Double(sampleRate))
var music = [Float](repeating: 0, count: sampleCount * 2)
var drums = [Float](repeating: 0, count: sampleCount * 2)
var wet = [Float](repeating: 0, count: sampleCount)
var noiseState: UInt32 = 22_222

func noise() -> Float {
    noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
    return Float(noiseState >> 8) / 8_388_608 - 1
}

func put(_ bus: inout [Float], _ index: Int, _ left: Float, _ right: Float) {
    guard index >= 0, index < sampleCount else { return }
    bus[index * 2] += left
    bus[index * 2 + 1] += right
}

func kick(_ at: Double, _ level: Float = 0.95) {
    let start = Int(at * Double(sampleRate))
    var phase = 0.0
    for i in 0..<Int(0.32 * Double(sampleRate)) {
        let time = Double(i) / Double(sampleRate)
        let frequency = 46 + 130 * exp(-time * 34)
        phase += 2 * .pi * frequency / Double(sampleRate)
        let click = i < 90 ? noise() * 0.18 * Float(1 - Double(i) / 90) : 0
        let value = (Float(sin(phase)) * Float(exp(-time * 8.5)) + click) * level
        put(&drums, start + i, value, value)
    }
}

func clap(_ at: Double, _ level: Float = 0.34) {
    let start = Int(at * Double(sampleRate))
    var low: Float = 0
    for i in 0..<Int(0.16 * Double(sampleRate)) {
        let time = Double(i) / Double(sampleRate)
        let burst = time < 0.03 ? Float(0.6 + 0.4 * sin(time * 900)) : Float(exp(-(time - 0.03) * 24))
        let raw = noise()
        low += 0.3 * (raw - low)
        let value = (raw - low) * burst * level
        put(&drums, start + i, value, value)
        if start + i < sampleCount { wet[start + i] += value * 0.6 }
    }
}

func hat(_ at: Double, _ level: Float) {
    let start = Int(at * Double(sampleRate))
    var previous: Float = 0
    for i in 0..<Int(0.05 * Double(sampleRate)) {
        let raw = noise()
        let high = raw - previous
        previous = raw
        let value = high * Float(exp(-Double(i) / Double(sampleRate) * 95)) * level
        put(&drums, start + i, value * 0.8, value)
    }
}

func tone(_ at: Double, _ frequency: Double, length: Double, level: Float, pan: Float, decay: Double, bright: Float = 0.3, send: Float = 0.3) {
    let start = Int(at * Double(sampleRate))
    for i in 0..<Int(length * Double(sampleRate)) {
        let time = Double(i) / Double(sampleRate)
        let phase = 2 * .pi * frequency * time
        let attack = Float(min(time / 0.004, 1))
        let body = Float(sin(phase)) + bright * Float(sin(phase * 2)) + bright * 0.4 * Float(sin(phase * 3))
        let value = body * attack * Float(exp(-time * decay)) * level
        put(&music, start + i, value * (1 - pan), value * (1 + pan))
        if start + i < sampleCount { wet[start + i] += value * send }
    }
}

func pad(_ at: Double, _ length: Double, _ notes: [Double], level: Float) {
    let start = Int(at * Double(sampleRate))
    for i in 0..<Int(length * Double(sampleRate)) {
        let time = Double(i) / Double(sampleRate)
        let envelope = Float(min(time / 0.35, 1) * min((length - time) / 0.35, 1))
        var left: Float = 0
        var right: Float = 0
        for note in notes {
            for harmonic in 1...4 {
                let strength = Float(1 / Double(harmonic * harmonic))
                left += Float(sin(2 * .pi * note * 0.998 * Double(harmonic) * time)) * strength
                right += Float(sin(2 * .pi * note * 1.002 * Double(harmonic) * time)) * strength
            }
        }
        let scale = envelope * level / Float(notes.count)
        put(&music, start + i, left * scale, right * scale)
        if start + i < sampleCount { wet[start + i] += (left + right) * scale * 0.15 }
    }
}

func sweep(_ at: Double, _ length: Double, rising: Bool, level: Float) {
    let start = Int(at * Double(sampleRate))
    var low: Float = 0
    for i in 0..<Int(length * Double(sampleRate)) {
        let progress = Double(i) / (length * Double(sampleRate))
        let shape = rising ? progress * progress * progress : sin(progress * .pi)
        let cutoff = Float(0.015 + (rising ? progress * progress : shape) * 0.42)
        low += cutoff * (noise() - low)
        let value = low * Float(shape) * level
        put(&music, start + i, value, value)
        if start + i < sampleCount { wet[start + i] += value * 0.5 }
    }
}

func impact(_ at: Double, _ level: Float = 1) {
    kick(at, 1.1 * level)
    let start = Int(at * Double(sampleRate))
    var low: Float = 0
    for i in 0..<Int(1.6 * Double(sampleRate)) {
        let time = Double(i) / Double(sampleRate)
        low += 0.05 * (noise() - low)
        let boom = Float(sin(2 * .pi * 41 * time)) * Float(exp(-time * 2.6)) * 0.75
        let value = (boom + low * 1.8 * Float(exp(-time * 4.5))) * level
        put(&drums, start + i, value, value)
        if start + i < sampleCount { wet[start + i] += low * Float(exp(-time * 3)) * 0.7 * level }
    }
}

func key(_ at: Double) {
    tone(at, 2400, length: 0.03, level: 0.1, pan: 0, decay: 170, bright: 0, send: 0.25)
    hat(at, 0.3)
}

func shutter(_ at: Double) {
    hat(at, 0.75)
    hat(at + 0.055, 0.6)
    tone(at, 900, length: 0.06, level: 0.13, pan: 0, decay: 70, bright: 0.1, send: 0.3)
}

func composeAudio() {
    let bar = 2.0
    let chords: [[Double]] = [
        [110, 130.81, 164.81, 196], // La menor 7
        [87.31, 130.81, 174.61, 220], // Fa mayor 7
        [130.81, 164.81, 196, 246.94], // Do mayor 7
        [98, 146.83, 196, 246.94], // Sol
    ]
    let roots = [55.0, 43.65, 65.41, 49.0]
    let scale = [440.0, 523.25, 587.33, 659.25, 783.99, 880, 1046.5]
    let pattern = [0, 2, 4, 3, 5, 4, 2, 6, 1, 4, 3, 5, 0, 3, 4, 2]

    // Introducción: acordes solos y una subida hacia el golpe.
    pad(0, 2, chords[0], level: 0.11)
    pad(2, 2, chords[3], level: 0.13)
    sweep(0.8, 3.2, rising: true, level: 0.75)
    for step in stride(from: 2.5, to: 4, by: 0.25) {
        kick(step, 0.22 + Float((step - 2.5) * 0.17))
    }

    // Cuerpo, de 4 a 20 segundos.
    for (index, start) in stride(from: 4.0, to: 26, by: bar).enumerated() {
        pad(start, bar, chords[index % 4], level: 0.13)
        for eighth in 0..<8 {
            let at = start + Double(eighth) * 0.25
            let root = roots[index % 4]
            tone(at, root, length: 0.22, level: 0.2, pan: 0, decay: 7, bright: 0.5, send: 0)
            hat(at, start >= 6 ? (eighth % 2 == 1 ? 0.11 : 0.05) : 0)
        }
        for beat in 0..<4 {
            kick(start + Double(beat) * 0.5)
            if start >= 6, beat % 2 == 1 {
                clap(start + Double(beat) * 0.5)
            }
        }
        if start >= 6 {
            for sixteenth in 0..<16 {
                let note = scale[pattern[(sixteenth + index * 3) % 16]]
                let pan: Float = sixteenth % 2 == 0 ? -0.35 : 0.35
                tone(start + Double(sixteenth) * 0.125, note, length: 0.28, level: 0.05, pan: pan, decay: 12, bright: 0.2, send: 0.6)
            }
        }
    }

    // Cierre: un solo acorde que se apaga.
    pad(26, 3.7, [55, 110, 164.81, 220, 261.63, 329.63], level: 0.17)
    for (index, note) in [880.0, 1046.5, 1318.5, 1760].enumerated() {
        tone(26 + Double(index) * 0.25, note, length: 1.4, level: 0.075, pan: index % 2 == 0 ? -0.3 : 0.3, decay: 3, bright: 0.15, send: 0.8)
    }

    // Efectos, en el mismo instante que la imagen.
    for hit in [4.0, 8.0, 16.5, 26.0] {
        impact(hit, hit == 4 || hit == 26 ? 1 : 0.55)
    }
    for at in [5.8, 7.8, 9.8, 11.8, 14.3, 15.8, 17.8, 19.8, 25.7] {
        sweep(at, 0.3, rising: true, level: 0.3)
    }
    for at in [6.25, 6.35, 6.45, 12.25, 12.35, 12.45, 16.25, 16.35] {
        key(at)
    }
    shutter(8)
    sweep(8.04, 0.55, rising: false, level: 0.28)
    for at in [10.5, 11.0, 11.5] {
        sweep(at, 0.34, rising: false, level: 0.2)
    }
    tone(12.5, 1318.5, length: 0.2, level: 0.12, pan: 0, decay: 16, bright: 0.2, send: 0.5)
    for index in 0..<6 {
        tone(14.55 + Double(index) * 0.075, 659.25 * pow(2, Double(index) / 12 * 2), length: 0.16, level: 0.08, pan: Float(index % 3) * 0.3 - 0.3, decay: 18, bright: 0.25, send: 0.5)
    }
    for index in 0..<11 {
        key(16.9 + Double(index) * 0.065)
    }
    for at in stride(from: 20.0, to: 26, by: 0.5) {
        sweep(at, 0.2, rising: false, level: 0.22)
    }
    for index in 0..<9 {
        key(18.5 + Double(index) * 0.1)
    }
    tone(19.4, 1318.5, length: 0.24, level: 0.12, pan: 0, decay: 14, bright: 0.2, send: 0.5)

    mixAudio()
}

func mixAudio() {
    // La música baja un instante en cada bombo, como en una mezcla de club.
    var duck = [Float](repeating: 1, count: sampleCount)
    for start in stride(from: 4.0, to: 26, by: 0.5) {
        let first = Int(start * Double(sampleRate))
        for i in 0..<Int(0.42 * Double(sampleRate)) where first + i < sampleCount {
            let time = Double(i) / Double(sampleRate)
            duck[first + i] = min(duck[first + i], 1 - 0.62 * Float(exp(-time * 10)))
        }
    }

    // Reverberación: cuatro ecos cortos que se realimentan.
    var reverb = [Float](repeating: 0, count: sampleCount * 2)
    for (index, delay) in [1557, 1617, 1491, 1422, 1277, 1356].enumerated() {
        var line = [Float](repeating: 0, count: delay * 3)
        var cursor = 0
        for i in 0..<sampleCount {
            let output = line[cursor]
            line[cursor] = wet[i] + output * 0.82
            cursor = (cursor + 1) % line.count
            reverb[i * 2 + index % 2] += output * 0.14
        }
    }

    var peak: Float = 0
    var energy: Float = 0
    var master = [Float](repeating: 0, count: sampleCount * 2)
    for i in 0..<sampleCount {
        let fade = Float(min((audioSeconds - Double(i) / Double(sampleRate)) / 1.0, 1))
        for side in 0..<2 {
            let index = i * 2 + side
            let dry = music[index] * duck[i] + drums[index] * 0.85 + reverb[index]
            let value = tanh(dry * 1.15) * 0.9 * fade
            master[index] = value
            peak = max(peak, abs(value))
            energy += value * value
        }
    }
    print(String(format: "audio: pico %.2f, nivel medio %.3f", peak, sqrt(energy / Float(sampleCount * 2))))

    // WAV de 16 bits.
    var data = Data()
    func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let byteCount = UInt32(sampleCount * 4)
    data.append(contentsOf: Array("RIFF".utf8))
    append(36 + byteCount)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(2))
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 4))
    append(UInt16(4))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(byteCount)
    data.reserveCapacity(44 + Int(byteCount))
    for value in master {
        let sample = Int16(max(min(value, 1), -1) * 32_000)
        withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }
    try! data.write(to: output.appendingPathComponent("musica.wav"))
}

// MARK: - Video

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let silent = output.appendingPathComponent("imagen.mp4")
let movie = output.appendingPathComponent("zas-promo.mp4")
try? FileManager.default.removeItem(at: silent)
try? FileManager.default.removeItem(at: movie)

composeAudio()

let writer = try! AVAssetWriter(outputURL: silent, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 9_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    ] as [String: Any],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

// Grano fino: evita las bandas en los degradados oscuros y le da textura de cine.
let grain: CGImage = {
    let side = 512
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    var state: UInt32 = 77
    for i in 0..<side * side {
        state = state &* 1_664_525 &+ 1_013_904_223
        let value = UInt8(state >> 24)
        bytes[i * 4] = value
        bytes[i * 4 + 1] = value
        bytes[i * 4 + 2] = value
        bytes[i * 4 + 3] = 255
    }
    let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}()

let sheetTimes: [CGFloat] = [1.6, 4.9, 7.4, 9.2, 11.8, 13.6, 15.5, 17.7, 19.6, 20.3, 23.3, 28.2]
var sheetImages: [CGImage] = []
let totalFrames = Int(duration) * fps
let subContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
subContext.translateBy(x: 0, y: H)
subContext.scaleBy(x: 1, y: -1)
let started = Date()

for frame in 0..<totalFrames {
    let t = CGFloat(frame) / CGFloat(fps)
    autoreleasepool {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { fatalError("sin memoria para el cuadro") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let target = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!

        // Desenfoque de movimiento real: varios instantes por cuadro, promediados.
        for sample in 0..<subframes {
            let moment = t + CGFloat(sample) / CGFloat(subframes) * 0.5 / CGFloat(fps)
            ctx = subContext
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: subContext, flipped: true)
            renderFrame(moment)
            NSGraphicsContext.restoreGraphicsState()
            guard let image = subContext.makeImage() else { continue }
            target.setAlpha(1 / CGFloat(sample + 1))
            target.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        }

        target.setAlpha(0.05)
        target.setBlendMode(.overlay)
        let offset = CGPoint(x: -CGFloat((frame * 137) % 512), y: -CGFloat((frame * 211) % 512))
        for column in 0..<6 {
            for row in 0..<4 {
                target.draw(grain, in: CGRect(x: offset.x + CGFloat(column) * 512, y: offset.y + CGFloat(row) * 512, width: 512, height: 512))
            }
        }

        if sheetTimes.contains(where: { abs($0 - t) < 0.5 / CGFloat(fps) }), let image = target.makeImage() {
            sheetImages.append(image)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData {
            usleep(2000)
        }
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
    if frame % 120 == 0 {
        print(String(format: "cuadro %d de %d, %.0f s", frame, totalFrames, Date().timeIntervalSince(started)))
    }
}

input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()
print("imagen: \(writer.status == .completed ? "lista" : "FALLO \(String(describing: writer.error))")")

// Une imagen y sonido.
let converter = Process()
let wavFile = output.appendingPathComponent("musica.wav")
let aacFile = output.appendingPathComponent("musica.m4a")
try? FileManager.default.removeItem(at: aacFile)
converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
converter.arguments = ["-f", "m4af", "-d", "aac", "-b", "256000", wavFile.path, aacFile.path]
try! converter.run()
converter.waitUntilExit()

func track(_ asset: AVURLAsset, _ type: AVMediaType) -> AVAssetTrack {
    let semaphore = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var track: AVAssetTrack? }
    let box = Box()
    asset.loadTracks(withMediaType: type) { tracks, _ in
        box.track = tracks?.first
        semaphore.signal()
    }
    semaphore.wait()
    return box.track!
}

let videoAsset = AVURLAsset(url: silent)
let audioAsset = AVURLAsset(url: aacFile)
let composition = AVMutableComposition()
let range = CMTimeRange(start: .zero, duration: CMTime(value: CMTimeValue(totalFrames), timescale: CMTimeScale(fps)))
let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
try! videoTrack.insertTimeRange(range, of: track(videoAsset, .video), at: .zero)
try! audioTrack.insertTimeRange(range, of: track(audioAsset, .audio), at: .zero)

let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
exporter.outputURL = movie
exporter.outputFileType = .mp4
let exported = DispatchSemaphore(value: 0)
exporter.exportAsynchronously { exported.signal() }
exported.wait()
print("video: \(exporter.status == .completed ? "listo" : "FALLO \(String(describing: exporter.error))")")

// Hoja de revisión con doce momentos.
let cellWidth = 480
let cellHeight = 270
let sheet = CGContext(data: nil, width: cellWidth * 4, height: cellHeight * 3, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for (index, image) in sheetImages.enumerated() {
    sheet.draw(image, in: CGRect(x: (index % 4) * cellWidth, y: (2 - index / 4) * cellHeight, width: cellWidth, height: cellHeight))
}
if let image = sheet.makeImage() {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("hoja.png"))
}
try? FileManager.default.removeItem(at: silent)
exit(exporter.status == .completed ? 0 : 1)

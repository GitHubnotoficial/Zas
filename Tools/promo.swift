// Video promocional de Zas: cada cuadro se dibuja aquí, sin capturas ni plantillas.
// La interfaz que aparece es una animación basada en la app, no una grabación.
// Uso: promo <carpeta-de-salida>
import AVFoundation
import AppKit

let width = 1920
let height = 1080
let W = CGFloat(width)
let H = CGFloat(height)
let fps = 30
let duration: CGFloat = 24

let yellow = NSColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1)
let ink = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)
let red = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)

var ctx: CGContext!

// MARK: - Tiempo

func span(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
    min(max((t - a) / (b - a), 0), 1)
}

func easeOut(_ x: CGFloat) -> CGFloat { 1 - pow(1 - x, 3) }
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

@discardableResult
func text(
    _ string: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
    at point: CGPoint, align: Align = .left, mono: Bool = false
) -> CGSize {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font,
        .foregroundColor: color,
        .kern: mono ? 0 : -size * 0.015,
    ])
    let measured = attributed.size()
    var x = point.x
    if align == .center { x -= measured.width / 2 }
    if align == .right { x -= measured.width }
    attributed.draw(at: CGPoint(x: x, y: point.y))
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

// MARK: - Fondo y títulos

func background(_ t: CGFloat) {
    let colors = [
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.13, alpha: 1).cgColor,
        NSColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: W * 0.3, y: H), options: [.drawsAfterEndLocation])

    let x = W * 0.5 + cos(t * 0.5) * 520
    let y = H * 0.45 + sin(t * 0.7) * 240
    let glow = [yellow.withAlphaComponent(0.13).cgColor, yellow.withAlphaComponent(0).cgColor] as CFArray
    let radial = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glow, locations: [0, 1])!
    ctx.drawRadialGradient(radial, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: 760, options: [])
}

func caption(_ string: String, _ local: CGFloat, y: CGFloat = 72) {
    let show = easeOut(span(local, 0.1, 0.55))
    withAlpha(show) {
        text(string, 62, .bold, .white, at: CGPoint(x: W / 2, y: y + (1 - show) * 26), align: .center)
    }
}

func keycaps(_ keys: [String], center: CGPoint, start: CGFloat, _ t: CGFloat) {
    let size: CGFloat = 92
    let gap: CGFloat = 14
    let total = CGFloat(keys.count) * size + CGFloat(keys.count - 1) * gap
    for (index, key) in keys.enumerated() {
        let local = span(t, start + CGFloat(index) * 0.09, start + CGFloat(index) * 0.09 + 0.4)
        guard local > 0 else { continue }
        // Las teclas se hunden un instante cuando se pulsa el atajo.
        let press = span(t, start + 0.55, start + 0.65) - span(t, start + 0.65, start + 0.85)
        let x = center.x - total / 2 + CGFloat(index) * (size + gap)
        let rect = CGRect(x: x, y: center.y - size / 2 + press * 7, width: size, height: size)
        scaled(easeBack(local), around: CGPoint(x: rect.midX, y: rect.midY)) {
            withAlpha(local) {
                shadow(26, 12, 0.5) {
                    rounded(rect, 18, NSColor(white: 0.97, alpha: 1))
                }
                let fontSize: CGFloat = key.count > 1 ? 30 : 46
                text(key, fontSize, .semibold, ink, at: CGPoint(x: rect.midX, y: rect.midY - fontSize * 0.62), align: .center)
            }
        }
    }
}

// MARK: - Logo

func logo(center: CGPoint, size: CGFloat, _ progress: CGFloat, _ flash: CGFloat = 0) {
    let box = easeBack(span(progress, 0, 0.42))
    guard box > 0 else { return }
    let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)

    scaled(box, around: center) {
        shadow(size * 0.2, size * 0.08, 0.6) {
            rounded(rect, size * 0.225, NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1))
        }
        stroked(rect.insetBy(dx: 1, dy: 1), size * 0.225, NSColor(white: 1, alpha: 0.12), 2)

        // Las esquinas del visor se trazan una a una.
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
            let drawn = easeOut(span(progress, 0.25 + CGFloat(index) * 0.06, 0.5 + CGFloat(index) * 0.06))
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

        // El rayo entra de golpe.
        let bolt = easeBack(span(progress, 0.55, 0.8))
        if bolt > 0 {
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

    if flash > 0 {
        withAlpha(flash * (1 - flash) * 4 * 0.5) {
            let burst = rect.insetBy(dx: -size * flash * 0.9, dy: -size * flash * 0.9)
            stroked(burst, size * 0.3 + size * flash, yellow, 6)
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

func appWindow(_ rect: CGRect, overlay: (() -> Void)? = nil) {
    shadow(60, 30, 0.55) {
        rounded(rect, 16, NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
    }
    ctx.saveGState()
    NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).addClip()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: rect.width / designSize.width, y: rect.height / designSize.height)

    NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
    CGRect(origin: .zero, size: designSize).fill()
    NSColor(srgbRed: 0.13, green: 0.15, blue: 0.22, alpha: 1).setFill()
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

let windowRect = CGRect(x: 360, y: 250, width: 1200, height: 640)

func designToScreen(_ rect: CGRect, in window: CGRect) -> CGRect {
    let sx = window.width / designSize.width
    let sy = window.height / designSize.height
    return CGRect(x: window.minX + rect.minX * sx, y: window.minY + rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
}

let errorRow = CGRect(x: 220, y: 284, width: 650, height: 54)

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

func cursor(at point: CGPoint, scale: CGFloat = 1.6) {
    let s = scale
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
    path.lineWidth = 1.6
    path.stroke()
}

// MARK: - Escenas

func sceneLogo(_ t: CGFloat) {
    let progress = span(t, 0.1, 1.5)
    let rise = easeInOut(span(t, 1.5, 2.1))
    logo(center: CGPoint(x: W / 2, y: H / 2 - 40 - rise * 60), size: 340, progress, span(t, 0.95, 1.5))
    let word = easeOut(span(t, 1.55, 2.1))
    withAlpha(word) {
        text("Zas", 112, .heavy, .white, at: CGPoint(x: W / 2, y: H / 2 + 150 - (1 - word) * -24), align: .center)
    }
    let tag = easeOut(span(t, 1.85, 2.4))
    withAlpha(tag) {
        text("Capturas para Mac. Al instante.", 42, .medium, NSColor(white: 1, alpha: 0.72), at: CGPoint(x: W / 2, y: H / 2 + 290), align: .center)
    }
}

func selectionRect(_ grow: CGFloat) -> CGRect {
    let target = designToScreen(errorRow, in: windowRect).insetBy(dx: -8, dy: -8)
    let start = CGRect(x: target.minX, y: target.minY, width: 1, height: 1)
    return mix(start, target, grow)
}

func sceneSelect(_ t: CGFloat) {
    caption("Selecciona lo que quieras.", t)
    let enter = easeOut(span(t, 0, 0.55))
    withAlpha(enter) {
        appWindow(windowRect.offsetBy(dx: 0, dy: (1 - enter) * 90))
    }
    keycaps(["⇧", "⌘", "2"], center: CGPoint(x: 1650, y: 215), start: 0.35, t)

    let dim = span(t, 0.95, 1.2)
    let grow = easeInOut(span(t, 1.35, 2.5))
    let rect = selectionRect(grow)
    if dim > 0 {
        let path = NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H))
        if grow > 0 {
            path.append(NSBezierPath(rect: rect))
            path.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.46 * dim).setFill()
        path.fill()
    }
    if grow > 0 {
        stroked(rect, 0, .white, 2.5)
        let label = "\(Int(rect.width * 1.5)) × \(Int(rect.height * 1.5))"
        let pill = CGRect(x: rect.minX, y: rect.maxY + 14, width: 170, height: 44)
        withAlpha(span(t, 1.45, 1.7)) {
            rounded(pill, 22, NSColor.black.withAlphaComponent(0.85))
            text(label, 21, .medium, .white, at: CGPoint(x: pill.midX, y: pill.minY + 9), align: .center, mono: true)
        }
    }
    let move = easeInOut(span(t, 0.8, 1.35))
    let start = CGPoint(x: 1200, y: 800)
    let target = selectionRect(0).origin
    let tip = grow > 0 ? CGPoint(x: rect.maxX, y: rect.maxY) : CGPoint(x: mix(start.x, target.x, move), y: mix(start.y, target.y, move))
    cursor(at: tip)
}

func thumbnailCard(_ rect: CGRect, badge: String?) {
    shadow(36, 18, 0.6) {
        rounded(rect, 16, NSColor(white: 0.09, alpha: 1))
    }
    ctx.saveGState()
    NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).addClip()
    NSColor.white.setFill()
    rect.fill()
    let line = rect.height / 6
    text("Pedido 1045", line * 1.4, .regular, .darkGray, at: CGPoint(x: rect.minX + rect.width * 0.05, y: rect.minY + line * 1.9))
    text("Error al guardar", line * 1.4, .medium, .systemRed, at: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + line * 1.9))
    ctx.restoreGState()
    stroked(rect.insetBy(dx: 0.5, dy: 0.5), 15.5, NSColor(white: 1, alpha: 0.25), 1)
}

func sceneCopied(_ t: CGFloat) {
    caption("Ya está copiada. Solo pega.", t)
    appWindow(windowRect)
    let source = selectionRect(1)
    let target = CGRect(x: 1400, y: 760, width: 460, height: 150)
    let fly = easeInOut(span(t, 0.28, 0.95))

    let dim = 1 - span(t, 0.1, 0.4)
    if dim > 0 {
        let path = NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H))
        path.append(NSBezierPath(rect: source))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.46 * dim).setFill()
        path.fill()
    }
    let flash = 1 - span(t, 0, 0.25)
    if flash > 0 {
        rounded(source, 0, NSColor.white.withAlphaComponent(flash * 0.85))
    }

    let card = mix(source, target, fly)
    thumbnailCard(card, badge: nil)

    let badge = easeBack(span(t, 0.95, 1.3))
    if badge > 0 {
        let pill = CGRect(x: target.minX + 16, y: target.maxY - 58, width: 170, height: 44)
        scaled(badge, around: CGPoint(x: pill.midX, y: pill.midY)) {
            rounded(pill, 22, yellow)
            symbol("checkmark", CGRect(x: pill.minX + 16, y: pill.minY + 11, width: 22, height: 22), ink)
            text("Copiado", 22, .bold, ink, at: CGPoint(x: pill.minX + 46, y: pill.minY + 8))
        }
    }
    keycaps(["⌘", "V"], center: CGPoint(x: 330, y: 830), start: 1.25, t)
}

func sceneAnnotate(_ t: CGFloat) {
    caption("Márcalo en dos segundos.", t)
    let enter = easeOut(span(t, 0, 0.45))
    let bar: CGFloat = 78
    let frame = CGRect(x: 360, y: 210, width: 1200, height: 770)
    let image = CGRect(x: frame.minX, y: frame.minY + bar, width: frame.width, height: frame.height - bar)

    withAlpha(enter) {
        shadow(60, 30, 0.55) {
            rounded(frame.offsetBy(dx: 0, dy: (1 - enter) * 70), 16, NSColor(white: 0.96, alpha: 1))
        }
    }
    ctx.saveGState()
    ctx.translateBy(x: 0, y: (1 - enter) * 70)
    withAlpha(enter) {
        let toolbar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: bar)
        let symbols = ["cursorarrow", "arrow.up.right", "rectangle", "circle", "highlighter", "scribble", "textformat", "1.circle", "checkerboard.rectangle", "crop"]
        for (index, name) in symbols.enumerated() {
            let box = CGRect(x: toolbar.minX + 120 + CGFloat(index) * 52, y: toolbar.midY - 22, width: 44, height: 44)
            let active = (index == 1 && t < 2.1) || (index == 2 && t >= 2.1)
            if active { rounded(box, 10, .systemBlue) }
            symbol(name, box.insetBy(dx: 11, dy: 11), active ? .white : NSColor(white: 0.2, alpha: 1))
        }
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen, .systemBlue].enumerated() {
            let dot = CGRect(x: toolbar.minX + 680 + CGFloat(index) * 40, y: toolbar.midY - 12, width: 24, height: 24)
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        let copy = CGRect(x: toolbar.maxX - 142, y: toolbar.midY - 24, width: 116, height: 48)
        rounded(copy, 11, .systemBlue)
        text("Copiar", 23, .semibold, .white, at: CGPoint(x: copy.midX, y: copy.minY + 9), align: .center)

        ctx.saveGState()
        let clip = NSBezierPath(rect: image)
        clip.addClip()
        appWindow(image) {
            let draw = easeInOut(span(t, 0.75, 1.5))
            arrow(from: CGPoint(x: 330, y: 88), to: CGPoint(x: 628, y: 298), draw, .systemRed, width: 6)
            let box = easeInOut(span(t, 1.75, 2.35))
            if box > 0 {
                let target = CGRect(x: 628, y: 292, width: 170, height: 38)
                let rect = CGRect(x: target.minX, y: target.minY, width: target.width * box, height: target.height * box)
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                path.lineWidth = 4.5
                NSColor.systemRed.setStroke()
                path.stroke()
            }
            let note = easeBack(span(t, 2.45, 2.85))
            if note > 0 {
                let origin = CGPoint(x: 268, y: 58)
                scaled(note, around: origin) {
                    text("Esto debería guardar", 22, .bold, .systemRed, at: origin)
                }
            }
        }
        ctx.restoreGState()

        let press = easeOut(span(t, 3.2, 3.5))
        if press > 0 {
            stroked(copy.insetBy(dx: -6 * press, dy: -6 * press), 14, yellow.withAlphaComponent(1 - press * 0.4), 4)
        }
    }
    ctx.restoreGState()
}

func sceneVideo(_ t: CGFloat) {
    let toGrid = span(t, 2.0, 2.3)
    if t < 2.0 {
        caption("Graba lo que está pasando.", t)
    } else {
        caption("Zas lo convierte en imágenes para Claude.", t - 2.0)
    }

    withAlpha(1 - toGrid) {
        let enter = easeOut(span(t, 0, 0.45))
        withAlpha(enter) {
            appWindow(windowRect)
        }
        keycaps(["⇧", "⌘", "6"], center: CGPoint(x: 1650, y: 215), start: 0.2, t)

        let live = span(t, 0.6, 0.8)
        if live > 0 {
            stroked(windowRect.insetBy(dx: -8, dy: -8), 20, red.withAlphaComponent(live), 5)
            let pulse = 0.65 + 0.35 * sin(t * 8)
            let pill = CGRect(x: 760, y: 186, width: 190, height: 50)
            rounded(pill, 25, NSColor.black.withAlphaComponent(0.85 * live))
            red.withAlphaComponent(pulse * live).setFill()
            NSBezierPath(ovalIn: CGRect(x: pill.minX + 20, y: pill.minY + 15, width: 20, height: 20)).fill()
            text(String(format: "0:%02d", Int(max(t - 0.6, 0) * 2.4)), 26, .semibold, .white.withAlphaComponent(live), at: CGPoint(x: pill.minX + 56, y: pill.minY + 9), mono: true)
        }
        let travel = easeInOut(span(t, 0.7, 1.9))
        cursor(at: CGPoint(x: mix(620, 1290, travel), y: mix(430, 700, travel) - sin(travel * .pi) * 110))
    }

    guard t >= 2.1 else { return }
    let columns = 3
    let cell = CGSize(width: 440, height: 268)
    let gap: CGFloat = 26
    let originX = (W - CGFloat(columns) * cell.width - CGFloat(columns - 1) * gap) / 2
    let moments = ["0:00", "0:02", "0:04", "0:06", "0:08", "0:10"]
    for (index, moment) in moments.enumerated() {
        let row = index / columns
        let column = index % columns
        let rect = CGRect(
            x: originX + CGFloat(column) * (cell.width + gap),
            y: 215 + CGFloat(row) * (cell.height + gap),
            width: cell.width,
            height: cell.height
        )
        let pop = easeBack(span(t, 2.2 + CGFloat(index) * 0.12, 2.6 + CGFloat(index) * 0.12))
        guard pop > 0 else { continue }
        scaled(pop, around: CGPoint(x: rect.midX, y: rect.midY)) {
            appWindow(rect) {
                // El cursor avanza de un momento al siguiente, como en un video real.
                let step = CGFloat(index) / 5
                cursor(at: CGPoint(x: mix(280, 700, step), y: mix(120, 300, step)), scale: 2.6)
            }
            let label = CGRect(x: rect.minX + 12, y: rect.minY + 12, width: 92, height: 42)
            rounded(label, 10, NSColor.black.withAlphaComponent(0.84))
            text(moment, 23, .bold, .white, at: CGPoint(x: label.midX, y: label.minY + 8), align: .center, mono: true)
        }
    }
}

func sceneTerminal(_ t: CGFloat) {
    caption("Pégala en Claude Code.", t)
    let enter = easeOut(span(t, 0, 0.45))
    let frame = CGRect(x: 360, y: 240, width: 1200, height: 560)
    withAlpha(enter) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: (1 - enter) * 70)
        shadow(60, 30, 0.6) {
            rounded(frame, 16, NSColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1))
        }
        stroked(frame.insetBy(dx: 0.5, dy: 0.5), 16, NSColor(white: 1, alpha: 0.14), 1)
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: frame.minX + 24 + CGFloat(index) * 26, y: frame.minY + 22, width: 15, height: 15)).fill()
        }
        text("Terminal", 20, .medium, NSColor(white: 1, alpha: 0.5), at: CGPoint(x: frame.midX, y: frame.minY + 17), align: .center)
        text("$ claude", 32, .medium, NSColor(white: 1, alpha: 0.62), at: CGPoint(x: frame.minX + 48, y: frame.minY + 96), mono: true)

        let box = CGRect(x: frame.minX + 44, y: frame.minY + 330, width: frame.width - 88, height: 110)
        stroked(box, 14, NSColor(white: 1, alpha: 0.3), 2)
        var x = box.minX + 26
        let y = box.minY + 33
        x += text(">", 32, .semibold, yellow, at: CGPoint(x: x, y: y), mono: true).width + 20

        let chip = easeBack(span(t, 1.15, 1.5))
        if chip > 0 {
            let rect = CGRect(x: x, y: y - 4, width: 216, height: 50)
            scaled(chip, around: CGPoint(x: rect.midX, y: rect.midY)) {
                rounded(rect, 10, yellow)
                text("[Image #1]", 29, .bold, ink, at: CGPoint(x: rect.minX + 16, y: rect.minY + 7), mono: true)
            }
            x += rect.width + 20
        }
        let sentence = "¿Por qué no guarda este pedido?"
        let typed = Int(CGFloat(sentence.count) * span(t, 1.65, 2.8))
        let shown = String(sentence.prefix(typed))
        if chip >= 1 || t > 1.5 {
            let size = text(shown, 32, .regular, .white, at: CGPoint(x: x, y: y), mono: true)
            if sin(t * 9) > -0.2 {
                yellow.setFill()
                CGRect(x: x + size.width + 3, y: y + 2, width: 15, height: 36).fill()
            }
        }
        ctx.restoreGState()
    }
    keycaps(["Ctrl", "V"], center: CGPoint(x: W / 2, y: 900), start: 0.55, t)
}

func sceneEnd(_ t: CGFloat) {
    logo(center: CGPoint(x: W / 2, y: 380), size: 280, span(t, 0.1, 1.1), span(t, 0.65, 1.1))
    let word = easeOut(span(t, 0.8, 1.25))
    withAlpha(word) {
        text("Zas", 104, .heavy, .white, at: CGPoint(x: W / 2, y: 548 + (1 - word) * 24), align: .center)
    }
    let tag = easeOut(span(t, 1.05, 1.5))
    withAlpha(tag) {
        text("Hecha para Mac. Pensada para trabajar con Claude.", 42, .medium, NSColor(white: 1, alpha: 0.75), at: CGPoint(x: W / 2, y: 692), align: .center)
    }
    let link = easeOut(span(t, 1.35, 1.8))
    withAlpha(link) {
        let pill = CGRect(x: W / 2 - 390, y: 790, width: 780, height: 78)
        rounded(pill, 39, yellow)
        text("github.com/GitHubnotoficial/Zas", 37, .bold, ink, at: CGPoint(x: W / 2, y: 809), align: .center)
    }
}

let scenes: [(start: CGFloat, end: CGFloat, draw: (CGFloat) -> Void)] = [
    (0, 3.2, sceneLogo),
    (3.2, 6.9, sceneSelect),
    (6.9, 9.6, sceneCopied),
    (9.6, 13.6, sceneAnnotate),
    (13.6, 18.0, sceneVideo),
    (18.0, 21.2, sceneTerminal),
    (21.2, duration, sceneEnd),
]

func renderFrame(_ t: CGFloat) {
    background(t)
    for scene in scenes where t >= scene.start && t < scene.end + 0.28 {
        let fadeIn = span(t, scene.start, scene.start + 0.28)
        let fadeOut = 1 - span(t, scene.end, scene.end + 0.28)
        let finalFade = scene.end == duration ? 1 - span(t, duration - 0.5, duration) : 1
        let alpha = (scene.start == 0 ? 1 : fadeIn) * fadeOut * finalFade
        withAlpha(alpha) {
            scene.draw(t - scene.start)
        }
    }
}

// MARK: - Video

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let movie = output.appendingPathComponent("zas-promo.mp4")
try? FileManager.default.removeItem(at: movie)

let writer = try! AVAssetWriter(outputURL: movie, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 10_000_000,
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

let sheetTimes: [CGFloat] = [1.2, 2.9, 5.6, 8.9, 13.2, 15.2, 17.4, 20.8, 23.2]
var sheetImages: [CGImage] = []
let totalFrames = Int(duration) * fps
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

for frame in 0..<totalFrames {
    let t = CGFloat(frame) / CGFloat(fps)
    autoreleasepool {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { fatalError("sin memoria para el cuadro") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // Arriba a la izquierda, como en un diseño, para no pensar al revés.
        context.translateBy(x: 0, y: H)
        context.scaleBy(x: 1, y: -1)
        ctx = context
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        renderFrame(t)
        NSGraphicsContext.restoreGraphicsState()

        if sheetTimes.contains(where: { abs($0 - t) < 0.5 / CGFloat(fps) }), let image = context.makeImage() {
            sheetImages.append(image)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData {
            usleep(2000)
        }
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
}

input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()
print("video: \(writer.status == .completed ? "listo" : "FALLO \(String(describing: writer.error))")")

// Hoja de revisión con nueve momentos.
let cellWidth = 640
let cellHeight = 360
let sheet = CGContext(data: nil, width: cellWidth * 3, height: cellHeight * 3, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for (index, image) in sheetImages.enumerated() {
    let x = (index % 3) * cellWidth
    let y = (2 - index / 3) * cellHeight
    sheet.draw(image, in: CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
}
if let image = sheet.makeImage() {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("hoja.png"))
}
exit(writer.status == .completed ? 0 : 1)

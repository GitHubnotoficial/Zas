import AppKit

/// Resultado de añadir un tramo.
struct ScrollStep: @unchecked Sendable {
    let stitcher: ScrollStitcher
    let added: Bool
    let preview: CGImage?
}

/// Une tramos de una pantalla que se desplaza hacia abajo en una sola imagen larga.
/// Compara filas de píxeles para encontrar cuánto se movió el contenido entre dos tramos.
struct ScrollStitcher {
    private(set) var pieces: [CGImage] = []
    private var lastRows: [UInt64] = []
    private let maximumHeight = 30_000
    /// Filas fijas abajo, como una barra o un cuadro de texto: se añaden una sola vez al final.
    private var footerRows = 0
    private var lastImage: CGImage?
    /// El contenido saltó más que un tramo completo: hay que volver un poco atrás.
    private(set) var lostTrack = false

    var height: Int { pieces.reduce(0) { $0 + $1.height } }
    var width: Int { pieces.first?.width ?? 0 }

    /// Compara filas y escribe imágenes largas: nada de esto debe correr en el hilo principal.
    static func advanced(_ stitcher: ScrollStitcher, adding url: URL, previewWidth: Int, previewHeight: Int) async -> ScrollStep {
        let box = Unchecked(value: stitcher)
        return await Task.detached(priority: .userInitiated) { () -> ScrollStep in
            var current = box.value
            guard let image = Capture.image(at: url) else {
                return ScrollStep(stitcher: current, added: false, preview: nil)
            }
            let added = current.add(image)
            let preview = added ? current.tailPreview(width: previewWidth, maxHeight: previewHeight) : nil
            return ScrollStep(stitcher: current, added: added, preview: preview)
        }.value
    }

    /// Une todo y lo guarda. `scale` son los pixeles por punto. Devuelve el tamaño en puntos.
    static func save(_ stitcher: ScrollStitcher, to url: URL, scale: CGFloat) async -> CGSize? {
        let box = Unchecked(value: stitcher)
        return await Task.detached(priority: .userInitiated) { () -> CGSize? in
            guard let image = box.value.composed() else { return nil }
            let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            return Capture.writePNG(image, to: url, pointSize: size) ? size : nil
        }.value
    }

    /// Devuelve `true` si entró contenido nuevo.
    @discardableResult
    mutating func add(_ image: CGImage) -> Bool {
        let rows = Self.rowHashes(image)
        guard !pieces.isEmpty else {
            pieces.append(image)
            lastRows = rows
            lastImage = image
            return true
        }
        guard image.width == width, height < maximumHeight, rows.count == lastRows.count else { return false }
        if rows == lastRows { return false }

        let (top, bottom) = Self.staticBands(lastRows, rows)
        let previous = Array(lastRows[top..<(rows.count - bottom)])
        let next = Array(rows[top..<(rows.count - bottom)])
        guard let shift = Self.shift(from: previous, to: next), shift > 0 else {
            lostTrack = true
            return false
        }
        let cut = CGRect(x: 0, y: rows.count - bottom - shift, width: image.width, height: shift)
        guard let slice = Self.copy(image, cut) else { return false }
        lostTrack = false
        footerRows = bottom
        pieces.append(slice)
        lastRows = rows
        lastImage = image
        return true
    }

    /// Filas iguales arriba y abajo en dos tramos: no se mueven al desplazar.
    static func staticBands(_ a: [UInt64], _ b: [UInt64]) -> (top: Int, bottom: Int) {
        let limit = a.count / 2
        var top = 0
        while top < limit, a[top] == b[top] { top += 1 }
        var bottom = 0
        while bottom < limit, a[a.count - 1 - bottom] == b[b.count - 1 - bottom] { bottom += 1 }
        return (top, bottom)
    }

    /// Copia independiente: un recorte normal retiene en memoria el tramo entero.
    private static func copy(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        guard let crop = image.cropping(to: rect) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context?.makeImage()
    }

    /// Cuántas filas subió el contenido. `nil` si los tramos no se parecen.
    static func shift(from previous: [UInt64], to next: [UInt64]) -> Int? {
        guard previous.count == next.count, previous.count > 16 else { return nil }
        if previous == next { return 0 }
        let count = previous.count
        var best: (shift: Int, score: Double)?
        for shift in 1..<(count - 8) {
            let overlap = count - shift
            var matches = 0
            for row in 0..<overlap where previous[row + shift] == next[row] {
                matches += 1
            }
            let score = Double(matches) / Double(overlap)
            if score >= 0.9, score > (best?.score ?? 0) {
                best = (shift, score)
            }
        }
        return best?.shift
    }

    static func rowHashes(_ image: CGImage) -> [UInt64] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { row in
            var hash: UInt64 = 14_695_981_039_346_656_037
            var column = 0
            while column < bytesPerRow {
                let index = row * bytesPerRow + column
                hash = (hash ^ UInt64(pixels[index])) &* 1_099_511_628_211
                hash = (hash ^ UInt64(pixels[index + 1])) &* 1_099_511_628_211
                hash = (hash ^ UInt64(pixels[index + 2])) &* 1_099_511_628_211
                column += 16
            }
            return hash
        }
    }

    func composed() -> CGImage? {
        guard let first = pieces.first else { return nil }
        // El pie del primer tramo se quita: va una sola vez, al final de todo.
        var parts = pieces
        if footerRows > 0, pieces.count > 1,
           let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - footerRows)) {
            parts[0] = trimmed
            if let last = lastImage,
               let footer = last.cropping(to: CGRect(x: 0, y: last.height - footerRows, width: last.width, height: footerRows)) {
                parts.append(footer)
            }
        }
        let total = parts.reduce(0) { $0 + $1.height }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var top = total
        for piece in parts {
            top -= piece.height
            context.draw(piece, in: CGRect(x: 0, y: top, width: piece.width, height: piece.height))
        }
        return context.makeImage()
    }
}

extension ScrollStitcher {
    /// Lo último que se unió, reducido a `targetWidth` píxeles de ancho. Solo dibuja los tramos
    /// que caben en `maxHeight`, así que una imagen de treinta mil filas cuesta lo mismo que una corta.
    func tailPreview(width targetWidth: Int, maxHeight: Int) -> CGImage? {
        guard width > 0, targetWidth > 0, maxHeight > 0, !pieces.isEmpty else { return nil }
        let scale = CGFloat(targetWidth) / CGFloat(width)
        let targetHeight = min(max(Int((CGFloat(height) * scale).rounded()), 1), maxHeight)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        var bottom: CGFloat = 0
        for piece in pieces.reversed() {
            let pieceHeight = CGFloat(piece.height) * scale
            context.draw(piece, in: CGRect(x: 0, y: bottom, width: CGFloat(targetWidth), height: pieceHeight))
            bottom += pieceHeight
            if bottom >= CGFloat(targetHeight) { break }
        }
        return context.makeImage()
    }
}

/// Dónde van los controles de la captura con desplazamiento, en coordenadas de AppKit.
/// Se evita pisar la selección: lo que esté dentro de ella podría acabar en la imagen.
enum ScrollHUDLayout {
    /// Misma barra que el selector: margen, radio y botones de sus medidas.
    static let barSize = CGSize(width: 202, height: Design.actionSize + Design.barPadding * 2)
    static let previewWidth: CGFloat = 148
    static let previewMaxHeight: CGFloat = 300
    static let margin: CGFloat = 18

    /// Abajo y centrada. Si la selección llega hasta ahí, se busca arriba y luego a los lados.
    static func barFrame(selection: CGRect, visible: CGRect) -> CGRect {
        let centered = (visible.midX - barSize.width / 2).rounded()
        let bottom = visible.minY + margin
        let origins = [
            CGPoint(x: centered, y: bottom),
            CGPoint(x: centered, y: visible.maxY - margin - barSize.height),
            CGPoint(x: selection.maxX + margin, y: bottom),
            CGPoint(x: selection.minX - margin - barSize.width, y: bottom),
        ]
        let candidates = origins.map { CGRect(origin: $0, size: barSize) }
        let free = candidates.first { visible.contains($0) && !$0.intersects(selection) }
        return free ?? candidates[0]
    }

    /// A la izquierda de la selección, apoyada abajo para crecer hacia arriba.
    static func previewFrame(height: CGFloat, selection: CGRect, visible: CGRect) -> CGRect {
        let size = CGSize(width: previewWidth, height: min(max(height, 1), previewMaxHeight))
        let left = selection.minX - margin - size.width
        let right = selection.maxX + margin
        let x: CGFloat
        if left >= visible.minX + margin {
            x = left
        } else if right + size.width <= visible.maxX - margin {
            x = right
        } else {
            x = visible.minX + margin
        }
        let lowest = max(selection.minY, visible.minY + margin)
        let y = min(lowest, visible.maxY - margin - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// Botón de texto de la barra. `Listo` es la acción principal y lleva el acento.
private final class ScrollBarButton: ReactiveButton {
    private let isPrimary: Bool

    init(frame: CGRect, title: String, hint: String, isPrimary: Bool, target: AnyObject, action: Selector) {
        self.isPrimary = isPrimary
        super.init(frame: frame)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isPrimary ? .semibold : .regular),
            .foregroundColor: isPrimary ? Palette.onAccent : NSColor.labelColor,
        ])
        toolTip = hint
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = Design.barRadius - Design.barPadding
        layer?.cornerCurve = .continuous
        setAccessibilityLabel(title)
        setAccessibilityHelp(hint)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func reactiveStateChanged() {
        refresh()
    }

    private func refresh() {
        let fill: NSColor
        if isPrimary {
            fill = isPressed ? Palette.accent.withAlphaComponent(0.75) : Palette.accent
        } else {
            fill = isPressed ? .tertiaryLabelColor : (isHovering ? .quaternaryLabelColor : .clear)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
    }
}

/// Lo que se ve mientras se desplaza: Cancelar y Listo, y la imagen que va creciendo.
@MainActor
final class ScrollCaptureHUD: NSObject {
    /// Ancho y alto máximo de la vista previa en píxeles: el doble de sus puntos, para Retina.
    static let previewPixelWidth = Int(ScrollHUDLayout.previewWidth * 2)
    static let previewPixelHeight = Int(ScrollHUDLayout.previewMaxHeight * 2)

    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    private let selection: CGRect
    private let visible: CGRect
    private let bar: NSPanel
    private let preview: NSPanel
    private let imageView = NSImageView()

    /// Con `hiddenFromCapture` no sale en los tramos. Las escenas de prueba lo apagan para verse.
    init(selection: CGRect, screen: NSScreen, hiddenFromCapture: Bool = true) {
        let visible = screen.visibleFrame
        self.selection = selection
        self.visible = visible
        bar = ScrollCaptureHUD.makePanel(
            frame: ScrollHUDLayout.barFrame(selection: selection, visible: visible),
            hiddenFromCapture: hiddenFromCapture
        )
        preview = ScrollCaptureHUD.makePanel(
            frame: ScrollHUDLayout.previewFrame(height: 1, selection: selection, visible: visible),
            hiddenFromCapture: hiddenFromCapture
        )
        super.init()
        buildBar()
        buildPreview()
    }

    private static func makePanel(frame: CGRect, hiddenFromCapture: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if hiddenFromCapture {
            panel.sharingType = .none
        }
        return panel
    }

    private func buildBar() {
        bar.hasShadow = true
        let size = ScrollHUDLayout.barSize
        let padding = Design.barPadding
        let buttonHeight = size.height - padding * 2
        let doneWidth: CGFloat = 76
        let glass = GlassView(frame: CGRect(origin: .zero, size: size), radius: Design.barRadius)

        let cancel = ScrollBarButton(
            frame: CGRect(x: padding, y: padding, width: size.width - padding * 3 - doneWidth, height: buttonHeight),
            title: "Cancelar",
            hint: "Descarta la captura (Esc)",
            isPrimary: false,
            target: self,
            action: #selector(cancelPressed)
        )
        glass.addSubview(cancel)
        let done = ScrollBarButton(
            frame: CGRect(x: size.width - padding - doneWidth, y: padding, width: doneWidth, height: buttonHeight),
            title: "Listo",
            hint: "Termina y une la captura (Enter)",
            isPrimary: true,
            target: self,
            action: #selector(donePressed)
        )
        glass.addSubview(done)
        bar.contentView = glass
    }

    private func buildPreview() {
        preview.hasShadow = true
        preview.ignoresMouseEvents = true
        imageView.frame = CGRect(origin: .zero, size: preview.frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Design.controlRadius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = Design.lineWidth
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        imageView.setAccessibilityElement(true)
        imageView.setAccessibilityRole(.image)
        imageView.setAccessibilityLabel("Vista previa de la captura")
        preview.contentView = imageView
    }

    func show() {
        bar.alphaValue = 0
        bar.orderFrontRegardless()
        fade(bar)
    }

    /// `image` ya viene reducida: ver `ScrollStitcher.tailPreview`.
    func update(preview image: CGImage) {
        let scale = ScrollHUDLayout.previewWidth / max(CGFloat(image.width), 1)
        let height = CGFloat(image.height) * scale
        imageView.image = NSImage(
            cgImage: image,
            size: CGSize(width: ScrollHUDLayout.previewWidth, height: height)
        )
        preview.setFrame(
            ScrollHUDLayout.previewFrame(height: height, selection: selection, visible: visible),
            display: true
        )
        if !preview.isVisible {
            preview.alphaValue = 0
            preview.orderFrontRegardless()
            fade(preview)
        }
        preview.invalidateShadow()
    }

    func close() {
        bar.orderOut(nil)
        preview.orderOut(nil)
    }

    /// Solo aparece: no viaja, así que no hay nada que quitar con Reducir movimiento.
    private func fade(_ panel: NSPanel) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = Design.fadeDuration
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    @objc private func donePressed() {
        onDone?()
    }
}

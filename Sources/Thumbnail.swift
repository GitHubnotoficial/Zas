@preconcurrency import AVFoundation
import AppKit
import UniformTypeIdentifiers

extension Design {
    /// Tarjetas y controles que flotan sobre ellas. Van sobre una captura: como en Vista Rápida,
    /// son un HUD oscuro con texto blanco en los dos modos.
    enum Card {
        static let radius = Design.radiusMedium
        static let pillSize = CGSize(width: 64, height: 22)
        static let circleSize = CGSize(width: 20, height: 20)
        static let rowButton = CGSize(width: 28, height: 24)
        static let playSize = CGSize(width: 36, height: 36)
        static let gap: CGFloat = 6
        /// Aire a cada lado cuando un aviso no cabe en la píldora.
        static let pillPadding: CGFloat = 8
        static let titleSize: CGFloat = 12
        static let symbolSize: CGFloat = 10
        static let rowSymbolSize: CGFloat = 14
        /// Más baja que esto, Copiar y Guardar van uno junto al otro.
        static let shortHeight: CGFloat = 110
        /// Más baja que esto, un video no tiene sitio para sus píldoras bajo el botón de reproducir.
        static let videoShortHeight: CGFloat = 140
        static let outlineWidth: CGFloat = 2
        /// Controles de las capturas fijadas, que no llevan material.
        static let controlFill = NSColor.black.withAlphaComponent(0.55)
        static let controlHover = NSColor.black.withAlphaComponent(0.7)
        static let controlPressed = NSColor.black.withAlphaComponent(0.8)
        static let ink = NSColor.white
        static let hoverWash = NSColor.white.withAlphaComponent(0.12)
        static let pressedWash = NSColor.white.withAlphaComponent(0.2)
        static let veil = NSColor.black.withAlphaComponent(0.3)
        /// Filo interior: separa la tarjeta de una captura del mismo color que el fondo.
        static let rim = NSColor.white.withAlphaComponent(0.12)
        /// Sombra propia, más suave y amplia que la del sistema.
        static let shadowColor = NSColor.black
        static let shadowOpacity: Float = 0.28
        static let shadowRadius: CGFloat = 14
        static let shadowDrop: CGFloat = 6
        /// Sitio alrededor de la tarjeta para que la sombra se apague antes del borde del panel.
        static let shadowRoom: CGFloat = 44
    }
}

enum ThumbnailKind {
    case screenshot
    case video
    case text
}

/// Solo pinta la sombra de una tarjeta. Va en una capa propia: AppKit gobierna la sombra
/// de la capa de una vista y descartaría estos valores.
private final class CardShadowView: NSView {
    private let shape = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.shadowColor = Design.Card.shadowColor.cgColor
        shape.shadowOpacity = Design.Card.shadowOpacity
        shape.shadowRadius = Design.Card.shadowRadius
        shape.shadowOffset = CGSize(width: 0, height: -Design.Card.shadowDrop)
        layer?.addSublayer(shape)
        refreshShape()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshShape()
    }

    private func refreshShape() {
        let room = Design.Card.shadowRoom
        let radius = Design.Card.radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.shadowPath = CGPath(
            roundedRect: bounds.insetBy(dx: room, dy: room),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        CATransaction.commit()
    }
}

/// Panel de una tarjeta. Recibe el gesto de dos dedos aunque nunca sea la ventana activa.
/// La sombra del sistema no se puede ablandar, y agrandar el panel se quedaría los clics de
/// alrededor: por eso va en un panel aparte, debajo de todas las tarjetas, que deja pasar el ratón.
private final class CardPanel: NSPanel {
    var onSwipe: ((NSEvent) -> Void)?

    private var shadowPanel: NSPanel?

    func attachShadow() {
        let shadow = NSPanel(
            contentRect: shadowFrame(for: frame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        shadow.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        shadow.isOpaque = false
        shadow.backgroundColor = .clear
        shadow.hasShadow = false
        shadow.hidesOnDeactivate = false
        shadow.isReleasedWhenClosed = false
        shadow.ignoresMouseEvents = true
        shadow.animationBehavior = .none
        shadow.collectionBehavior = collectionBehavior
        let view = CardShadowView(frame: CGRect(origin: .zero, size: shadow.frame.size))
        view.autoresizingMask = [.width, .height]
        shadow.contentView = view
        shadowPanel = shadow
    }

    private func shadowFrame(for card: CGRect) -> CGRect {
        card.insetBy(dx: -Design.Card.shadowRoom, dy: -Design.Card.shadowRoom)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        shadowPanel?.setFrame(shadowFrame(for: frameRect), display: flag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        shadowPanel?.setFrame(shadowFrame(for: frame), display: true)
    }

    override func orderFrontRegardless() {
        shadowPanel?.orderFrontRegardless()
        super.orderFrontRegardless()
    }

    override func orderOut(_ sender: Any?) {
        shadowPanel?.orderOut(sender)
        super.orderOut(sender)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, event.hasPreciseScrollingDeltas, event.momentumPhase == [] {
            onSwipe?(event)
            return
        }
        super.sendEvent(event)
    }
}

/// Pila de tarjetas en la esquina inferior del lado elegido en Ajustes. Cada captura nueva
/// entra abajo y empuja a las demás, para poder sacar varias seguidas y arrastrarlas o editarlas después.
@MainActor
final class ThumbnailController {
    var onAnnotate: ((NSImage, URL) -> Void)?
    var onPin: ((NSImage) -> Void)?
    var onSummarize: ((URL) -> Void)?
    var onSelectText: ((NSImage, URL) -> Void)?
    var onTrim: ((URL) -> Void)?
    var onGif: ((URL) -> Void)?

    private final class Item: @unchecked Sendable {
        let panel: CardPanel
        let view: ThumbnailView
        var timer: Timer?
        var spring: Timer?
        var swipeOffset: CGFloat = 0
        var swipeVelocity: CGFloat = 0
        var swipeTime = Date()
        /// El contorno espera a que la tarjeta se vea: mientras se captura, la pila está escondida.
        var outlinePending = false

        init(panel: CardPanel, view: ThumbnailView) {
            self.panel = panel
            self.view = view
        }
    }

    private let width: CGFloat = 224
    private let maximumItems = 4

    private var items: [Item] = []
    /// Tarjetas saliendo por el borde: también deben esconderse si llega otra captura.
    private var leaving: [NSPanel] = []
    private var isSuspended = false
    private var screen: NSScreen?

    /// `source` es el sitio de la pantalla de donde salió la captura: la tarjeta nace ahí.
    func show(
        image: NSImage,
        file: URL,
        kind: ThumbnailKind,
        text: String? = nil,
        inClipboard: Bool = true,
        from source: CGRect? = nil,
        preview: NSImage? = nil
    ) {
        screen = NSScreen.underMouse

        let imageSize = image.size
        let aspect = max(imageSize.width, 1) / max(imageSize.height, 1)
        // La tarjeta toma la forma de la captura para no dejar bandas. Sus límites dejan sitio a las acciones.
        let height = min(max((width / aspect).rounded(), 84), 168)
        let size = CGSize(width: min(max((height * aspect).rounded(), 160), width), height: height)

        let panel = CardPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.attachShadow()

        let view = ThumbnailView(
            frame: CGRect(origin: .zero, size: size),
            image: image,
            preview: preview,
            file: file,
            kind: kind,
            text: text
        )
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        let item = Item(panel: panel, view: view)
        panel.onSwipe = { [weak self, weak item] event in
            guard let self, let item else { return }
            self.handleSwipe(event, on: item)
        }
        view.onClose = { [weak self, weak item] in
            guard let item else { return }
            self?.dismiss(item)
        }
        view.onAnnotate = { [weak self, weak item] in
            guard let self, let item else { return }
            self.dismiss(item)
            self.onAnnotate?(image, file)
        }
        view.onSelectText = { [weak self, weak item] in
            guard let self, let item else { return }
            self.dismiss(item)
            self.onSelectText?(image, file)
        }
        view.onPin = { [weak self, weak item] in
            guard let self, let item else { return }
            self.dismiss(item)
            self.onPin?(image)
        }
        view.onHoldChanged = { [weak self, weak item] holding in
            guard let self, let item else { return }
            if holding {
                self.stopTimer(item)
            } else {
                self.startTimer(item)
            }
        }
        view.onCopy = { [weak self, weak item] in
            guard let self, let item else { return }
            self.markCopied(item)
        }
        view.onCopyPath = { [weak self, weak item] in
            guard let self, let item else { return }
            Capture.copyText(file.path)
            self.items.forEach { $0.view.isInClipboard = false }
            Sounds.play(.copy)
            item.view.flashCopied("Ruta copiada")
        }
        view.onSummarize = { [weak self] in
            self?.onSummarize?(file)
        }
        view.onTrim = { [weak self] in
            self?.onTrim?(file)
        }
        view.onGif = { [weak self] in
            self?.onGif?(file)
        }
        view.onReleased = { [weak self] in
            self?.syncHover()
        }

        // Solo la captura más reciente está en el portapapeles y lleva el contorno.
        items.forEach {
            $0.view.isInClipboard = false
            $0.outlinePending = false
            $0.view.clearOutline()
        }
        view.isInClipboard = inClipboard
        item.outlinePending = true

        items.insert(item, at: 0)
        while items.count > maximumItems, let oldest = items.last {
            dismiss(oldest, animated: false)
        }

        let target = frames()[0]
        let outside = (target.width + Design.edgeMargin) * outwardSign(of: target)
        let start = source.flatMap { $0.width >= 24 && $0.height >= 24 ? $0 : nil }
            ?? target.offsetBy(dx: outside, dy: 0)
        // Con Reducir movimiento no hay vuelo: la tarjeta aparece en su sitio con un fundido.
        panel.setFrame(Design.reduceMotion ? target : start, display: false)
        if !isSuspended {
            panel.orderFrontRegardless()
            if Design.reduceMotion {
                fadeIn(panel)
            }
        }
        layoutItems()
        // Mientras está escondida no corre el tiempo: se cuenta desde que se vuelva a ver.
        if !isSuspended {
            startTimer(item)
            revealOutline()
        }
    }

    private func fadeIn(_ panel: NSPanel) {
        panel.alphaValue = 0
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = Design.fadeDuration
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
    }

    /// Esconde la pila para que no salga en una captura.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        leaving.forEach { $0.orderOut(nil) }
        for item in items {
            stopTimer(item)
            item.spring?.invalidate()
            item.spring = nil
            // Una ventana escondida no recibe la salida del cursor: quedaría "con el cursor encima".
            item.view.setHovering(false)
            item.panel.orderOut(nil)
        }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for item in items {
            item.panel.orderFrontRegardless()
            startTimer(item)
        }
        layoutItems()
        revealOutline()
    }

    private func revealOutline() {
        guard let newest = items.first, newest.outlinePending else { return }
        newest.outlinePending = false
        newest.view.flashOutline()
    }

    private func markCopied(_ item: Item) {
        let view = item.view
        guard view.copyToClipboard() else {
            NSSound.beep()
            return
        }
        items.forEach { $0.view.isInClipboard = $0 === item }
        Sounds.play(.copy)
        view.flashCopied("Copiado")
    }

    /// Otra cosa entró al portapapeles: ninguna tarjeta debe decir "Copiado".
    func clipboardChanged() {
        items.forEach { $0.view.isInClipboard = false }
    }

    func dismissAll() {
        for item in items {
            dismiss(item, animated: false)
        }
    }

    private func dismiss(_ item: Item, animated: Bool = true) {
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        stopTimer(item)
        item.spring?.invalidate()
        items.remove(at: index)

        let panel = item.panel
        if animated && !isSuspended {
            slideOut(panel)
        } else {
            panel.orderOut(nil)
        }
        layoutItems()
    }

    /// -1 si el borde más cercano es el izquierdo, 1 si es el derecho.
    private func outwardSign(of frame: CGRect) -> CGFloat {
        frame.midX < (screen ?? NSScreen.underMouse).frame.midX ? -1 : 1
    }

    /// Justo fuera de la pantalla, por el borde más cercano.
    private func exitFrame(from start: CGRect) -> CGRect {
        let bounds = (screen ?? NSScreen.underMouse).frame
        let x = outwardSign(of: start) < 0 ? bounds.minX - start.width - 12 : bounds.maxX + 12
        return CGRect(x: x, y: start.minY, width: start.width, height: start.height)
    }

    /// Sale por el borde más cercano, hacia donde estaría si fuera un objeto.
    private func slideOut(_ panel: NSPanel) {
        let start = panel.frame
        let target = exitFrame(from: start)
        leaving.append(panel)
        Spring.run(response: Design.exitResponse, damping: 1, step: { progress in
            panel.setFrame(start.moved(to: target, by: progress), display: true)
        }, completion: { [weak self] in
            panel.orderOut(nil)
            self?.leaving.removeAll { $0 === panel }
        })
    }

    private func handleSwipe(_ event: NSEvent, on item: Item) {
        guard !isSuspended else { return }
        switch event.phase {
        case .began:
            beginSwipe(item)
        case .changed:
            moveSwipe(item, by: event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX)
        case .ended, .cancelled:
            endSwipe(item)
        default:
            break
        }
    }

    private func beginSwipe(_ item: Item) {
        item.spring?.invalidate()
        item.swipeOffset = 0
        item.swipeVelocity = 0
        item.swipeTime = Date()
        stopTimer(item)
    }

    /// `delta` es positivo hacia la derecha. Se acumula hacia el borde más cercano,
    /// sea cual sea: así `CardSwipe` no necesita saber de qué lado está la tarjeta.
    private func moveSwipe(_ item: Item, by delta: CGFloat) {
        guard let home = homeFrame(of: item) else { return }
        let outward = outwardSign(of: home)
        let now = Date()
        let elapsed = max(now.timeIntervalSince(item.swipeTime), 0.001)
        item.swipeVelocity = delta * outward / CGFloat(elapsed)
        item.swipeTime = now
        item.swipeOffset += delta * outward
        item.panel.setFrameOrigin(NSPoint(x: home.minX + CardSwipe.resisted(item.swipeOffset) * outward, y: home.minY))
    }

    private func endSwipe(_ item: Item) {
        if CardSwipe.shouldClose(offset: item.swipeOffset, width: item.panel.frame.width, velocity: item.swipeVelocity) {
            dismiss(item)
        } else {
            layoutItems()
            syncHover()
        }
    }

    private func homeFrame(of item: Item) -> CGRect? {
        guard let index = items.firstIndex(where: { $0 === item }) else { return nil }
        return frames()[index]
    }

    private func frames() -> [CGRect] {
        let visible = (screen ?? NSScreen.underMouse).visibleFrame
        let onLeft = Settings.shared.thumbnailsOnLeft
        var y = visible.minY + Design.edgeMargin
        return items.map { item in
            let size = item.view.cardSize
            let x = onLeft ? visible.minX + Design.edgeMargin : visible.maxX - size.width - Design.edgeMargin
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            y += size.height + Design.stackGap
            return frame
        }
    }

    private func layoutItems() {
        guard !isSuspended else { return }
        for (item, target) in zip(items, frames()) {
            let start = item.panel.frame
            guard start != target else { continue }
            item.spring?.invalidate()
            item.spring = Spring.run(step: { [weak item] progress in
                item?.panel.setFrame(start.moved(to: target, by: progress), display: true)
            })
        }
        // Al moverse bajo un cursor quieto, macOS no avisa de entradas ni salidas.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.syncHover()
        }
    }

    /// Ajusta el estado a la posición real del cursor. Sin esto, una tarjeta
    /// que perdió el aviso de salida no se cerraría nunca.
    private func syncHover() {
        guard !isSuspended else { return }
        let mouse = NSEvent.mouseLocation
        for item in items where !item.view.isHeld {
            let inside = item.panel.frame.contains(mouse)
            if inside != item.view.isHovering {
                item.view.setHovering(inside)
            }
            if inside {
                stopTimer(item)
            } else if item.timer == nil {
                startTimer(item)
            }
        }
    }

    private func startTimer(_ item: Item) {
        stopTimer(item)
        let seconds = Settings.shared.thumbnailSeconds
        item.timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item else { return }
                item.timer = nil
                if item.panel.frame.contains(NSEvent.mouseLocation) {
                    self.syncHover()
                } else {
                    self.dismiss(item)
                }
            }
        }
    }

    private func stopTimer(_ item: Item) {
        item.timer?.invalidate()
        item.timer = nil
    }

    #if ZAS_TEST
    func simulateHover(index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].view.setHovering(true)
    }

    /// Lo que pasa cuando se pierde el aviso de salida: cursor lejos, estado "encima", sin reloj.
    func simulateLostExit(index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].view.setHovering(true)
        stopTimer(items[index])
    }

    func testSyncHover() { syncHover() }
    func testIsHovering(index: Int) -> Bool { items[index].view.isHovering }
    func testHasTimer(index: Int) -> Bool { items[index].timer != nil }
    func testIsInClipboard(index: Int) -> Bool { items[index].view.isInClipboard }
    func testBadge(index: Int) -> String? { items[index].view.badgeText }
    func testActionCount(index: Int) -> Int { items[index].view.actionCount }
    func testActionLabels(index: Int) -> [String] { items[index].view.actionLabels }
    func testIsOutlined(index: Int) -> Bool { items[index].view.isOutlined }
    func testHitsButton(index: Int, at point: CGPoint) -> Bool { items[index].view.hitsButton(at: point) }
    func testHasVeil(index: Int) -> Bool { items[index].view.hasVeil }
    func testDrawnPixels(index: Int) -> Int { items[index].view.drawnPixels }
    func testSave(index: Int, to url: URL) -> Bool { items[index].view.writeCopy(to: url) }
    func testExitFrame(from frame: CGRect) -> CGRect { exitFrame(from: frame) }

    /// Un gesto completo hasta `delta`, positivo hacia la derecha. Falta soltarlo con `testEndSwipe`.
    func testSwipe(index: Int, delta: CGFloat) {
        beginSwipe(items[index])
        moveSwipe(items[index], by: delta)
    }

    func testEndSwipe(index: Int) { endSwipe(items[index]) }
    func testCopy(index: Int) { markCopied(items[index]) }
    var testFrames: [CGRect] { items.map { $0.panel.frame } }

    var visibleCount: Int { items.count }
    #endif
}

/// El contorno y el filo se pintan encima de la imagen, pero los clics los atraviesan.
private final class OutlineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Control sobre la tarjeta. Oscuro en los dos modos: se lee igual sobre cualquier captura.
private final class CardControl: ReactiveButton {
    enum Style {
        /// La acción principal, con el acento.
        case accent
        /// HUD oscuro de material.
        case material
        /// Solo el glifo, con una sombra suave para separarse de la imagen.
        case plain
    }

    private let minimumWidth: CGFloat
    private let wash = NSView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(
        title: String? = nil,
        symbol: String? = nil,
        symbolSize: CGFloat = Design.Card.symbolSize,
        label: String,
        size: CGSize,
        radius: CGFloat = Design.radiusSmall,
        style: Style,
        target: AnyObject,
        action: Selector
    ) {
        minimumWidth = size.width
        super.init(frame: CGRect(origin: .zero, size: size))
        self.title = ""
        isBordered = false
        toolTip = label
        self.target = target
        self.action = action
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous

        switch style {
        case .accent:
            layer?.backgroundColor = Palette.accent.cgColor
        case .material:
            let material = GlassView(frame: bounds, radius: radius, material: .hudWindow, blending: .withinWindow)
            material.autoresizingMask = [.width, .height]
            addSubview(material)
        case .plain:
            break
        }

        wash.frame = bounds
        wash.autoresizingMask = [.width, .height]
        wash.wantsLayer = true
        wash.layer?.cornerRadius = radius
        wash.layer?.cornerCurve = .continuous
        addSubview(wash)

        if let symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Design.Card.ink]))
            let glyph = NSImageView(frame: bounds)
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            glyph.imageScaling = .scaleNone
            glyph.autoresizingMask = [.width, .height]
            glyph.setAccessibilityElement(false)
            if style == .plain {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
                shadow.shadowBlurRadius = 2
                glyph.shadow = shadow
            }
            addSubview(glyph)
        }
        if let title {
            titleLabel.font = .systemFont(ofSize: Design.Card.titleSize, weight: style == .accent ? .semibold : .regular)
            titleLabel.textColor = Design.Card.ink
            titleLabel.setAccessibilityElement(false)
            addSubview(titleLabel)
            showTitle(title)
        }
        setAccessibilityLabel(label)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    /// Todo el botón responde, también encima de su material o de su texto.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    /// Un aviso largo, como "Ruta copiada", ensancha la píldora en vez de cortarse.
    func showTitle(_ text: String) {
        titleLabel.stringValue = text
        titleLabel.sizeToFit()
        frame.size.width = max(minimumWidth, ceil(titleLabel.frame.width) + Design.Card.pillPadding * 2)
        titleLabel.frame.origin = CGPoint(
            x: ((bounds.width - titleLabel.frame.width) / 2).rounded(),
            y: ((bounds.height - titleLabel.frame.height) / 2).rounded()
        )
    }

    override func reactiveStateChanged() {
        refresh()
    }

    private func refresh() {
        let fill: NSColor = isPressed ? Design.Card.pressedWash : (isHovering ? Design.Card.hoverWash : .clear)
        wash.layer?.backgroundColor = fill.cgColor
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    var onClose: (() -> Void)?
    var onHoldChanged: ((Bool) -> Void)?
    var onAnnotate: (() -> Void)?
    var onSelectText: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onSummarize: (() -> Void)?
    var onTrim: (() -> Void)?
    var onGif: (() -> Void)?
    /// Terminó un arrastre o el panel de guardar: hay que volver a mirar dónde está el cursor.
    var onReleased: (() -> Void)?

    var isInClipboard = false {
        didSet {
            noticeTask?.cancel()
            showsClipboardNotice = isInClipboard
            refreshBadge()
            guard isInClipboard else { return }
            noticeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled else { return }
                self?.showsClipboardNotice = false
                self?.refreshBadge()
            }
        }
    }

    let cardSize: CGSize

    private let image: NSImage
    /// Lo que se pinta: una copia pequeña. La tarjeta redibuja en cada cuadro de su resorte.
    private var shown: NSImage
    private let file: URL
    private let kind: ThumbnailKind
    private let text: String?

    private var hovering = false
    var isHovering: Bool { hovering }
    private(set) var isDragging = false
    private var isSaving = false
    /// Mientras se arrastra o se guarda, el cursor sale de la tarjeta, pero esta debe seguir ahí.
    var isHeld: Bool { isDragging || isSaving }
    private var flashText: String?
    private var mouseDownPoint: NSPoint?
    private var dragged = false
    private var trackingArea: NSTrackingArea?
    private var showsClipboardNotice = false
    private var noticeTask: Task<Void, Never>?
    private var outlineTask: Task<Void, Never>?
    private(set) var isOutlined = false
    /// Largo del video, cuando ya se leyó.
    private var durationText: String?

    /// Oscurece la captura para que los controles se lean sobre cualquier imagen. La captura se sigue viendo.
    private let veil = NSView()
    private let rim = OutlineView()
    private let outline = OutlineView()
    private let badge = GlassView(frame: .zero, radius: 9, material: .hudWindow, blending: .withinWindow)
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeIcon = NSImageView()
    /// La primera es siempre Copiar.
    private var pills: [CardControl] = []
    private var closeButton: CardControl?
    /// Fila inferior de iconos.
    private var row: [CardControl] = []
    private var playButton: CardControl?

    private var controls: [CardControl] {
        pills + [closeButton].compactMap { $0 } + row + [playButton].compactMap { $0 }
    }
    var actionCount: Int { controls.count }
    var actionLabels: [String] { controls.compactMap { $0.accessibilityLabel() } }

    init(frame: CGRect, image: NSImage, preview: NSImage?, file: URL, kind: ThumbnailKind, text: String?) {
        self.image = image
        shown = preview ?? image
        self.file = file
        self.kind = kind
        self.text = text
        cardSize = frame.size
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Design.Card.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(kind == .video ? "Video capturado" : (kind == .text ? "Texto capturado" : "Captura"))
        buildBadge()
        buildVeil()
        buildRim()
        buildControls()
        buildOutline()
        layoutCard()
        prepareImages(needsPreview: preview == nil)
        if kind == .video {
            loadDuration()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Todo clic es de la tarjeta, salvo en un botón que ya se ve. Sin esto, el velo y el
    /// aviso se quedarían el clic, y un botón aún invisible respondería por sorpresa.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hovering && hit is CardControl ? hit : self
    }

    func hitsButton(at point: CGPoint) -> Bool {
        hitTest(convert(point, to: superview)) is CardControl
    }

    // La tarjeta nace del tamaño de la selección y encoge: se recoloca a mano para no arrastrar redondeos.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutCard()
    }

    private func layoutCard() {
        veil.frame = bounds
        rim.frame = bounds
        outline.frame = bounds

        let gap = Design.Card.gap
        if let closeButton {
            closeButton.frame.origin = CGPoint(x: gap, y: bounds.height - gap - closeButton.frame.height)
        }

        let rowSize = Design.Card.rowButton
        let rowWidth = CGFloat(row.count) * rowSize.width + CGFloat(max(row.count - 1, 0)) * 2
        var x = ((bounds.width - rowWidth) / 2).rounded()
        for button in row {
            button.frame.origin = CGPoint(x: x, y: gap - 2)
            x += rowSize.width + 2
        }

        // La altura final, no la del momento: la tarjeta nace del tamaño de la selección y encoge.
        if let playButton {
            let size = playButton.frame.size
            let center = CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded())
            playButton.frame.origin = center
            if cardSize.height < Design.Card.videoShortHeight {
                placePillsInRow(endingAt: bounds.width - gap, y: bounds.height - gap - Design.Card.pillSize.height)
            } else {
                let width = pillRowWidth
                placePillsInRow(
                    endingAt: ((bounds.width + width) / 2).rounded(),
                    y: center.y - gap - Design.Card.pillSize.height
                )
            }
        } else if pills.count > 1, cardSize.height < Design.Card.shortHeight {
            let width = pillRowWidth
            placePillsInRow(
                endingAt: ((bounds.width + width) / 2).rounded(),
                y: ((bounds.height - Design.Card.pillSize.height) / 2).rounded()
            )
        } else {
            let height = pills.reduce(-gap) { $0 + $1.frame.height + gap }
            var top = ((bounds.height + height) / 2).rounded()
            for pill in pills {
                let size = pill.frame.size
                pill.frame.origin = CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: top - size.height)
                top -= size.height + gap
            }
        }
    }

    private var pillRowWidth: CGFloat {
        pills.reduce(-Design.Card.gap) { $0 + $1.frame.width + Design.Card.gap }
    }

    /// Copiar y Guardar uno junto al otro, con el último pegado a `right`.
    private func placePillsInRow(endingAt right: CGFloat, y: CGFloat) {
        var x = right - pillRowWidth
        for pill in pills {
            pill.frame.origin = CGPoint(x: x, y: y)
            x += pill.frame.width + Design.Card.gap
        }
    }

    private func buildVeil() {
        veil.wantsLayer = true
        veil.layer?.backgroundColor = Design.Card.veil.cgColor
        veil.alphaValue = 0
        addSubview(veil)
    }

    private func buildRim() {
        rim.wantsLayer = true
        rim.layer?.cornerRadius = Design.Card.radius
        rim.layer?.cornerCurve = .continuous
        rim.layer?.borderWidth = Design.lineWidth
        rim.layer?.borderColor = Design.Card.rim.cgColor
        addSubview(rim)
    }

    /// Copia pequeña para no redibujar la captura entera. Se calcula aparte: la tarjeta aparece al instante.
    private func prepareImages(needsPreview: Bool) {
        guard needsPreview, let source = shown.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let box = Unchecked(value: source)
        let size = image.size
        Task { @MainActor [weak self] in
            let small = await Task.detached(priority: .utility) {
                Unchecked(value: ImageTools.reduced(box.value, longestSide: 640))
            }.value
            guard let self, let reduced = small.value else { return }
            self.shown = NSImage(cgImage: reduced, size: size)
            self.needsDisplay = true
        }
    }

    /// Un archivo que no es un video de verdad se queda con la marca "Video".
    private func loadDuration() {
        let asset = AVURLAsset(url: file)
        Task { @MainActor [weak self] in
            guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return }
            self?.durationText = VideoSheet.timeLabel(seconds)
            self?.refreshBadge()
        }
    }

    var hasVeil: Bool { veil.layer?.backgroundColor != nil }

    /// Ancho en pixeles de lo que la tarjeta redibuja.
    var drawnPixels: Int {
        shown.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width ?? 0
    }

    private func makeRowButton(_ symbol: String, label: String, action: Selector) -> CardControl {
        CardControl(symbol: symbol, symbolSize: Design.Card.rowSymbolSize, label: label, size: Design.Card.rowButton, style: .plain, target: self, action: action)
    }

    /// En reposo no se ve nada de esto: la captura manda. El resto de opciones está en el clic derecho.
    private func buildControls() {
        pills = [CardControl(title: "Copiar", label: "Copiar", size: Design.Card.pillSize, style: .accent, target: self, action: #selector(copyAgain))]
        let circle = Design.Card.circleSize
        closeButton = CardControl(symbol: "xmark", label: "Cerrar", size: circle, radius: circle.height / 2, style: .material, target: self, action: #selector(closeCard))

        if kind != .text {
            pills.append(CardControl(title: "Guardar", label: "Guardar", size: Design.Card.pillSize, style: .material, target: self, action: #selector(saveAs)))
        }
        switch kind {
        case .screenshot:
            row = [
                makeRowButton("pin", label: "Fijar en pantalla", action: #selector(pin)),
                makeRowButton("pencil.tip", label: "Anotar", action: #selector(annotate)),
                makeRowButton("terminal", label: "Copiar ruta para un agente", action: #selector(copyPath)),
            ]
        case .video:
            row = [
                makeRowButton("pin", label: "Fijar en pantalla", action: #selector(pin)),
                makeRowButton("square.grid.2x2", label: "Copiar resumen en imágenes para Claude", action: #selector(summarize)),
                makeRowButton("terminal", label: "Copiar ruta para un agente", action: #selector(copyPath)),
            ]
            let play = Design.Card.playSize
            playButton = CardControl(symbol: "play.fill", symbolSize: Design.iconSize, label: "Reproducir", size: play, radius: play.height / 2, style: .material, target: self, action: #selector(open))
        case .text:
            break
        }

        for control in controls {
            control.alphaValue = 0
            addSubview(control)
        }
    }

    /// Por encima de todo: señala cuál es la captura recién tomada.
    private func buildOutline() {
        outline.wantsLayer = true
        outline.layer?.cornerRadius = Design.Card.radius
        outline.layer?.cornerCurve = .continuous
        outline.layer?.borderWidth = Design.Card.outlineWidth
        outline.alphaValue = 0
        addSubview(outline)
    }

    private func buildBadge() {
        badge.appearance = NSAppearance(named: .darkAqua)
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        badgeLabel.textColor = Design.Card.ink
        badge.addSubview(badgeLabel)
        badgeIcon.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [Design.Card.ink]))
            )
        badgeIcon.imageScaling = .scaleNone
        badgeIcon.setAccessibilityElement(false)
        badge.addSubview(badgeIcon)
        addSubview(badge)
        refreshBadge()
    }

    private func refreshBadge() {
        setAccessibilityValue(badgeText)
        // Con el cursor encima, el aviso se lee en la propia píldora y no tapa ningún control.
        if let copy = pills.first {
            copy.showTitle(flashText ?? "Copiar")
            layoutCard()
        }
        guard let badgeText, !hovering else {
            badge.isHidden = true
            return
        }
        badgeLabel.stringValue = badgeText
        badgeLabel.sizeToFit()
        let height: CGFloat = 18
        let side: CGFloat = 7
        // El icono acompaña al largo del video, no a los avisos.
        let showsIcon = badgeText == durationText
        let iconWidth: CGFloat = 14
        let iconRoom: CGFloat = showsIcon ? iconWidth + 3 : 0
        badge.frame = CGRect(x: 8, y: 8, width: (badgeLabel.frame.width + iconRoom + side * 2).rounded(.up), height: height)
        badgeIcon.isHidden = !showsIcon
        badgeIcon.frame = CGRect(x: side, y: 0, width: iconWidth, height: height)
        badgeLabel.frame.origin = CGPoint(x: side + iconRoom, y: ((height - badgeLabel.frame.height) / 2).rounded())
        badge.isHidden = false
    }

    /// Fundido corto: no viaja, así que también vale con Reducir movimiento.
    private func fade(_ views: [NSView], to alpha: CGFloat) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = Design.fadeDuration
        views.forEach { $0.animator().alphaValue = alpha }
        NSAnimationContext.endGrouping()
    }

    func flashOutline() {
        outlineTask?.cancel()
        outline.layer?.borderColor = Palette.accent.cgColor
        isOutlined = true
        fade([outline], to: 1)
        outlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.clearOutline()
        }
    }

    func clearOutline() {
        outlineTask?.cancel()
        guard isOutlined else { return }
        isOutlined = false
        fade([outline], to: 0)
    }

    @objc private func annotate() { onAnnotate?() }
    @objc private func pin() { onPin?() }
    @objc private func copyAgain() { onCopy?() }
    @objc private func copyPath() { onCopyPath?() }
    @objc private func summarize() { onSummarize?() }
    @objc private func closeCard() { onClose?() }
    @objc private func trim() { onTrim?() }
    @objc private func makeGif() { onGif?() }

    /// El panel no es modal: la tarjeta se queda y sigue viva hasta que se responda, aunque se cierre.
    @objc private func saveAs() {
        guard !isSaving else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: file.pathExtension) ?? .png]
        panel.directoryURL = Capture.isScratch(file) ? Capture.folder : file.deletingLastPathComponent()
        panel.nameFieldStringValue = file.lastPathComponent
        isSaving = true
        onHoldChanged?(true)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            let url = panel.url
            Task { @MainActor in
                self.isSaving = false
                if response == .OK, let url {
                    if self.writeCopy(to: url) {
                        self.flashCopied("Guardado")
                    } else {
                        Toast.shared.show("No se pudo guardar la captura.")
                    }
                }
                self.onReleased?()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Escritura atómica: si falla, un archivo que ya existía queda intacto.
    func writeCopy(to url: URL) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Vuelve a poner esta captura en el portapapeles. Sirve para pegar una de las anteriores.
    @MainActor
    func copyToClipboard() -> Bool {
        switch kind {
        case .screenshot:
            return Capture.copyImage(at: file) != nil
        case .video:
            Capture.copyFile(at: file)
            return FileManager.default.fileExists(atPath: file.path)
        case .text:
            guard let text else { return false }
            Capture.copyText(text)
            return true
        }
    }

    @MainActor
    func flashCopied(_ text: String) {
        flashText = text
        refreshBadge()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            self?.flashText = nil
            self?.refreshBadge()
        }
    }

    @objc private func open() {
        NSWorkspace.shared.open(file)
        onClose?()
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([file])
        onClose?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if kind != .text {
            let path = file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            let location = menu.addItem(withTitle: path, action: nil, keyEquivalent: "")
            location.isEnabled = false
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copiar ruta", action: #selector(copyPath), keyEquivalent: "").target = self
        }
        if kind != .text {
            menu.addItem(withTitle: "Guardar como…", action: #selector(saveAs), keyEquivalent: "").target = self
        }
        if kind != .text, !Capture.isScratch(file) {
            menu.addItem(withTitle: "Mostrar en Finder", action: #selector(reveal), keyEquivalent: "").target = self
        }
        if kind == .video {
            menu.addItem(withTitle: "Recortar video…", action: #selector(trim), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Crear GIF", action: #selector(makeGif), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Cerrar", action: #selector(closeCard), keyEquivalent: "").target = self
        return menu
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
        onHoldChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isHeld else { return }
        setHovering(false)
        onHoldChanged?(false)
    }

    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        fade([veil], to: value ? 1 : 0)
        fade(controls, to: value ? 1 : 0)
        refreshBadge()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }

        dragged = true
        isDragging = true
        onHoldChanged?(true)
        // Del texto se arrastra el texto: su imagen de paso ya se borró.
        let writer: NSPasteboardWriting = kind == .text ? ((text ?? "") as NSString) : (file as NSURL)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: shown)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragged else { return }

        switch kind {
        case .screenshot: onAnnotate?()
        case .video: open()
        case .text: onSelectText?()
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        if operation != [] {
            onClose?()
        } else {
            onReleased?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        Palette.window.setFill()
        bounds.fill()

        // La imagen llena la tarjeta sin deformarse. Si es muy alta o muy ancha, recorta antes que dejar bandas.
        let imageSize = image.size
        let ratio = max(bounds.width / max(imageSize.width, 1), bounds.height / max(imageSize.height, 1))
        let drawn = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        shown.draw(in: CGRect(
            x: (bounds.width - drawn.width) / 2,
            y: (bounds.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
    }

    /// "Copiado" solo en lo que de verdad está en el portapapeles, y solo un momento.
    /// Después, en reposo, solo queda la marca de los videos.
    var badgeText: String? {
        if let flashText {
            return flashText
        }
        switch kind {
        case .screenshot:
            return showsClipboardNotice ? "Copiado" : nil
        case .video:
            return showsClipboardNotice ? "Video copiado" : (durationText ?? "Video")
        case .text:
            return showsClipboardNotice ? "Texto copiado" : nil
        }
    }
}

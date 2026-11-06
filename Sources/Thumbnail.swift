import AppKit

enum ThumbnailKind {
    case screenshot
    case video
    case text
}

/// Panel de una tarjeta. Recibe el gesto de dos dedos aunque nunca sea la ventana activa.
private final class CardPanel: NSPanel {
    var onSwipe: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, event.hasPreciseScrollingDeltas, event.momentumPhase == [] {
            onSwipe?(event)
            return
        }
        super.sendEvent(event)
    }
}

/// Pila de tarjetas en la esquina. Cada captura nueva entra abajo y empuja a las demás,
/// para poder sacar varias seguidas y arrastrarlas o editarlas después.
@MainActor
final class ThumbnailController {
    var onAnnotate: ((NSImage, URL) -> Void)?
    var onPin: ((NSImage) -> Void)?
    var onSummarize: ((URL) -> Void)?

    private final class Item: @unchecked Sendable {
        let panel: CardPanel
        let view: ThumbnailView
        var timer: Timer?
        var spring: Timer?
        var swipeOffset: CGFloat = 0
        var swipeVelocity: CGFloat = 0
        var swipeTime = Date()

        init(panel: CardPanel, view: ThumbnailView) {
            self.panel = panel
            self.view = view
        }
    }

    private let width: CGFloat = 224
    private let maximumItems = 4

    private var items: [Item] = []
    private var isSuspended = false
    private var screen: NSScreen?

    /// `source` es el sitio de la pantalla de donde salió la captura: la tarjeta nace ahí.
    func show(
        image: NSImage,
        file: URL,
        kind: ThumbnailKind,
        text: String? = nil,
        inClipboard: Bool = true,
        from source: CGRect? = nil
    ) {
        screen = NSScreen.underMouse

        let imageSize = image.size
        let aspect = max(imageSize.width, 1) / max(imageSize.height, 1)
        let height = min(max((width / aspect).rounded(), 112), 168)
        let size = CGSize(width: width, height: height)

        let panel = CardPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = ThumbnailView(
            frame: CGRect(origin: .zero, size: size),
            image: image,
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
            Capture.playSound()
            item.view.flashCopied("Ruta copiada")
        }
        view.onSummarize = { [weak self] in
            self?.onSummarize?(file)
        }
        view.onDragEnded = { [weak self] in
            self?.syncHover()
        }

        // Solo la captura más reciente está en el portapapeles.
        items.forEach { $0.view.isInClipboard = false }
        view.isInClipboard = inClipboard

        items.insert(item, at: 0)
        while items.count > maximumItems, let oldest = items.last {
            dismiss(oldest, animated: false)
        }

        let target = frames()[0]
        let start = source.flatMap { $0.width >= 24 && $0.height >= 24 ? $0 : nil }
            ?? target.offsetBy(dx: target.width + Design.edgeMargin, dy: 0)
        panel.setFrame(start, display: false)
        if !isSuspended {
            panel.orderFrontRegardless()
        }
        layoutItems()
        // Mientras está escondida no corre el tiempo: se cuenta desde que se vuelva a ver.
        if !isSuspended {
            startTimer(item)
        }
    }

    /// Esconde la pila para que no salga en una captura.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
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
    }

    private func markCopied(_ item: Item) {
        let view = item.view
        guard view.copyToClipboard() else {
            NSSound.beep()
            return
        }
        items.forEach { $0.view.isInClipboard = $0 === item }
        Capture.playSound()
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

    /// Sale por el borde más cercano, hacia donde estaría si fuera un objeto.
    private func slideOut(_ panel: NSPanel) {
        let start = panel.frame
        let edge = (screen ?? NSScreen.underMouse).frame.maxX + 12
        let target = start.offsetBy(dx: edge - start.minX, dy: 0)
        Spring.run(response: 0.34, damping: 1, step: { progress in
            panel.setFrame(start.moved(to: target, by: progress), display: true)
        }, completion: {
            panel.orderOut(nil)
        })
    }

    private func handleSwipe(_ event: NSEvent, on item: Item) {
        guard !isSuspended else { return }
        switch event.phase {
        case .began:
            item.spring?.invalidate()
            item.swipeOffset = 0
            item.swipeVelocity = 0
            item.swipeTime = Date()
            stopTimer(item)
        case .changed:
            let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let now = Date()
            let elapsed = max(now.timeIntervalSince(item.swipeTime), 0.001)
            item.swipeVelocity = delta / CGFloat(elapsed)
            item.swipeTime = now
            item.swipeOffset += delta
            guard let home = homeFrame(of: item) else { return }
            item.panel.setFrameOrigin(NSPoint(x: home.minX + CardSwipe.resisted(item.swipeOffset), y: home.minY))
        case .ended, .cancelled:
            if CardSwipe.shouldClose(offset: item.swipeOffset, width: item.panel.frame.width, velocity: item.swipeVelocity) {
                dismiss(item)
            } else {
                layoutItems()
                syncHover()
            }
        default:
            break
        }
    }

    private func homeFrame(of item: Item) -> CGRect? {
        guard let index = items.firstIndex(where: { $0 === item }) else { return nil }
        return frames()[index]
    }

    private func frames() -> [CGRect] {
        let visible = (screen ?? NSScreen.underMouse).visibleFrame
        var y = visible.minY + Design.edgeMargin
        return items.map { item in
            let size = item.view.cardSize
            let frame = CGRect(x: visible.maxX - size.width - Design.edgeMargin, y: y, width: size.width, height: size.height)
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
            }, completion: { [weak item] in
                item?.panel.invalidateShadow()
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
        for item in items where !item.view.isDragging {
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
    func testCopy(index: Int) { markCopied(items[index]) }
    var testFrames: [CGRect] { items.map { $0.panel.frame } }

    var visibleCount: Int { items.count }
    #endif
}

private final class ThumbnailView: NSView, NSDraggingSource {
    var onClose: (() -> Void)?
    var onHoldChanged: ((Bool) -> Void)?
    var onAnnotate: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onSummarize: (() -> Void)?
    var onDragEnded: (() -> Void)?

    var isInClipboard = false {
        didSet { refreshBadge() }
    }

    let cardSize: CGSize

    private let image: NSImage
    private let file: URL
    private let kind: ThumbnailKind
    private let text: String?

    private var hovering = false
    var isHovering: Bool { hovering }
    private(set) var isDragging = false
    private var flashText: String?
    private var mouseDownPoint: NSPoint?
    private var dragged = false
    private var trackingArea: NSTrackingArea?

    private let actionBar: GlassView
    private var actionButtons: [GlassButton] = []
    private let badge = GlassView(frame: .zero, radius: 11)
    private let badgeLabel = NSTextField(labelWithString: "")

    var actionCount: Int { actionButtons.count }

    init(frame: CGRect, image: NSImage, file: URL, kind: ThumbnailKind, text: String?) {
        self.image = image
        self.file = file
        self.kind = kind
        self.text = text
        cardSize = frame.size
        actionBar = GlassView(frame: .zero, radius: Design.controlRadius + 2)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Design.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        buildActions()
        buildBadge()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Cuatro acciones como máximo: el resto está en el clic derecho.
    private func buildActions() {
        var buttons: [GlassButton] = [
            GlassButton(symbol: "doc.on.doc", tooltip: "Copiar otra vez", target: self, action: #selector(copyAgain)),
        ]
        switch kind {
        case .screenshot:
            buttons.append(GlassButton(symbol: "pencil.tip", tooltip: "Anotar", target: self, action: #selector(annotate)))
            buttons.append(GlassButton(symbol: "terminal", tooltip: "Copiar la ruta para un agente", target: self, action: #selector(copyPath)))
            buttons.append(GlassButton(symbol: "pin", tooltip: "Fijar en pantalla", target: self, action: #selector(pin)))
        case .video:
            buttons.append(GlassButton(symbol: "square.grid.2x2", tooltip: "Copiar resumen en imágenes para Claude", target: self, action: #selector(summarize)))
            buttons.append(GlassButton(symbol: "terminal", tooltip: "Copiar la ruta para un agente", target: self, action: #selector(copyPath)))
            buttons.append(GlassButton(symbol: "play.fill", tooltip: "Reproducir", target: self, action: #selector(open)))
        case .text:
            break
        }

        let padding: CGFloat = 4
        let gap: CGFloat = 2
        let width = padding * 2 + CGFloat(buttons.count) * Design.actionSize + CGFloat(buttons.count - 1) * gap
        let height = Design.actionSize + padding * 2
        actionBar.frame = CGRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: 8,
            width: width,
            height: height
        )
        actionBar.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        var x = padding
        for button in buttons {
            button.frame.origin = CGPoint(x: x, y: padding)
            actionBar.addSubview(button)
            x += Design.actionSize + gap
        }
        actionBar.alphaValue = 0
        addSubview(actionBar)
        actionButtons = buttons
    }

    private func buildBadge() {
        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .labelColor
        badge.addSubview(badgeLabel)
        addSubview(badge)
        refreshBadge()
    }

    private func refreshBadge() {
        guard let badgeText, !hovering else {
            badge.isHidden = true
            return
        }
        badgeLabel.stringValue = badgeText
        badgeLabel.sizeToFit()
        let size = CGSize(width: badgeLabel.frame.width + 20, height: 22)
        badge.frame = CGRect(x: 8, y: 8, width: size.width, height: size.height)
        badgeLabel.frame.origin = CGPoint(x: 10, y: ((size.height - badgeLabel.frame.height) / 2).rounded())
        badge.isHidden = false
    }

    @objc private func annotate() { onAnnotate?() }
    @objc private func pin() { onPin?() }
    @objc private func copyAgain() { onCopy?() }
    @objc private func copyPath() { onCopyPath?() }
    @objc private func summarize() { onSummarize?() }
    @objc private func closeCard() { onClose?() }

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
        if kind != .text, !Capture.isScratch(file) {
            menu.addItem(withTitle: "Mostrar en Finder", action: #selector(reveal), keyEquivalent: "").target = self
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
        // Al arrastrar, el cursor sale de la tarjeta, pero esta debe seguir ahí.
        guard !isDragging else { return }
        setHovering(false)
        onHoldChanged?(false)
    }

    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.16
        actionBar.animator().alphaValue = value ? 1 : 0
        NSAnimationContext.endGrouping()
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
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragged else { return }

        switch kind {
        case .screenshot: onAnnotate?()
        case .video: open()
        case .text: onClose?()
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
            onDragEnded?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor(white: 0.09, alpha: 1).setFill()
        bounds.fill()

        // La imagen entra completa, sin deformarse.
        let imageSize = image.size
        let ratio = min(bounds.width / max(imageSize.width, 1), bounds.height / max(imageSize.height, 1))
        let drawn = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        image.draw(in: CGRect(
            x: (bounds.width - drawn.width) / 2,
            y: (bounds.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
    }

    /// "Copiado" solo en lo que de verdad está en el portapapeles.
    var badgeText: String? {
        if let flashText {
            return flashText
        }
        switch kind {
        case .screenshot:
            return isInClipboard ? "Copiado" : nil
        case .video:
            return isInClipboard ? "Video copiado" : "Video"
        case .text:
            return isInClipboard ? "Texto copiado" : "Texto"
        }
    }
}

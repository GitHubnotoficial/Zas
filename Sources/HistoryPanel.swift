import AppKit
import Carbon
import SwiftUI

/// Botón plano de SwiftUI con los mismos dos estados inmediatos que los de AppKit.
struct ReactiveButtonStyle: ButtonStyle {
    private struct ReactiveLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(configuration.isPressed ? -0.12 : (hovering ? 0.08 : 0))
                .onHover { hovering = $0 }
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        ReactiveLabel(configuration: configuration)
    }
}

/// Qué enseña el historial. Se decide por la extensión del archivo.
enum HistoryFilter: String, CaseIterable {
    case all = "Todo"
    case images = "Capturas"
    case videos = "Videos"
    case gifs = "GIF"

    func includes(_ file: URL) -> Bool {
        let type = file.pathExtension.lowercased()
        switch self {
        case .all: return true
        case .images: return type == "png"
        case .videos: return type == "mp4"
        case .gifs: return type == "gif"
        }
    }
}

/// Estado del carrusel: qué archivos se ven y cuál está enfocado.
@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var visible: [URL] = []
    @Published private(set) var focus = 0
    @Published private(set) var filter = HistoryFilter.all
    private var files: [URL] = []

    var focused: URL? {
        visible.indices.contains(focus) ? visible[focus] : nil
    }

    init(files: [URL] = []) {
        load(files)
    }

    /// Conserva el enfoque si el archivo sigue ahí. Si se borró, pasa al que ocupó su sitio.
    func load(_ files: [URL]) {
        let kept = focused
        self.files = files
        let shown = filter
        visible = files.filter { shown.includes($0) }
        focus = kept.flatMap { visible.firstIndex(of: $0) } ?? min(focus, max(visible.count - 1, 0))
    }

    func select(_ newFilter: HistoryFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        visible = files.filter { newFilter.includes($0) }
        focus = 0
    }

    func cycleFilter(by step: Int) {
        let all = HistoryFilter.allCases
        let current = all.firstIndex(of: filter) ?? 0
        select(all[(current + step + all.count) % all.count])
    }

    func move(by step: Int) {
        focus = min(max(focus + step, 0), max(visible.count - 1, 0))
    }

    func focusOn(_ file: URL) {
        if let index = visible.firstIndex(of: file) {
            focus = index
        }
    }
}

/// Medidas del carrusel: tarjetas de 16:10.
private enum HistoryMetrics {
    static let tile = CGSize(width: 220, height: 137.5)
    static let gap: CGFloat = 20
    static let ring: CGFloat = 3
    static var step: CGFloat { tile.width + gap }
}

/// Control segmentado del sistema. El de SwiftUI no deja elegir su color: en este panel, que no activa
/// la app, se quedaba gris.
private struct HistoryFilterControl: NSViewRepresentable {
    @ObservedObject var model: HistoryModel

    final class Coordinator: NSObject {
        private let model: HistoryModel

        init(model: HistoryModel) {
            self.model = model
        }

        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            let filters = HistoryFilter.allCases
            if filters.indices.contains(sender.selectedSegment) {
                model.select(filters[sender.selectedSegment])
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: HistoryFilter.allCases.map(\.rawValue),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.selectedSegmentBezelColor = Palette.accent
        control.setAccessibilityLabel("Filtrar el historial")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        control.selectedSegment = HistoryFilter.allCases.firstIndex(of: model.filter) ?? 0
    }
}

/// Control segmentado, carrusel con la enfocada en el centro y la acción de abrir como texto.
private struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    let onOpen: (URL) -> Void
    let onChange: () -> Void

    private struct Slot: Identifiable {
        let index: Int
        let file: URL
        var id: URL { file }
    }

    private var motion: Animation? {
        Design.reduceMotion
            ? nil
            : .spring(response: Design.springResponse, dampingFraction: Design.springDamping)
    }

    /// Solo existen las tarjetas que caben: con quinientas capturas no se dibujan quinientas.
    private func slots(width: CGFloat) -> [Slot] {
        guard !model.visible.isEmpty else { return [] }
        let reach = Int(width / HistoryMetrics.step / 2) + 2
        let first = max(model.focus - reach, 0)
        let last = min(model.focus + reach, model.visible.count - 1)
        return (first...last).map { Slot(index: $0, file: model.visible[$0]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
                .padding(.top, 16)
            if model.visible.isEmpty {
                Text("Aún no hay capturas aquí.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                carousel
                    .padding(.top, 16)
                openButton
                    .padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filters: some View {
        HistoryFilterControl(model: model)
            .fixedSize()
    }

    private var carousel: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(slots(width: geometry.size.width)) { slot in
                    HistoryTile(
                        file: slot.file,
                        isFocused: slot.index == model.focus,
                        onPress: { press(slot) },
                        onOpen: onOpen,
                        onChange: onChange
                    )
                    .offset(x: CGFloat(slot.index - model.focus) * HistoryMetrics.step)
                    .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: HistoryMetrics.tile.height + HistoryMetrics.ring * 2 + 2)
        .animation(motion, value: model.focus)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capturas")
    }

    /// La del centro se abre. Las de los lados primero vienen al centro:
    /// así un clic nunca abre algo que no estaba enfocado.
    private func press(_ slot: Slot) {
        if slot.index == model.focus {
            onOpen(slot.file)
        } else {
            model.focusOn(slot.file)
        }
    }

    private var openButton: some View {
        Button {
            if let file = model.focused {
                onOpen(file)
            }
        } label: {
            Text("⏎ Abrir")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(ReactiveButtonStyle())
        .accessibilityLabel("Abrir")
        .accessibilityHint("Abre lo que está enfocado")
    }
}

private struct HistoryTile: View {
    let file: URL
    let isFocused: Bool
    let onPress: () -> Void
    let onOpen: (URL) -> Void
    let onChange: () -> Void
    @State private var preview: NSImage?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()

    private var dateText: String {
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date.map(Self.formatter.string) ?? Recents.title(for: file)
    }

    private var isVideo: Bool { HistoryFilter.videos.includes(file) }
    private var isGif: Bool { HistoryFilter.gifs.includes(file) }

    private var kindName: String {
        if isVideo { return "Video" }
        return isGif ? "GIF" : "Captura"
    }

    var body: some View {
        Button(action: onPress) {
            artwork
        }
        .buttonStyle(ReactiveButtonStyle())
        .help(dateText)
        .accessibilityLabel("\(kindName) del \(dateText)")
        .accessibilityHint(isFocused ? "Abre este archivo" : "Lleva este archivo al centro")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .accessibilityAction(named: Text("Abrir")) { onOpen(file) }
        .task(id: file) {
            // Se decodifica aparte: quinientas capturas no deben trabar el panel.
            let url = file
            preview = await Recents.previewInBackground(of: url).image
        }
        .contextMenu {
            Button("Abrir") { onOpen(file) }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            Button("Mover a la Papelera") {
                NSWorkspace.shared.recycle([file]) { _, _ in
                    Task { @MainActor in onChange() }
                }
            }
        }
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
        let size = HistoryMetrics.tile
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let preview {
                    Image(nsImage: preview).resizable().scaledToFill()
                } else {
                    Image(systemName: isVideo ? "film" : "photo")
                        .font(.system(size: Design.iconSize * 2))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: Palette.group))
            .clipped()
            .accessibilityHidden(true)

            if isVideo || isGif {
                badge
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: Palette.hairline), lineWidth: Design.lineWidth))
        .overlay(
            RoundedRectangle(cornerRadius: Design.cardRadius + HistoryMetrics.ring, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: HistoryMetrics.ring)
                .padding(-HistoryMetrics.ring)
                .opacity(isFocused ? 1 : 0)
        )
        .contentShape(shape)
    }

    private var badge: some View {
        Group {
            if isVideo {
                Image(systemName: "play.fill")
            } else {
                Text("GIF")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Color.black.opacity(0.6), in: Capsule())
    }
}

/// Panel sin título que sí recibe teclado sin robarle el foco a la app de delante.
private final class HistoryPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onWheel: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true {
            return
        }
        if event.type == .scrollWheel, let onWheel {
            onWheel(event)
            return
        }
        super.sendEvent(event)
    }
}

/// El historial: una franja de material que sigue la apariencia del sistema, abajo en la pantalla.
@MainActor
final class HistoryController {
    private static let height: CGFloat = 268
    /// Aire hasta los bordes de la pantalla.
    static let inset: CGFloat = 12
    /// Recorrido del trackpad que equivale a pasar una tarjeta.
    private static let wheelStep: CGFloat = 90

    let model = HistoryModel()
    var onClose: (() -> Void)?
    /// Las escenas de prueba lo apagan: en esas máquinas el foco puede irse solo.
    var closesOnFocusLoss = true

    private let onOpen: (URL) -> Void
    private var panel: HistoryPanel?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var spring: Timer?
    private var wheelTravel: CGFloat = 0
    private var menuIsOpen = false

    init(onOpen: @escaping (URL) -> Void) {
        self.onOpen = onOpen
    }

    var isOpen: Bool { panel != nil }

    func reload() {
        model.load(Recents.files(limit: 500))
    }

    func show() {
        reload()
        let screen = NSScreen.underMouse
        // Sobre el Dock, no encima: de la franja no debe asomar nada por debajo.
        let frame = CGRect(
            x: screen.frame.minX + Self.inset,
            y: screen.visibleFrame.minY + Self.inset,
            width: screen.frame.width - Self.inset * 2,
            height: Self.height
        )
        let panel = HistoryPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Historial"
        panel.setAccessibilityLabel("Historial")
        // Por encima de las ventanas y de un Dock lateral.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content(size: frame.size)
        panel.onKey = { [weak self] event in
            self?.handle(event) ?? false
        }
        panel.onWheel = { [weak self] event in
            self?.handleWheel(event)
        }
        self.panel = panel
        watchFocus(of: panel)

        let start = frame.offsetBy(dx: 0, dy: -36)
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = Design.fadeDuration
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
        // Amortiguado del todo: un rebote se notaría contra el borde de la pantalla.
        // Solo viaja: mover el marco sin volver a dibujar toda la franja en cada cuadro.
        spring = Spring.run(damping: 1, step: { progress in
            panel.setFrameOrigin(start.moved(to: frame, by: progress).origin)
        })
    }

    func close(animated: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        spring?.invalidate()
        spring = nil
        panel.onKey = nil
        panel.onWheel = nil
        panel.ignoresMouseEvents = true
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        onClose?()

        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = Design.fadeDuration
        panel.animator().alphaValue = 0
        NSAnimationContext.endGrouping()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((Design.fadeDuration + 0.02) * 1_000_000_000))
            panel.orderOut(nil)
        }
    }

    private func content(size: CGSize) -> NSView {
        let bounds = CGRect(origin: .zero, size: size)
        let glass = GlassView(frame: bounds, radius: Design.radiusLarge, material: .hudWindow)
        glass.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: HistoryView(
            model: model,
            onOpen: { [weak self] file in
                self?.open(file)
            },
            onChange: { [weak self] in
                self?.reload()
            }
        ))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        return glass
    }

    /// Clic fuera cierra: cuando el panel pierde el foco, o cuando se hace clic en otra app.
    private func watchFocus(of panel: NSPanel) {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lostFocus()
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lostFocus()
            }
        })
        // El menú de clic derecho no debe contar como salir del panel.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuIsOpen = true
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuClosed()
            }
        })
    }

    private func menuClosed() {
        menuIsOpen = false
        panel?.makeKey()
    }

    private func lostFocus() {
        guard closesOnFocusLoss, !menuIsOpen else { return }
        close()
    }

    private func open(_ file: URL) {
        // Sin animación: la tarjeta de lo abierto aparece enseguida.
        close(animated: false)
        onOpen(file)
    }

    /// Devuelve `true` si la tecla ya se atendió.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        guard flags.isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            model.move(by: -1)
        case kVK_RightArrow:
            model.move(by: 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let file = model.focused {
                open(file)
            }
        case kVK_Escape:
            close()
        case kVK_Tab:
            model.cycleFilter(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        default:
            break
        }
        // El resto se ignora en silencio: aquí no hay dónde escribir.
        return true
    }

    /// Rueda y trackpad, en cualquier dirección, pasan tarjetas: la enfocada queda siempre al centro.
    private func handleWheel(_ event: NSEvent) {
        let isHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let delta = -(isHorizontal ? event.scrollingDeltaX : event.scrollingDeltaY)
        guard event.hasPreciseScrollingDeltas else {
            if delta != 0 {
                model.move(by: delta > 0 ? 1 : -1)
            }
            return
        }
        if event.phase == .began {
            wheelTravel = 0
        }
        wheelTravel += delta
        while abs(wheelTravel) >= Self.wheelStep {
            let direction: CGFloat = wheelTravel > 0 ? 1 : -1
            model.move(by: Int(direction))
            wheelTravel -= direction * Self.wheelStep
        }
    }

    #if ZAS_TEST
    var testCanBecomeKey: Bool { panel?.canBecomeKey ?? false }
    var testFrame: CGRect { panel?.frame ?? .zero }

    func testKey(_ keyCode: UInt16) {
        guard let panel, let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        panel.sendEvent(event)
    }

    /// Una rueda de ratón común: los valores negativos desplazan hacia abajo.
    func testWheel(lines: Int32) {
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent)
        else { return }
        handleWheel(event)
    }
    #endif
}

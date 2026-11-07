import AppKit
import ServiceManagement
import SwiftUI

/// Captura un atajo nuevo: al hacer clic escucha la siguiente combinación de teclas.
/// En reposo es texto a la derecha. Solo lleva fondo con el cursor encima o mientras graba.
final class ShortcutRecorderButton: ReactiveButton {
    /// Mientras se elige un atajo, los globales se apagan: si no, se comerían la combinación.
    static var onRecordingChanged: ((Bool) -> Void)?

    var onChange: ((Shortcut) -> Void)?

    var shortcut: Shortcut {
        didSet { refreshTitle() }
    }

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    private var shownText: String {
        monitor == nil ? shortcut.displayString : "Pulsa las teclas…"
    }

    override var isFlipped: Bool { false }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: CGRect(x: 0, y: 0, width: 130, height: 22))
        title = ""
        isBordered = false
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    private func refreshTitle() {
        setAccessibilityValue(shownText)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let isRecording = monitor != nil
        let shape = NSBezierPath.continuous(in: bounds, radius: Design.radiusSmall)
        if isRecording {
            Palette.activeVeil.setFill()
            shape.fill()
        } else if isPressed {
            Palette.pressed.setFill()
            shape.fill()
        } else if isHovering {
            Palette.hover.setFill()
            shape.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Design.SettingsWindow.bodySize),
            .foregroundColor: isRecording ? Palette.accent : Palette.secondaryText,
        ]
        let text = shownText as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.maxX - 8 - size.width, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    @objc private func beginRecording() {
        guard monitor == nil else { return }
        ShortcutRecorderButton.onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Una tecla en otra ventana cancela: no debe convertirse en atajo.
            guard event.window === self.window else {
                self.stopRecording()
                return event
            }
            self.handle(event)
            return nil
        }
        // Si se cambia de ventana a medias, los atajos globales deben volver:
        // de lo contrario quedarían apagados sin que nadie lo note.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopRecording()
            }
        }
        refreshTitle()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopRecording()
        }
    }

    private func handle(_ event: NSEvent) {
        defer { stopRecording() }
        guard event.keyCode != 53 else { return } // Esc cancela.

        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              Shortcut.isSupported(keyCode: event.keyCode)
        else {
            NSSound.beep()
            return
        }
        let new = Shortcut(keyCode: UInt32(event.keyCode), modifiers: Shortcut.carbonModifiers(from: flags))
        shortcut = new
        onChange?(new)
    }

    private func stopRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        refreshTitle()
        ShortcutRecorderButton.onRecordingChanged?(false)
    }
}

private struct ShortcutField: NSViewRepresentable {
    let action: HotKeyAction
    @ObservedObject var settings: Settings

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(shortcut: settings.shortcut(for: action))
        button.setAccessibilityLabel(action.title)
        button.onChange = { [settings, action] shortcut in
            settings.shortcuts[action] = shortcut
        }
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        let shortcut = settings.shortcut(for: action)
        if button.shortcut != shortcut {
            button.shortcut = shortcut
        }
    }
}

/// Medidas de la ventana de Ajustes. Los colores son los del sistema y los de `Palette`.
extension Design {
    enum SettingsWindow {
        static let width: CGFloat = 500
        /// Lo que se deja libre por encima y por debajo en una pantalla baja.
        static let screenRoom: CGFloat = 40
        static let contentMargin: CGFloat = 20
        static let sectionGap: CGFloat = 20
        static let rowHeight: CGFloat = 32
        static let rowInset: CGFloat = 12
        static let titleSize: CGFloat = 15
        static let bodySize: CGFloat = 13
        static let detailSize: CGFloat = 11
        static let sectionSize: CGFloat = 12
    }
}

private enum SettingsPane: CaseIterable {
    case general, shortcuts, video

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Atajos"
        case .video: return "Video"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .video: return "video"
        }
    }

    var identifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("ajustes.\(title)")
    }
}

/// La pestaña elegida. Avisa para que la ventana cambie su título y su altura.
private final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane = .general {
        didSet { onChange?(pane) }
    }

    /// El contenido cabe entero: no hay nada que desplazar.
    @Published var contentFits = true

    var onChange: ((SettingsPane) -> Void)?
}

/// Pestañas de la barra, como en el Settings estándar.
@MainActor
private final class SettingsTabs: NSObject, NSToolbarDelegate {
    private let navigation: SettingsNavigation
    private var identifiers: [NSToolbarItem.Identifier] { SettingsPane.allCases.map(\.identifier) }

    init(navigation: SettingsNavigation) {
        self.navigation = navigation
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane.allCases.first(where: { $0.identifier == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(tabPressed(_:))
        return item
    }

    @objc private func tabPressed(_ sender: NSToolbarItem) {
        if let pane = SettingsPane.allCases.first(where: { $0.identifier == sender.itemIdentifier }) {
            navigation.pane = pane
        }
    }
}

/// Título discreto y filas agrupadas, sin líneas entre ellas.
private struct SettingsSection<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.radiusMedium, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: Design.SettingsWindow.sectionSize, weight: .semibold))
                    .foregroundColor(Color(nsColor: Palette.secondaryText))
                    .padding(.horizontal, Design.SettingsWindow.rowInset)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, Design.SettingsWindow.rowInset)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: Palette.section), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: Palette.hairline), lineWidth: Design.lineWidth))
        }
    }
}

/// Texto a la izquierda y control a la derecha. Si el control ya lleva el nombre para
/// VoiceOver, `labelled` esconde el texto para no leerlo dos veces.
private struct SettingsRow<Accessory: View>: View {
    let title: String
    let detail: String?
    let isEnabled: Bool
    let labelled: Bool
    let accessory: Accessory

    init(
        _ title: String,
        detail: String? = nil,
        isEnabled: Bool = true,
        labelled: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.detail = detail
        self.isEnabled = isEnabled
        self.labelled = labelled
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Design.SettingsWindow.bodySize))
                    .foregroundColor(Color(nsColor: isEnabled ? Palette.text : Palette.secondaryText))
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(labelled)
                if let detail {
                    Text(detail)
                        .font(.system(size: Design.SettingsWindow.detailSize))
                        .foregroundColor(Color(nsColor: Palette.secondaryText))
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .frame(minHeight: Design.SettingsWindow.rowHeight)
    }
}

private struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String?
    var isEnabled = true

    var body: some View {
        SettingsRow(title, detail: detail, isEnabled: isEnabled, labelled: true) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isEnabled)
        }
    }
}

private extension View {
    /// Selector pequeño y sin marco, pegado al borde de la fila. La etiqueta sigue para VoiceOver.
    func settingsPicker() -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
    }

    /// Botones estándar y pequeños.
    func settingsButton() -> some View {
        controlSize(.small)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: Settings
    let pane: SettingsPane
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: Design.SettingsWindow.sectionGap) {
            Text(pane.title)
                .font(.system(size: Design.SettingsWindow.titleSize, weight: .semibold))
                .foregroundColor(Color(nsColor: Palette.text))
                .accessibilityAddTraits(.isHeader)
            switch pane {
            case .general: general
            case .shortcuts: shortcuts
            case .video: video
            }
        }
        .padding(Design.SettingsWindow.contentMargin)
        .frame(width: Design.SettingsWindow.width, alignment: .topLeading)
    }

    @ViewBuilder
    private var general: some View {
        SettingsSection {
            SettingsToggle(title: "Abrir Zas al iniciar sesión", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            SettingsToggle(title: "Efectos de sonido", isOn: $settings.soundEffects)
        }
        SettingsSection("Captura") {
            SettingsToggle(title: "Ocultar iconos del escritorio", isOn: $settings.hidesDesktopIcons)
        }
        SettingsSection("Miniaturas") {
            SettingsToggle(title: "Mostrar miniaturas a la izquierda", isOn: $settings.thumbnailsOnLeft)
            SettingsRow("Mostrar miniatura durante", labelled: true) {
                Picker("Mostrar miniatura durante", selection: $settings.thumbnailSeconds) {
                    Text("3 segundos").tag(3.0)
                    Text("6 segundos").tag(6.0)
                    Text("10 segundos").tag(10.0)
                    Text("30 segundos").tag(30.0)
                }
                .settingsPicker()
            }
        }
        SettingsSection("Guardar") {
            SettingsToggle(title: "Guardar una copia de cada captura", isOn: $settings.saveCaptures)
            SettingsRow("Capturas y videos") {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: Design.SettingsWindow.detailSize))
                        .foregroundColor(Color(nsColor: Palette.accent))
                        .accessibilityHidden(true)
                    Text(displayPath)
                        .font(.system(size: Design.SettingsWindow.detailSize))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(Color(nsColor: Palette.secondaryText))
                    Button("Mostrar en Finder") {
                        NSWorkspace.shared.open(Capture.folder)
                    }
                    .settingsButton()
                    Button("Elegir…", action: chooseFolder)
                        .settingsButton()
                }
            }
        }
        HStack {
            Spacer()
            // El menú de la app no se ve en una app de la barra de menú.
            Button("Acerca de Zas") {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            .settingsButton()
        }
    }

    @ViewBuilder
    private var shortcuts: some View {
        SettingsSection {
            ForEach(HotKeyAction.allCases, id: \.self) { action in
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(action.title) {
                        ShortcutField(action: action, settings: settings)
                            .frame(width: 136, height: 22)
                    }
                    if settings.conflicts.contains(action) {
                        Label("Este atajo ya está en uso. Elige otro.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: Design.SettingsWindow.detailSize))
                            .foregroundColor(Color(nsColor: Palette.secondaryText))
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        HStack {
            Spacer()
            Button("Restablecer atajos") {
                settings.resetShortcuts()
            }
            .settingsButton()
        }
    }

    @ViewBuilder
    private var video: some View {
        SettingsSection {
            SettingsRow("Al terminar, copiar", labelled: true) {
                Picker("Al terminar, copiar", selection: $settings.videoCopiesSummary) {
                    Text("Resumen en imágenes").tag(true)
                    Text("Archivo de video").tag(false)
                }
                .settingsPicker()
            }
            SettingsRow("Tomar una imagen cada", isEnabled: settings.videoCopiesSummary, labelled: true) {
                Picker("Tomar una imagen cada", selection: $settings.videoEvery) {
                    Text("1 segundo").tag(1.0)
                    Text("2 segundos").tag(2.0)
                    Text("5 segundos").tag(5.0)
                    Text("10 segundos").tag(10.0)
                    Text("30 segundos").tag(30.0)
                    Text("1 minuto").tag(60.0)
                }
                .settingsPicker()
                .disabled(!settings.videoCopiesSummary)
            }
            SettingsRow("Detener la grabación a los", labelled: true) {
                Picker("Detener la grabación a los", selection: $settings.videoLimit) {
                    Text("Sin límite").tag(0.0)
                    Text("10 segundos").tag(10.0)
                    Text("30 segundos").tag(30.0)
                    Text("1 minuto").tag(60.0)
                    Text("5 minutos").tag(300.0)
                }
                .settingsPicker()
            }
            SettingsRow("Cuadros por segundo", labelled: true) {
                Picker("Cuadros por segundo", selection: $settings.videoFPS) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .settingsPicker()
            }
        }
        SettingsSection("Mostrar en el video") {
            SettingsToggle(title: "Cursor", isOn: $settings.videoCursor)
            SettingsToggle(title: "Clics", isOn: $settings.videoClicks)
            SettingsToggle(title: "Teclas", isOn: $settings.videoKeys)
            SettingsToggle(title: "Cámara", isOn: $settings.videoCamera)
        }
        SettingsSection("Sonido") {
            SettingsToggle(title: "Sonido del Mac", isOn: $settings.systemAudio)
            SettingsToggle(
                title: "Micrófono",
                isOn: $settings.recordMicrophone,
                detail: ScreenRecorder.supportsMicrophone ? nil : "Requiere macOS 15 o más nuevo.",
                isEnabled: ScreenRecorder.supportsMicrophone
            )
        }
    }

    private var displayPath: String {
        settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Zas: no se pudo cambiar el inicio de sesión: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Elegir"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }
}

/// La pestaña elegida. Solo se desplaza si la pantalla es más baja que su contenido.
private struct SettingsRootView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        ScrollView {
            // Cada pestaña empieza desde arriba.
            SettingsView(settings: settings, pane: navigation.pane)
                .id(navigation.pane)
        }
        .scrollDisabled(navigation.contentFits)
    }
}

/// La bienvenida se entera de que se pulsó el atajo.
private final class WelcomeState: ObservableObject {
    @Published var keyIsLit = false
}

/// Primer contacto: una sola idea por pantalla. Ritmo 24, 8, 24 y 24.
private struct WelcomeView: View {
    let hasPermission: Bool
    @ObservedObject var state: WelcomeState
    let openSettings: () -> Void
    let relaunch: () -> Void
    let dismiss: () -> Void
    @State private var openedSettings = false

    private static let iconShape = RoundedRectangle(cornerRadius: Design.radiusLarge, style: .continuous)

    private var keyMotion: Animation? {
        Design.reduceMotion ? nil : .spring(response: Design.slideResponse, dampingFraction: Design.springDamping)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .overlay(Self.iconShape.strokeBorder(Color(nsColor: Palette.hairline), lineWidth: Design.lineWidth))
                .padding(.top, 24)
                .accessibilityHidden(true)

            Text(hasPermission ? "Zas está listo" : "Permite grabar la pantalla")
                .font(.title)
                .padding(.top, 24)

            Text(hasPermission
                ? "Vive en la barra de menú. Haz tu primera captura con este atajo."
                : "macOS lo pide para capturar. Todo se queda en tu Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 44)

            if hasPermission {
                Text(Settings.shared.shortcut(for: .region).displayString)
                    .font(.title2)
                    .foregroundStyle(state.keyIsLit ? AnyShapeStyle(Color(nsColor: Palette.accent)) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 24)
                    .background(
                        state.keyIsLit ? AnyShapeStyle(Color(nsColor: Palette.activeVeil)) : AnyShapeStyle(HierarchicalShapeStyle.quaternary),
                        in: RoundedRectangle(cornerRadius: Design.radiusMedium, style: .continuous)
                    )
                    .animation(keyMotion, value: state.keyIsLit)
                    .padding(.top, 24)
            }

            Button(action: primaryAction) {
                Text(primaryTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .padding(.horizontal, 44)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 400)
    }

    private var primaryTitle: String {
        if hasPermission { return "Empezar" }
        return openedSettings ? "Reiniciar Zas" : "Abrir Ajustes"
    }

    private func primaryAction() {
        if hasPermission {
            dismiss()
        } else if openedSettings {
            relaunch()
        } else {
            openedSettings = true
            openSettings()
        }
    }
}

/// Crea y recuerda las dos ventanas de la app.
@MainActor
final class WindowCoordinator: NSObject {
    private var settingsWindow: NSWindow?
    private var settingsNavigation: SettingsNavigation?
    private var settingsTabs: SettingsTabs?
    private var settingsSpring: Timer?
    private var welcomeWindow: NSWindow?
    private let welcomeState = WelcomeState()

    func showSettings() {
        if settingsWindow == nil {
            let width = Design.SettingsWindow.width
            let bounds = CGRect(x: 0, y: 0, width: width, height: 400)
            // Sin minimizar ni cambiar de tamaño: la ventana mide lo que mide su pestaña.
            let window = NSWindow(contentRect: bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            // El título no se ve, pero nombra la pestaña para VoiceOver y el menú Ventana.
            window.title = SettingsPane.general.title
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false

            let navigation = SettingsNavigation()
            let tabs = SettingsTabs(navigation: navigation)
            let toolbar = NSToolbar(identifier: "ajustes")
            toolbar.delegate = tabs
            toolbar.displayMode = .iconAndLabel
            toolbar.selectedItemIdentifier = SettingsPane.general.identifier
            window.toolbar = toolbar
            window.toolbarStyle = .preference

            navigation.onChange = { [weak self, weak window, weak toolbar] pane in
                window?.title = pane.title
                toolbar?.selectedItemIdentifier = pane.identifier
                self?.fitSettings(animated: true)
            }
            let host = NSHostingView(rootView: SettingsRootView(settings: .shared, navigation: navigation))
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            let container = NSView(frame: bounds)
            container.addSubview(host)
            window.contentView = container

            settingsWindow = window
            settingsNavigation = navigation
            settingsTabs = tabs
            fitSettings(animated: false)
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Con la barra ya en pantalla, la cuenta de su altura es la definitiva.
        fitSettings(animated: false)
    }

    /// La mayor altura que cabe en la pantalla de la ventana.
    private func settingsRoom(in window: NSWindow) -> CGFloat {
        #if ZAS_TEST
        if let testSettingsRoom {
            return testSettingsRoom
        }
        #endif
        return (window.screen ?? NSScreen.underMouse).visibleFrame.height - Design.SettingsWindow.screenRoom
    }

    /// Lleva la ventana a la altura de la pestaña, sin mover su borde de arriba.
    /// En una pantalla baja se queda dentro y el contenido se desplaza.
    private func fitSettings(animated: Bool) {
        guard let window = settingsWindow, let navigation = settingsNavigation, let content = window.contentView else { return }
        settingsSpring?.invalidate()
        let wanted = NSHostingView(rootView: SettingsView(settings: .shared, pane: navigation.pane)).fittingSize.height.rounded(.up)
        let chrome = window.frame.height - content.bounds.height
        let room = settingsRoom(in: window)
        let height = min(wanted + chrome, room)
        navigation.contentFits = wanted + chrome <= room

        let start = window.frame
        let target = CGRect(x: start.minX, y: start.maxY - height, width: start.width, height: height)
        guard animated else {
            window.setFrame(target, display: true)
            return
        }
        settingsSpring = Spring.run(step: { [weak window] progress in
            window?.setFrame(start.moved(to: target, by: progress), display: true)
        })
    }

    private var history: HistoryController?

    func showHistory(onOpen: @escaping (URL) -> Void) {
        if let history {
            history.reload()
            return
        }
        let controller = HistoryController(onOpen: onOpen)
        controller.onClose = { [weak self] in
            self?.history = nil
        }
        history = controller
        controller.show()
    }

    /// Una captura no debe llevarse el historial en la imagen.
    func closeHistory() {
        history?.close(animated: false)
    }

    /// El atajo de la bienvenida se ilumina al pulsarlo y sigue encendido durante la primera captura.
    func lightWelcomeKey() {
        welcomeState.keyIsLit = welcomeWindow?.isVisible == true
    }

    func dimWelcomeKey() {
        welcomeState.keyIsLit = false
    }

    /// La primera captura ya salió: la bienvenida ha cumplido.
    func finishWelcome() {
        guard welcomeState.keyIsLit else { return }
        welcomeState.keyIsLit = false
        welcomeWindow?.close()
    }

    func showWelcome(hasPermission: Bool, openSettings: @escaping () -> Void, relaunch: @escaping () -> Void) {
        let dismiss: () -> Void = { [weak self] in
            self?.welcomeWindow?.close()
        }
        let host = NSHostingController(rootView: WelcomeView(
            hasPermission: hasPermission,
            state: welcomeState,
            openSettings: openSettings,
            relaunch: relaunch,
            dismiss: dismiss
        ))
        welcomeWindow?.close()
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = hasPermission ? "Bienvenida" : "Permiso"
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(host.view.fittingSize)
        window.center()
        welcomeWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    #if ZAS_TEST
    func testSettingsPane(_ index: Int) {
        settingsNavigation?.pane = SettingsPane.allCases[index]
    }

    var testSettingsTitle: String { settingsWindow?.title ?? "" }
    var testSettingsWindow: NSWindow? { settingsWindow }
    /// Simula una pantalla baja: la ventana de Ajustes no puede pasar de esta altura.
    var testSettingsRoom: CGFloat?
    var testSettingsContentFits: Bool { settingsNavigation?.contentFits ?? false }
    var testSettingsTabCount: Int { settingsWindow?.toolbar?.items.count ?? 0 }
    var testWelcomeKeyIsLit: Bool { welcomeState.keyIsLit }
    var testWelcomeIsOpen: Bool { welcomeWindow?.isVisible == true }

    func closeAll() {
        settingsSpring?.invalidate()
        settingsWindow?.close()
        welcomeWindow?.close()
        settingsWindow = nil
        settingsNavigation = nil
        settingsTabs = nil
        welcomeWindow = nil
        closeHistory()
    }

    var testHistory: HistoryController? { history }
    #endif
}

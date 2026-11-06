import AppKit
import ServiceManagement
import SwiftUI

/// Captura un atajo nuevo: al hacer clic escucha la siguiente combinación de teclas.
final class ShortcutRecorderButton: NSButton {
    /// Mientras se elige un atajo, los globales se apagan: si no, se comerían la combinación.
    static var onRecordingChanged: ((Bool) -> Void)?

    var onChange: ((Shortcut) -> Void)?

    var shortcut: Shortcut {
        didSet { refreshTitle() }
    }

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: Design.SettingsWindow.detailSize)
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    private func refreshTitle() {
        title = monitor == nil ? shortcut.displayString : "Pulsa las teclas…"
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

/// Medidas y colores de la ventana de Ajustes. El fondo del contenido es más claro que la
/// ventana del editor: las tarjetas gris muy claro solo se leen sobre blanco.
extension Design {
    enum SettingsWindow {
        static let size = CGSize(width: 720, height: 594)
        static let radius: CGFloat = 16
        static let sidebarWidth: CGFloat = 190
        static let sidebarInset: CGFloat = 10
        /// Alto de la franja de los semáforos, igual a la de título del contenido.
        static let headerHeight: CGFloat = 52
        static let entryHeight: CGFloat = 32
        static let entryRadius: CGFloat = 8
        static let entryGap: CGFloat = 3
        static let iconSide: CGFloat = 20
        static let iconRadius: CGFloat = 5
        static let iconSymbol: CGFloat = 11
        static let contentMargin: CGFloat = 20
        static let sectionGap: CGFloat = 20
        static let cardRadius: CGFloat = 10
        static let rowHeight: CGFloat = 34
        static let rowInset: CGFloat = 10
        static let bodySize: CGFloat = 12
        static let detailSize: CGFloat = 11
        static let sectionSize: CGFloat = 13

        static let grayIcon = NSColor.systemGray
        static let redIcon = NSColor.systemRed
        static let iconSymbolColor = NSColor.white

        static var contentFill: NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark ? NSColor(srgbRed: 0x1B / 255, green: 0x1B / 255, blue: 0x1D / 255, alpha: 1) : .white
            }
        }

        static var cardFill: NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark
                    ? NSColor(srgbRed: 0x2B / 255, green: 0x2B / 255, blue: 0x2D / 255, alpha: 1)
                    : NSColor(srgbRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
            }
        }
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
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .video: return "video.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .general, .shortcuts: return Design.SettingsWindow.grayIcon
        case .video: return Design.SettingsWindow.redIcon
        }
    }
}

/// La sección elegida en la barra lateral. Avisa para que el título de la ventana la siga.
private final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane = .general {
        didSet { onChange?(pane) }
    }

    var onChange: ((SettingsPane) -> Void)?
}

/// Icono en cuadro de color, texto y fondo gris cuando está elegida.
private struct SidebarEntry: View {
    let title: String
    let symbol: String
    let tint: NSColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: Design.SettingsWindow.iconSymbol, weight: .semibold))
                    .foregroundColor(Color(nsColor: Design.SettingsWindow.iconSymbolColor))
                    .frame(width: Design.SettingsWindow.iconSide, height: Design.SettingsWindow.iconSide)
                    .background(
                        Color(nsColor: tint),
                        in: RoundedRectangle(cornerRadius: Design.SettingsWindow.iconRadius, style: .continuous)
                    )
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: Design.SettingsWindow.bodySize))
                    .foregroundColor(Color(nsColor: Palette.text))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: Design.SettingsWindow.entryHeight)
            .background(
                isSelected ? Color(nsColor: Palette.hairline) : Color.clear,
                in: RoundedRectangle(cornerRadius: Design.SettingsWindow.entryRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: Design.SettingsWindow.entryGap) {
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                SidebarEntry(
                    title: pane.title,
                    symbol: pane.symbol,
                    tint: pane.tint,
                    isSelected: navigation.pane == pane
                ) {
                    navigation.pane = pane
                }
            }
            Spacer(minLength: 0)
            // No es una sección: abre el mismo panel que el menú de la app.
            SidebarEntry(
                title: "Acerca de",
                symbol: "info",
                tint: Design.SettingsWindow.grayIcon,
                isSelected: false
            ) {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        }
        .padding(.top, Design.SettingsWindow.headerHeight)
        .padding(.horizontal, Design.SettingsWindow.sidebarInset)
        .padding(.bottom, Design.SettingsWindow.sidebarInset)
    }
}

/// Título en negrita y filas agrupadas en una tarjeta, sin líneas entre ellas.
private struct SettingsSection<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: Design.SettingsWindow.sectionSize, weight: .bold))
                    .foregroundColor(Color(nsColor: Palette.text))
                    .padding(.horizontal, Design.SettingsWindow.rowInset)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, Design.SettingsWindow.rowInset)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: Design.SettingsWindow.cardFill),
                in: RoundedRectangle(cornerRadius: Design.SettingsWindow.cardRadius, style: .continuous)
            )
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

    /// Botones "Elegir…": pequeños y grises.
    func settingsButton() -> some View {
        buttonStyle(.bordered)
            .controlSize(.small)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: Settings
    let pane: SettingsPane
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pane.title)
                .font(.system(size: Design.SettingsWindow.sectionSize, weight: .semibold))
                .foregroundColor(Color(nsColor: Palette.text))
                .frame(height: Design.SettingsWindow.headerHeight)
                .padding(.horizontal, Design.SettingsWindow.contentMargin)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.SettingsWindow.sectionGap) {
                    switch pane {
                    case .general: general
                    case .shortcuts: shortcuts
                    case .video: video
                    }
                }
                .padding(.horizontal, Design.SettingsWindow.contentMargin)
                .padding(.bottom, Design.SettingsWindow.contentMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Cada sección empieza desde arriba.
            .id(pane)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: Design.SettingsWindow.contentFill))
    }

    @ViewBuilder
    private var general: some View {
        SettingsSection("App") {
            SettingsToggle(title: "Abrir Zas al iniciar sesión", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
        }
        SettingsSection("Captura") {
            SettingsToggle(title: "Sonido al capturar", isOn: $settings.playSound)
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
                    Image(systemName: "folder.fill")
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
    }

    @ViewBuilder
    private var shortcuts: some View {
        SettingsSection {
            ForEach(HotKeyAction.allCases, id: \.self) { action in
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(action.title) {
                        ShortcutField(action: action, settings: settings)
                            .frame(width: 130, height: 22)
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

/// Barra lateral sobre el vidrio de la ventana y, a la derecha, la sección elegida.
private struct SettingsRootView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation)
                .frame(width: Design.SettingsWindow.sidebarWidth)
            SettingsView(settings: settings, pane: navigation.pane)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // La franja de los semáforos es parte del diseño: sin esto, todo bajaría 52 puntos.
        .ignoresSafeArea()
    }
}

/// Primer contacto: una sola idea por pantalla.
private struct WelcomeView: View {
    let hasPermission: Bool
    let openSettings: () -> Void
    let relaunch: () -> Void
    let dismiss: () -> Void
    @State private var openedSettings = false

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .padding(.top, 36)
                .accessibilityHidden(true)

            Text(hasPermission ? "Zas está listo" : "Permite grabar la pantalla")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 16)

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
                    .font(.title.weight(.semibold))
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 22)
            }

            Button(action: primaryAction) {
                Text(primaryTitle).frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .padding(.horizontal, 44)
            .padding(.top, 26)
            .padding(.bottom, 30)
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
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private var settingsNavigation: SettingsNavigation?
    private var welcomeWindow: NSWindow?

    func showSettings() {
        if settingsWindow == nil {
            let metrics = Design.SettingsWindow.self
            let bounds = CGRect(origin: .zero, size: metrics.size)
            let window = NSWindow(
                contentRect: bounds,
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            // El título no se ve, pero nombra la sección para VoiceOver y el menú Ventana.
            window.title = SettingsPane.general.title
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            // Una barra vacía da aire a los semáforos, igual que la franja de 52 del contenido.
            window.toolbar = NSToolbar(identifier: "ajustes")
            window.toolbarStyle = .unified
            // Ventana transparente: las esquinas de 16 las pone el vidrio, no el sistema.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false

            let navigation = SettingsNavigation()
            navigation.onChange = { [weak window] pane in
                window?.title = pane.title
            }
            let glass = GlassView(frame: bounds, radius: metrics.radius, material: .sidebar)
            glass.autoresizingMask = [.width, .height]
            let host = NSHostingView(rootView: SettingsRootView(settings: .shared, navigation: navigation))
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            glass.addSubview(host)
            window.contentView = glass

            window.center()
            settingsWindow = window
            settingsNavigation = navigation
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // La sombra sigue a las esquinas propias, no al rectángulo de la ventana.
        settingsWindow?.invalidateShadow()
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

    func showWelcome(hasPermission: Bool, openSettings: @escaping () -> Void, relaunch: @escaping () -> Void) {
        let dismiss: () -> Void = { [weak self] in
            self?.welcomeWindow?.close()
        }
        let host = NSHostingController(rootView: WelcomeView(
            hasPermission: hasPermission,
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

    func closeAll() {
        settingsWindow?.close()
        welcomeWindow?.close()
        settingsWindow = nil
        settingsNavigation = nil
        welcomeWindow = nil
        closeHistory()
    }

    var testHistory: HistoryController? { history }
    #endif
}

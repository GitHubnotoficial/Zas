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
}

private struct SettingsView: View {
    @ObservedObject var settings: Settings
    let pane: SettingsPane
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Group {
            switch pane {
            case .general: general
            case .shortcuts: shortcuts
            case .video: video
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var general: some View {
        Form {
            Toggle("Abrir Zas al iniciar sesión", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            Toggle("Sonido al capturar", isOn: $settings.playSound)
            Picker("Mostrar miniatura durante", selection: $settings.thumbnailSeconds) {
                Text("3 segundos").tag(3.0)
                Text("6 segundos").tag(6.0)
                Text("10 segundos").tag(10.0)
                Text("30 segundos").tag(30.0)
            }
            Toggle("Guardar una copia de cada captura", isOn: $settings.saveCaptures)
            LabeledContent("Capturas y videos") {
                HStack(spacing: 8) {
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Mostrar en Finder") {
                        NSWorkspace.shared.open(Capture.folder)
                    }
                    Button("Cambiar…", action: chooseFolder)
                }
            }
        }
    }

    private var shortcuts: some View {
        Form {
            ForEach(HotKeyAction.allCases, id: \.self) { action in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(action.title) {
                        ShortcutField(action: action, settings: settings)
                            .frame(width: 130, height: 24)
                    }
                    if settings.conflicts.contains(action) {
                        Label("Este atajo ya está en uso. Elige otro.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restablecer atajos") {
                    settings.resetShortcuts()
                }
            }
        }
    }

    private var video: some View {
        Form {
            Section {
                Picker("Al terminar, copiar", selection: $settings.videoCopiesSummary) {
                    Text("Resumen en imágenes").tag(true)
                    Text("Archivo de video").tag(false)
                }
                Picker("Tomar una imagen cada", selection: $settings.videoEvery) {
                    Text("1 segundo").tag(1.0)
                    Text("2 segundos").tag(2.0)
                    Text("5 segundos").tag(5.0)
                    Text("10 segundos").tag(10.0)
                    Text("30 segundos").tag(30.0)
                    Text("1 minuto").tag(60.0)
                }
                .disabled(!settings.videoCopiesSummary)
                Picker("Detener la grabación a los", selection: $settings.videoLimit) {
                    Text("Sin límite").tag(0.0)
                    Text("10 segundos").tag(10.0)
                    Text("30 segundos").tag(30.0)
                    Text("1 minuto").tag(60.0)
                    Text("5 minutos").tag(300.0)
                }
                Picker("Cuadros por segundo", selection: $settings.videoFPS) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
            }
            Section("Mostrar en el video") {
                Toggle("Cursor", isOn: $settings.videoCursor)
                Toggle("Clics", isOn: $settings.videoClicks)
                Toggle("Teclas", isOn: $settings.videoKeys)
                Toggle("Cámara", isOn: $settings.videoCamera)
            }
            Section("Sonido") {
                Toggle("Sonido del Mac", isOn: $settings.systemAudio)
                Toggle("Micrófono", isOn: $settings.recordMicrophone)
                    .disabled(!ScreenRecorder.supportsMicrophone)
                if !ScreenRecorder.supportsMicrophone {
                    Text("Requiere macOS 15 o más nuevo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
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

/// Todas las capturas guardadas, con filtro y borrado a la Papelera.
private struct HistoryView: View {
    enum Filter: String, CaseIterable {
        case all = "Todo"
        case images = "Capturas"
        case videos = "Videos"
    }

    let onOpen: (URL) -> Void
    @State private var files: [URL] = []
    @State private var filter = Filter.all

    private var visible: [URL] {
        files.filter {
            switch filter {
            case .all: return true
            case .images: return $0.pathExtension == "png"
            case .videos: return $0.pathExtension == "mp4"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mostrar", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.vertical, 12)

            if visible.isEmpty {
                Text("Aún no hay capturas aquí.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(visible, id: \.self) { file in
                            HistoryTile(file: file, onOpen: onOpen, onChange: reload)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 360, idealHeight: 520)
        .onAppear(perform: reload)
    }

    private func reload() {
        files = Recents.files(limit: 500)
    }
}

private struct HistoryTile: View {
    let file: URL
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

    var body: some View {
        Button {
            onOpen(file)
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: file.pathExtension == "mp4" ? "film" : "photo")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 160, height: 100)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(dateText)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.pathExtension == "mp4" ? "Video" : "Captura") del \(dateText)")
        .task {
            // Se decodifica aparte: quinientas capturas no deben trabar la ventana.
            let url = file
            preview = await Task.detached(priority: .utility) { Recents.preview(of: url) }.value
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
}

/// Crea y recuerda las dos ventanas de la app.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private var settingsTabs: NSTabViewController?
    private var welcomeWindow: NSWindow?

    func showSettings() {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for pane in SettingsPane.allCases {
                let host = NSHostingController(rootView: SettingsView(settings: .shared, pane: pane))
                host.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: host)
                item.label = pane.title
                item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.title = SettingsPane.general.title
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            settingsTabs = tabs
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private var historyWindow: NSWindow?

    func showHistory(onOpen: @escaping (URL) -> Void) {
        let host = NSHostingController(rootView: HistoryView(onOpen: onOpen))
        historyWindow?.close()
        let window = NSWindow(contentViewController: host)
        window.title = "Historial"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(host.view.fittingSize)
        window.center()
        historyWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        settingsTabs?.selectedTabViewItemIndex = index
    }

    func closeAll() {
        settingsWindow?.close()
        welcomeWindow?.close()
        settingsWindow = nil
        settingsTabs = nil
        welcomeWindow = nil
        historyWindow?.close()
        historyWindow = nil
    }
    #endif
}

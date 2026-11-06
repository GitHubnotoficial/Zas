import AppKit
import ServiceManagement
import SwiftUI

/// Captura un atajo nuevo: al hacer clic escucha la siguiente combinación de teclas.
final class ShortcutRecorderButton: NSButton {
    var onChange: ((Shortcut) -> Void)?

    var shortcut: Shortcut {
        didSet { refreshTitle() }
    }

    private var monitor: Any?

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
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
        refreshTitle()
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
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        refreshTitle()
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

private struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Abrir Zas al iniciar sesión", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                Toggle("Sonido al capturar", isOn: $settings.playSound)
                LabeledContent("Guardar en") {
                    HStack(spacing: 8) {
                        Text(displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Cambiar…", action: chooseFolder)
                    }
                }
                Picker("Mostrar miniatura durante", selection: $settings.thumbnailSeconds) {
                    Text("3 segundos").tag(3.0)
                    Text("6 segundos").tag(6.0)
                    Text("10 segundos").tag(10.0)
                    Text("30 segundos").tag(30.0)
                }
            }

            Section("Atajos") {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutField(action: action, settings: settings)
                            .frame(width: 130, height: 24)
                    }
                }
                HStack {
                    Spacer()
                    Button("Restablecer atajos") {
                        settings.resetShortcuts()
                    }
                }
            }

            Section("Video") {
                Toggle("Grabar con micrófono", isOn: $settings.recordMicrophone)
                    .disabled(!ScreenRecorder.supportsMicrophone)
                if !ScreenRecorder.supportsMicrophone {
                    Text("Requiere macOS 15 o más nuevo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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

private struct WelcomeView: View {
    let hasPermission: Bool
    let openSettings: () -> Void
    let relaunch: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
                .padding(.top, 28)

            Text(hasPermission ? "Zas está listo" : "Un permiso y listo")
                .font(.system(size: 22, weight: .bold))
                .padding(.top, 12)

            Text(hasPermission
                ? "Vive en la barra de menú, arriba a la derecha."
                : "macOS exige autorizar la Grabación de pantalla para poder capturar. Zas guarda todo en tu Mac y no envía nada a internet.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 36)

            VStack(spacing: 0) {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    HStack {
                        Image(systemName: action.symbol)
                            .frame(width: 22)
                            .foregroundStyle(.secondary)
                        Text(action.title)
                            .font(.system(size: 13))
                        Spacer()
                        Text(Settings.shared.shortcut(for: action).displayString)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    if action != HotKeyAction.allCases.last {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .padding(.horizontal, 28)
            .padding(.top, 20)

            Group {
                if hasPermission {
                    Button("Empezar", action: dismiss)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                } else {
                    VStack(spacing: 8) {
                        Button(action: openSettings) {
                            Text("Abrir Ajustes").frame(maxWidth: .infinity)
                        }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)

                        Button(action: relaunch) {
                            Text("Ya lo activé, reiniciar Zas").frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    }
                    .padding(.horizontal, 28)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(width: 400)
    }
}

/// Crea y recuerda las dos ventanas de la app.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: .shared))
            let window = NSWindow(contentViewController: host)
            window.title = "Ajustes de Zas"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // SwiftUI calcula el tamaño tarde: hay que pedirlo antes de centrar.
            window.setContentSize(host.view.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
    func closeAll() {
        settingsWindow?.close()
        welcomeWindow?.close()
        settingsWindow = nil
        welcomeWindow = nil
    }
    #endif
}

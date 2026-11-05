import AVFoundation
import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!
    private var menu: NSMenu!

    private let overlay = SelectionOverlay()
    private let thumbnail = ThumbnailController()
    private let pins = PinController()
    private var editors: [AnnotationEditor] = []

    private var recorder: ScreenRecorder?
    private var isStopping = false
    private var recordingStart = Date()
    private var recordingTimer: Timer?
    private var recordingBorder: NSPanel?
    private var imageGenerator: AVAssetImageGenerator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        registerHotKeys()
        thumbnail.onAnnotate = { [weak self] image, file in
            self?.openEditor(image: image, file: file)
        }
        thumbnail.onPin = { [weak self] image in
            self?.pins.pin(image)
        }
        _ = Capture.folder
        _ = hasScreenPermission()
    }

    // MARK: - Menú y atajos

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIdleIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleRecording)

        menu = NSMenu()
        addItem("Capturar área", #selector(captureRegion), key: "2")
        addItem("Capturar pantalla", #selector(captureFullScreen), key: "1")
        addItem("Capturar ventana…", #selector(captureWindow), key: "")
        addItem("Copiar texto de la pantalla", #selector(captureText), key: "7")
        menu.addItem(.separator())
        addItem("Grabar video", #selector(toggleRecording), key: "6")
        menu.addItem(.separator())
        addItem("Abrir carpeta de capturas", #selector(openFolder), key: "")
        loginItem = addItem("Abrir al iniciar sesión", #selector(toggleLaunchAtLogin), key: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        addItem("Salir de Zas", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key == "q" ? [.command] : [.command, .shift]
        item.target = self
        menu.addItem(item)
        return item
    }

    private func registerHotKeys() {
        let modifiers = cmdKey | shiftKey
        HotKeys.shared.register(keyCode: kVK_ANSI_2, modifiers: modifiers) { [weak self] in
            self?.captureRegion()
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_1, modifiers: modifiers) { [weak self] in
            self?.captureFullScreen()
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_6, modifiers: modifiers) { [weak self] in
            self?.toggleRecording()
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_7, modifiers: modifiers) { [weak self] in
            self?.captureText()
        }
    }

    private func setIdleIcon() {
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Zas")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.contentTintColor = nil
    }

    // MARK: - Capturas

    @objc private func captureRegion() {
        guard canStartCapture(), hasScreenPermission() else { return }
        thumbnail.hide()
        overlay.begin(mode: .screenshot) { [weak self] selection in
            guard let selection else { return }
            self?.snap(selection)
        }
    }

    @objc private func captureFullScreen() {
        guard canStartCapture(), hasScreenPermission() else { return }
        thumbnail.hide()
        snap(.fullScreen(.underMouse))
    }

    @objc private func captureWindow() {
        guard canStartCapture(), hasScreenPermission() else { return }
        thumbnail.hide()
        takeScreenshot(arguments: ["-x", "-i", "-w", "-o"])
    }

    @objc private func captureText() {
        guard canStartCapture(), hasScreenPermission() else { return }
        thumbnail.hide()
        overlay.begin(mode: .text) { [weak self] selection in
            guard let selection else { return }
            self?.readText(selection)
        }
    }

    private func readText(_ selection: Selection) {
        let region = Capture.regionArgument(selection.globalTopLeftRect)
        let url = Capture.temporaryFileURL()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            Capture.run(arguments: ["-x", region], to: url) { [weak self] succeeded in
                guard succeeded else { return }
                TextReader.read(from: url) { text in
                    self?.finishText(text, imageURL: url)
                }
            }
        }
    }

    private func finishText(_ text: String, imageURL: URL) {
        guard !text.isEmpty else {
            showError("No encontré texto", "Prueba seleccionando un área con letras más grandes o más claras.")
            return
        }
        Capture.copyText(text)
        NSSound(named: NSSound.Name("Tink"))?.play()
        if let image = NSImage(contentsOf: imageURL) {
            thumbnail.show(image: image, file: imageURL, kind: .text)
        }
    }

    private func openEditor(image: NSImage, file: URL) {
        let editor = AnnotationEditor(image: image, file: file)
        editor.onFinish = { [weak self] newImage, newFile in
            NSSound(named: NSSound.Name("Tink"))?.play()
            self?.thumbnail.show(image: newImage, file: newFile, kind: .screenshot)
        }
        // Se suelta después de cerrar, para que el editor siga vivo mientras termina.
        editor.onClose = { [weak self, weak editor] in
            Task { @MainActor in
                self?.editors.removeAll { $0 === editor }
            }
        }
        editors.append(editor)
        editor.show()
    }

    private func canStartCapture() -> Bool {
        !overlay.isActive && recorder == nil
    }

    private func snap(_ selection: Selection) {
        let region = Capture.regionArgument(selection.globalTopLeftRect)
        // Pausa corta para que las ventanas de Zas ya no salgan en la imagen.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.takeScreenshot(arguments: ["-x", region])
        }
    }

    private func takeScreenshot(arguments: [String]) {
        let url = Capture.newFileURL(extension: "png")
        Capture.run(arguments: arguments, to: url) { [weak self] succeeded in
            guard succeeded, let image = Capture.copyImage(at: url) else { return }
            NSSound(named: NSSound.Name("Tink"))?.play()
            self?.thumbnail.show(image: image, file: url, kind: .screenshot)
        }
    }

    // MARK: - Video

    @objc private func toggleRecording() {
        if recorder != nil {
            stopRecording()
            return
        }
        guard !overlay.isActive, hasScreenPermission() else { return }
        thumbnail.hide()
        overlay.begin(mode: .recording) { [weak self] selection in
            guard let selection else { return }
            self?.startRecording(selection)
        }
    }

    private func startRecording(_ selection: Selection) {
        guard let displayID = selection.screen.displayID else { return }

        let newRecorder = ScreenRecorder()
        newRecorder.onUnexpectedStop = { [weak self] _ in
            self?.stopRecording()
        }
        recorder = newRecorder

        let rect = selection.rect
        let scale = selection.screen.backingScaleFactor
        let url = Capture.newFileURL(extension: "mp4")

        Task { @MainActor in
            do {
                try await newRecorder.start(displayID: displayID, rect: rect, scale: scale, to: url)
                self.showRecordingUI(selection)
            } catch {
                self.recorder = nil
                self.showError("No se pudo iniciar la grabación", error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        guard let recorder, !isStopping, recordingTimer != nil else { return }
        isStopping = true
        hideRecordingUI()

        Task { @MainActor in
            let url = await recorder.stop()
            self.recorder = nil
            self.isStopping = false
            if let url {
                self.finishVideo(url)
            } else {
                self.showError("No se pudo guardar el video", "La grabación no generó ningún archivo.")
            }
        }
    }

    private func finishVideo(_ url: URL) {
        Capture.copyFile(at: url)
        NSSound(named: NSSound.Name("Tink"))?.play()

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 520, height: 360)
        generator.requestedTimeToleranceAfter = .positiveInfinity
        imageGenerator = generator

        generator.generateCGImageAsynchronously(for: .zero) { [weak self] cgImage, _, _ in
            Task { @MainActor in
                let image: NSImage
                if let cgImage {
                    image = NSImage(cgImage: cgImage, size: .zero)
                } else {
                    image = NSImage(systemSymbolName: "film", accessibilityDescription: "Video") ?? NSImage()
                }
                self?.thumbnail.show(image: image, file: url, kind: .video)
                self?.imageGenerator = nil
            }
        }
    }

    private func showRecordingUI(_ selection: Selection) {
        // Sin menú, el clic en la barra llama a toggleRecording y detiene.
        statusItem.menu = nil
        statusItem.button?.image = NSImage(
            systemSymbolName: "stop.circle.fill",
            accessibilityDescription: "Detener grabación"
        )
        statusItem.button?.contentTintColor = .systemRed
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = " 0:00"

        recordingStart = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsedTime()
            }
        }

        if !selection.isFullScreen {
            showRecordingBorder(around: selection.appKitRect)
        }
    }

    private func hideRecordingUI() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingBorder?.orderOut(nil)
        recordingBorder = nil
        setIdleIcon()
        statusItem.menu = menu
    }

    private func updateElapsedTime() {
        let seconds = Int(Date().timeIntervalSince(recordingStart))
        statusItem.button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
    }

    private func showRecordingBorder(around rect: CGRect) {
        let panel = NSPanel(
            contentRect: rect.insetBy(dx: -3, dy: -3),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemRed.cgColor
        view.layer?.borderWidth = 2
        panel.contentView = view
        panel.orderFrontRegardless()
        recordingBorder = panel
    }

    // MARK: - Otras acciones

    @objc private func openFolder() {
        NSWorkspace.shared.open(Capture.folder)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showError("No se pudo cambiar esta opción", error.localizedDescription)
        }
        loginItem.state = service.status == .enabled ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Permisos y errores

    private func hasScreenPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Zas necesita permiso de Grabación de pantalla"
        alert.informativeText = """
        1. Pulsa "Abrir Ajustes" y activa Zas en la lista.
        2. Vuelve a esta ventana y pulsa "Reiniciar Zas".
        """
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Reiniciar Zas")
        alert.addButton(withTitle: "Ahora no")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            CGRequestScreenCaptureAccess()
            let settings = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: settings) {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
        return false
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

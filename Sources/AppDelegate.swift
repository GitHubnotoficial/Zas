import AVFoundation
import AppKit
import Carbon
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var actionItems: [HotKeyAction: NSMenuItem] = [:]
    private var settingsObserver: AnyCancellable?

    private let overlay = SelectionOverlay()
    private let thumbnail = ThumbnailController()
    private let pins = PinController()
    private let windows = WindowCoordinator()
    private var editors: [AnnotationEditor] = []

    private var hotKeyIDs: [UInt32] = []
    private var conflictingShortcuts: [HotKeyAction] = []

    private var recorder: ScreenRecorder?
    private var isStopping = false
    private var recordingStart = Date()
    private var recordingTimer: Timer?
    private var recordingBorder: NSPanel?
    private var imageGenerator: AVAssetImageGenerator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusMenu()
        registerHotKeys()

        thumbnail.onAnnotate = { [weak self] image, file in
            self?.openEditor(image: image, file: file)
        }
        thumbnail.onPin = { [weak self] image in
            self?.pins.pin(image)
        }

        // Los atajos se aplican en cuanto cambian en Ajustes.
        settingsObserver = Settings.shared.$shortcuts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.registerHotKeys()
            }

        _ = Capture.folder

        let hasPermission = CGPreflightScreenCaptureAccess()
        if !hasPermission {
            showPermissionWindow()
        } else if !Settings.shared.welcomed {
            windows.showWelcome(hasPermission: true, openSettings: {}, relaunch: {})
        }
        if hasPermission {
            Settings.shared.welcomed = true
        }
    }

    // MARK: - Menús

    /// La app no se ve en el Dock, pero este menú da ⌘Z, ⌘C y ⌘V a los campos de texto.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Salir de Zas", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Archivo")
        fileMenu.addItem(withTitle: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edición")
        editMenu.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIdleIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleRecording)

        menu = NSMenu()
        addActionItem(.region, #selector(captureRegion))
        addActionItem(.fullScreen, #selector(captureFullScreen))
        addActionItem(.text, #selector(captureText))
        menu.addItem(.separator())
        addActionItem(.record, #selector(toggleRecording))
        menu.addItem(.separator())
        addItem("Abrir carpeta de capturas", symbol: "folder", #selector(openFolder))
        let settings = addItem("Ajustes…", symbol: "gearshape", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(.separator())
        let quit = addItem("Salir de Zas", symbol: nil, #selector(quit))
        quit.keyEquivalent = "q"
        statusItem.menu = menu
    }

    private func addActionItem(_ action: HotKeyAction, _ selector: Selector) {
        let item = addItem(action.title, symbol: action.symbol, selector)
        actionItems[action] = item
    }

    @discardableResult
    private func addItem(_ title: String, symbol: String?, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(item)
        return item
    }

    private func registerHotKeys() {
        hotKeyIDs.forEach { HotKeys.shared.unregister($0) }
        hotKeyIDs.removeAll()
        conflictingShortcuts.removeAll()

        for action in HotKeyAction.allCases {
            let shortcut = Settings.shared.shortcut(for: action)
            let id = HotKeys.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                self?.perform(action)
            }
            if let id {
                hotKeyIDs.append(id)
            } else {
                conflictingShortcuts.append(action)
            }

            actionItems[action]?.keyEquivalent = shortcut.menuKeyEquivalent
            actionItems[action]?.keyEquivalentModifierMask = shortcut.menuModifiers
        }
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .region: captureRegion()
        case .fullScreen: captureFullScreen()
        case .text: captureText()
        case .record: toggleRecording()
        }
    }

    private func setIdleIcon() {
        statusItem.button?.image = Self.menuBarIcon
        statusItem.button?.title = ""
        statusItem.button?.contentTintColor = nil
    }

    /// Icono propio de la barra: visor con un rayo. Se adapta a barra clara y oscura.
    private static var menuBarIcon: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let length: CGFloat = 4.5
            let inset: CGFloat = 1.5
            let box = rect.insetBy(dx: inset, dy: inset)
            let corners = NSBezierPath()
            corners.lineWidth = 1.6
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round

            corners.move(to: NSPoint(x: box.minX, y: box.minY + length))
            corners.line(to: NSPoint(x: box.minX, y: box.minY))
            corners.line(to: NSPoint(x: box.minX + length, y: box.minY))

            corners.move(to: NSPoint(x: box.maxX - length, y: box.minY))
            corners.line(to: NSPoint(x: box.maxX, y: box.minY))
            corners.line(to: NSPoint(x: box.maxX, y: box.minY + length))

            corners.move(to: NSPoint(x: box.maxX, y: box.maxY - length))
            corners.line(to: NSPoint(x: box.maxX, y: box.maxY))
            corners.line(to: NSPoint(x: box.maxX - length, y: box.maxY))

            corners.move(to: NSPoint(x: box.minX + length, y: box.maxY))
            corners.line(to: NSPoint(x: box.minX, y: box.maxY))
            corners.line(to: NSPoint(x: box.minX, y: box.maxY - length))

            NSColor.black.setStroke()
            corners.stroke()

            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 10.2, y: 14))
            bolt.line(to: NSPoint(x: 5.8, y: 8.3))
            bolt.line(to: NSPoint(x: 8.6, y: 8.3))
            bolt.line(to: NSPoint(x: 7.8, y: 4))
            bolt.line(to: NSPoint(x: 12.2, y: 9.7))
            bolt.line(to: NSPoint(x: 9.4, y: 9.7))
            bolt.close()
            NSColor.black.setFill()
            bolt.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Zas"
        return image
    }

    // MARK: - Capturas

    @objc private func captureRegion() {
        guard canStartCapture(), ensurePermission() else { return }
        thumbnail.suspend()
        overlay.begin(mode: .screenshot) { [weak self] selection in
            guard let self else { return }
            guard let selection else {
                self.thumbnail.resume()
                return
            }
            self.snap(selection)
        }
    }

    @objc private func captureFullScreen() {
        guard canStartCapture(), ensurePermission() else { return }
        thumbnail.suspend()
        snap(.fullScreen(.underMouse))
    }

    @objc private func captureText() {
        guard canStartCapture(), ensurePermission() else { return }
        thumbnail.suspend()
        overlay.begin(mode: .text) { [weak self] selection in
            guard let self else { return }
            guard let selection else {
                self.thumbnail.resume()
                return
            }
            self.readText(selection)
        }
    }

    private func canStartCapture() -> Bool {
        !overlay.isActive && recorder == nil
    }

    private func snap(_ selection: Selection) {
        let arguments = selection.captureArguments
        // Pausa corta para que las ventanas de Zas ya no salgan en la imagen.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.takeScreenshot(arguments: arguments)
        }
    }

    private func takeScreenshot(arguments: [String]) {
        let url = Capture.newFileURL(extension: "png")
        Capture.run(arguments: arguments, to: url) { [weak self] succeeded in
            guard let self else { return }
            self.thumbnail.resume()
            guard succeeded else {
                self.showError("No se pudo capturar", "macOS no entregó la imagen. Inténtalo de nuevo.")
                return
            }
            guard let image = Capture.copyImage(at: url) else { return }
            Capture.playSound()
            self.thumbnail.show(image: image, file: url, kind: .screenshot)
        }
    }

    private func readText(_ selection: Selection) {
        let arguments = selection.captureArguments
        let url = Capture.temporaryFileURL()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            Capture.run(arguments: arguments, to: url) { [weak self] succeeded in
                guard succeeded else {
                    self?.thumbnail.resume()
                    return
                }
                TextReader.read(from: url) { text in
                    self?.finishText(text, imageURL: url)
                }
            }
        }
    }

    private func finishText(_ text: String, imageURL: URL) {
        thumbnail.resume()
        guard !text.isEmpty else {
            showError("No encontré texto", "Prueba seleccionando un área con letras más grandes o más claras.")
            return
        }
        Capture.copyText(text)
        Capture.playSound()
        if let image = NSImage(contentsOf: imageURL) {
            thumbnail.show(image: image, file: imageURL, kind: .text)
        }
    }

    private func openEditor(image: NSImage, file: URL) {
        let editor = AnnotationEditor(image: image, file: file)
        editor.onFinish = { [weak self] newImage, newFile in
            Capture.playSound()
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

    // MARK: - Video

    @objc private func toggleRecording() {
        if recorder != nil {
            stopRecording()
            return
        }
        guard !overlay.isActive, ensurePermission() else { return }
        thumbnail.suspend()
        overlay.begin(mode: .recording) { [weak self] selection in
            guard let self else { return }
            guard let selection else {
                self.thumbnail.resume()
                return
            }
            self.startRecording(selection)
        }
    }

    private func startRecording(_ selection: Selection) {
        guard let displayID = selection.screen.displayID else {
            thumbnail.resume()
            return
        }

        let newRecorder = ScreenRecorder()
        newRecorder.onUnexpectedStop = { [weak self] _ in
            self?.stopRecording()
        }
        recorder = newRecorder

        let rect = selection.rect
        let scale = selection.screen.backingScaleFactor
        let microphone = Settings.shared.recordMicrophone
        let url = Capture.newFileURL(extension: "mp4")

        Task { @MainActor in
            do {
                try await newRecorder.start(
                    displayID: displayID,
                    rect: rect,
                    scale: scale,
                    microphone: microphone,
                    to: url
                )
                self.showRecordingUI(selection)
            } catch {
                self.recorder = nil
                self.thumbnail.resume()
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
            self.thumbnail.resume()
            if let url {
                self.finishVideo(url)
            } else {
                self.showError("No se pudo guardar el video", "La grabación no generó ningún archivo.")
            }
        }
    }

    private func finishVideo(_ url: URL) {
        Capture.copyFile(at: url)
        Capture.playSound()

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 560, height: 400)
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
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.contentTintColor = .systemRed
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
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemRed.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 3
        panel.contentView = view
        panel.orderFrontRegardless()
        recordingBorder = panel
    }

    // MARK: - Otras acciones

    @objc private func openFolder() {
        NSWorkspace.shared.open(Capture.folder)
    }

    @objc private func openSettings() {
        windows.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Permisos y errores

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        showPermissionWindow()
        return false
    }

    private func showPermissionWindow() {
        windows.showWelcome(
            hasPermission: false,
            openSettings: {
                // Hace que Zas aparezca en la lista de Ajustes.
                CGRequestScreenCaptureAccess()
                let settings = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                if let url = URL(string: settings) {
                    NSWorkspace.shared.open(url)
                }
            },
            relaunch: { [weak self] in
                self?.relaunch()
            }
        )
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

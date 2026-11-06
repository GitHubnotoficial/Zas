@preconcurrency import AVFoundation
import AppKit
import Carbon
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var actionItems: [HotKeyAction: NSMenuItem] = [:]
    private let recentsStrip = RecentsStripView()
    private var lastCaptureRect: CGRect?
    private var lastSelection: Selection?
    private var trimWindows: [VideoTrimWindow] = []
    private var scrollStitcher: ScrollStitcher?
    private var scrollHotKeys: [UInt32] = []
    private var scrollSelection: Selection?
    private var settingsObserver: AnyCancellable?

    private let overlay = SelectionOverlay()
    private let thumbnail = ThumbnailController()
    private let pins = PinController()
    private let windows = WindowCoordinator()
    private var editors: [AnnotationEditor] = []

    private var hotKeyIDs: [UInt32] = []
    private var captureInFlight = false

    private var recorder: ScreenRecorder?
    private var effects: RecordingEffects?
    private var isStopping = false
    private var recordingStart = Date()
    private var recordingTimer: Timer?
    private var recordingBorder: NSPanel?
    private var imageGenerators: [AVAssetImageGenerator] = []
    private var recordingActivity: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Capture.clearScratch()
        buildMainMenu()
        buildStatusMenu()
        registerHotKeys()
        listenForTermination()
        enableLaunchAtLoginOnce()

        thumbnail.onAnnotate = { [weak self] image, file in
            self?.openEditor(image: image, file: file)
        }
        thumbnail.onPin = { [weak self] image in
            self?.pins.pin(image)
        }
        thumbnail.onSelectText = { [weak self] image, file in
            self?.openEditor(image: image, file: file, selectingText: true)
        }
        thumbnail.onTrim = { [weak self] video in
            self?.trim(video)
        }
        thumbnail.onGif = { [weak self] video in
            self?.makeGif(from: video)
        }
        thumbnail.onSummarize = { [weak self] video in
            self?.copySummary(of: video)
        }

        // Los atajos se aplican en cuanto cambian en Ajustes.
        settingsObserver = Settings.shared.$shortcuts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.registerHotKeys()
            }

        ShortcutRecorderButton.onRecordingChanged = { [weak self] recording in
            if recording {
                self?.unregisterHotKeys()
            } else {
                self?.registerHotKeys()
            }
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

    /// Si se cierra la app mientras graba, primero termina el video: si no, quedaría inservible.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if editors.contains(where: \.hasUnsavedWork) {
            let alert = NSAlert()
            alert.messageText = "¿Salir sin copiar?"
            alert.informativeText = "Hay marcas sin copiar en el editor. Se perderán."
            let quit = alert.addButton(withTitle: "Salir")
            quit.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancelar")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn {
                return .terminateCancel
            }
        }
        guard let recorder else { return .terminateNow }

        let alreadyStopping = isStopping
        isStopping = true
        hideRecordingUI()
        Task { @MainActor in
            if alreadyStopping {
                while self.recorder != nil {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            } else {
                _ = await recorder.stop()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Capture.clearScratch()
    }

    /// El instalador cierra Zas con esta señal: así un video en curso termina bien
    /// y macOS no le pide a Terminal permiso para controlar otra app.
    private func listenForTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignal = source
    }

    /// Una app de barra de menú que no abre al encender deja los atajos muertos sin avisar.
    private func enableLaunchAtLoginOnce() {
        guard !Settings.shared.loginItemConfigured,
              Bundle.main.bundlePath.hasSuffix("/Applications/Zas.app")
        else { return }
        Settings.shared.loginItemConfigured = true
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Zas: no se pudo activar el inicio de sesión: %@", error.localizedDescription)
        }
    }

    // MARK: - Menús

    /// La app no se ve en el Dock, pero este menú da ⌘Z, ⌘C y ⌘V a los campos de texto.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Acerca de Zas", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Salir de Zas", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Archivo")
        fileMenu.addItem(withTitle: "Guardar copia", action: Selector(("menuSave")), keyEquivalent: "s")
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

        // Sin destino fijo: solo se activan cuando el editor está al frente.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Ver")
        viewMenu.addItem(withTitle: "Acercar", action: Selector(("zoomIn")), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Alejar", action: Selector(("zoomOut")), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Ajustar a la ventana", action: Selector(("zoomFit")), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Seleccionar texto", action: Selector(("toggleTextMode")), keyEquivalent: "")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let toolsItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "Herramientas")
        for tool in AnnotationTool.allCases where tool != .picture {
            let item = toolsMenu.addItem(withTitle: tool.label, action: Selector(("menuTool:")), keyEquivalent: "")
            item.tag = tool.rawValue
        }
        toolsItem.submenu = toolsMenu
        main.addItem(toolsItem)

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
        addActionItem(.timed, #selector(captureTimed))
        addActionItem(.scroll, #selector(captureScroll))
        addActionItem(.text, #selector(captureText))
        addActionItem(.record, #selector(toggleRecording))
        addActionItem(.again, #selector(captureAgain))
        menu.addItem(.separator())
        let recents = NSMenuItem()
        recents.view = recentsStrip
        recentsStrip.onPick = { [weak self] file in
            self?.reopenRecent(file)
        }
        menu.addItem(recents)
        menu.delegate = self
        menu.addItem(.separator())
        addItem("Historial", symbol: nil, #selector(openHistory))
        addItem("Abrir proyecto…", symbol: nil, #selector(chooseProject))
        let settings = addItem("Ajustes…", symbol: nil, #selector(openSettings))
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

    private func unregisterHotKeys() {
        hotKeyIDs.forEach { HotKeys.shared.unregister($0) }
        hotKeyIDs.removeAll()
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        var conflicts: Set<HotKeyAction> = []

        for action in HotKeyAction.allCases {
            let shortcut = Settings.shared.shortcut(for: action)
            let id = HotKeys.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                self?.perform(action)
            }
            if let id {
                hotKeyIDs.append(id)
            } else {
                conflicts.insert(action)
            }

            actionItems[action]?.keyEquivalent = shortcut.menuKeyEquivalent
            actionItems[action]?.keyEquivalentModifierMask = shortcut.menuModifiers
        }
        Settings.shared.conflicts = conflicts
    }

    private func perform(_ action: HotKeyAction) {
        // Repetir el atajo con la selección abierta la cancela.
        if overlay.isActive {
            overlay.cancel()
            return
        }
        switch action {
        case .region: captureRegion()
        case .fullScreen: captureFullScreen()
        case .timed: captureTimed()
        case .scroll: captureScroll()
        case .again: captureAgain()
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

    /// Repite la última área sin volver a elegirla.
    @objc private func captureAgain() {
        guard canStartCapture(), ensurePermission() else { return }
        guard let lastSelection else {
            Toast.shared.show("Aún no hay una captura que repetir.")
            return
        }
        thumbnail.suspend()
        snap(lastSelection)
    }

    @objc private func captureRegion() {
        beginSelection(.screenshot)
    }

    /// Todas las capturas pasan por aquí: la barra de vidrio puede cambiar el modo a medio camino.
    private func beginSelection(_ mode: SelectionMode) {
        guard canStartCapture(), ensurePermission() else { return }
        thumbnail.suspend()
        overlay.begin(mode: mode) { [weak self] selection in
            guard let self else { return }
            guard let selection else {
                self.thumbnail.resume()
                return
            }
            switch self.overlay.mode {
            case .screenshot: self.snap(selection)
            case .text: self.readText(selection)
            case .recording: self.startRecording(selection)
            case .timed: self.countDown(selection)
            case .scroll: self.startScroll(selection)
            }
        }
    }

    @objc private func captureFullScreen() {
        guard canStartCapture(), ensurePermission() else { return }
        thumbnail.suspend()
        snap(.fullScreen(.underMouse))
    }

    @objc private func captureScroll() {
        beginSelection(.scroll)
    }

    @objc private func captureText() {
        beginSelection(.text)
    }

    /// Primero se elige el área y después corre el tiempo: da margen para abrir un menú o un aviso.
    @objc private func captureTimed() {
        beginSelection(.timed)
    }

    private func countDown(_ selection: Selection) {
        captureInFlight = true
        Task { @MainActor in
            for second in [3, 2, 1] {
                Toast.shared.show("\(second)", seconds: 2, large: true)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // El aviso no debe salir en la imagen.
            Toast.shared.hide()
            self.snap(selection)
        }
    }

    private func canStartCapture() -> Bool {
        if recorder != nil {
            let stop = Settings.shared.shortcut(for: .record).displayString
            Toast.shared.show("Grabando. \(stop) para detener")
            return false
        }
        return !overlay.isActive && !captureInFlight
    }

    private func snap(_ selection: Selection) {
        captureInFlight = true
        let arguments = selection.captureArguments
        let pointSize = selection.imagePointSize
        // Una captura de pantalla completa no tiene de dónde "salir".
        lastCaptureRect = selection.isFullScreen ? nil : selection.appKitRect
        lastSelection = selection
        // Repetir debe capturar de nuevo, no volver a guardar la imagen congelada.
        lastSelection?.frozen = nil
        // Con la pantalla congelada, la imagen ya existe.
        if let frozen = selection.frozen {
            let url = Capture.newFileURL(extension: "png")
            let saved = Capture.writePNG(frozen, to: url, pointSize: pointSize)
            finishCapture(url: url, succeeded: saved, pointSize: pointSize)
            return
        }
        // Pausa corta para que las ventanas de Zas ya no salgan en la imagen.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.takeScreenshot(arguments: arguments, pointSize: pointSize)
        }
    }

    private func takeScreenshot(arguments: [String], pointSize: CGSize) {
        let url = Capture.newFileURL(extension: "png")
        Capture.run(arguments: arguments, to: url) { [weak self] succeeded in
            self?.finishCapture(url: url, succeeded: succeeded, pointSize: pointSize)
        }
    }

    private func finishCapture(url: URL, succeeded: Bool, pointSize: CGSize) {
        captureInFlight = false
        thumbnail.resume()
        do {
            guard succeeded else {
                showError("No se pudo capturar", "macOS no entregó la imagen. Inténtalo de nuevo.")
                return
            }
            guard let image = Capture.copyImage(at: url, pointSize: pointSize) else {
                showError("No se pudo copiar", "macOS entregó un archivo que no se puede leer. Inténtalo de nuevo.")
                return
            }
            Capture.playSound()
            thumbnail.show(image: image, file: url, kind: .screenshot, from: lastCaptureRect)
        }
    }

    // MARK: - Captura con desplazamiento

    /// Va tomando tramos mientras se desplaza el contenido, y los une al terminar.
    private func startScroll(_ selection: Selection) {
        captureInFlight = true
        scrollStitcher = ScrollStitcher()
        scrollSelection = selection
        if !selection.isFullScreen {
            showRecordingBorder(around: selection.appKitRect)
        }
        Toast.shared.show("Desplázate. Enter termina, Esc cancela.", seconds: 4)
        if let done = HotKeys.shared.register(keyCode: UInt32(kVK_Return), modifiers: 0, action: { [weak self] in
            self?.finishScroll(save: true)
        }) {
            scrollHotKeys.append(done)
        }
        if let cancel = HotKeys.shared.register(keyCode: UInt32(kVK_Escape), modifiers: 0, action: { [weak self] in
            self?.finishScroll(save: false)
        }) {
            scrollHotKeys.append(cancel)
        }
        // Espera a que las ventanas de Zas salgan de la imagen, igual que una captura normal.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.takeScrollPiece()
        }
    }

    private func takeScrollPiece() {
        guard scrollStitcher != nil, let selection = scrollSelection else { return }
        let url = Capture.temporaryFileURL()
        Capture.run(arguments: ["-x", Capture.regionArgument(selection.globalTopLeftRect)], to: url) { [weak self] _ in
            guard let self else { return }
            if let image = Capture.image(at: url) {
                self.scrollStitcher?.add(image)
                if self.scrollStitcher?.lostTrack == true {
                    Toast.shared.show("Muy rápido. Sube un poco.", seconds: 1.5)
                }
            }
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                self.takeScrollPiece()
            }
        }
    }

    private func finishScroll(save: Bool) {
        guard var stitcher = scrollStitcher, let selection = scrollSelection else { return }
        scrollStitcher = nil
        scrollSelection = nil
        scrollHotKeys.forEach { HotKeys.shared.unregister($0) }
        scrollHotKeys.removeAll()
        recordingBorder?.orderOut(nil)
        recordingBorder = nil
        Toast.shared.hide()

        guard save else {
            captureInFlight = false
            thumbnail.resume()
            return
        }
        // Un último tramo, para no perder lo que se desplazó justo antes de Enter.
        let url = Capture.temporaryFileURL()
        Capture.run(arguments: ["-x", Capture.regionArgument(selection.globalTopLeftRect)], to: url) { [weak self] _ in
            if let image = Capture.image(at: url) {
                stitcher.add(image)
            }
            try? FileManager.default.removeItem(at: url)
            self?.saveScroll(stitcher, selection: selection)
        }
    }

    private func saveScroll(_ stitcher: ScrollStitcher, selection: Selection) {
        guard let image = stitcher.composed() else {
            captureInFlight = false
            thumbnail.resume()
            Toast.shared.show("No se pudo unir la captura.")
            return
        }
        let scale = CGFloat(stitcher.width) / max(selection.rect.width, 1)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let url = Capture.newFileURL(extension: "png")
        lastCaptureRect = nil
        finishCapture(url: url, succeeded: Capture.writePNG(image, to: url, pointSize: size), pointSize: size)
    }

    // MARK: - Herramientas de video

    private func trim(_ video: URL) {
        let window = VideoTrimWindow(video: video)
        window.onFinish = { [weak self] output in
            self?.showVideoThumbnail(output, inClipboard: true)
            Capture.copyFile(at: output)
        }
        window.onClose = { [weak self, weak window] in
            Task { @MainActor in
                self?.trimWindows.removeAll { $0 === window }
            }
        }
        trimWindows.append(window)
        window.show()
    }

    private func makeGif(from video: URL) {
        Toast.shared.show("Creando el GIF…")
        Task { @MainActor in
            let name = "\(video.deletingPathExtension().lastPathComponent).gif"
            let output = Capture.uniqueURL(in: video.deletingLastPathComponent(), name: name)
            if await GifExporter.export(video: video, to: output) {
                Capture.copyFile(at: output)
                Capture.playSound()
                Toast.shared.show("GIF copiado")
            } else {
                Toast.shared.show("No se pudo crear el GIF.")
            }
        }
    }

    @objc private func chooseProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ZasProject.fileType]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            openProject(url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openProject)
    }

    private func openProject(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let project = try? JSONDecoder().decode(ZasProject.self, from: data),
              let image = project.baseImage()
        else {
            Toast.shared.show("No se pudo abrir ese proyecto.")
            return
        }
        openEditor(image: image, file: url, document: project.document())
    }

    @objc private func openHistory() {
        windows.showHistory { [weak self] file in
            self?.reopenRecent(file)
        }
    }

    private func readText(_ selection: Selection) {
        captureInFlight = true
        let arguments = selection.captureArguments
        let url = Capture.temporaryFileURL()
        if let frozen = selection.frozen, Capture.writePNG(frozen, to: url, pointSize: selection.imagePointSize) {
            TextReader.read(from: url) { [weak self] text in
                self?.finishText(text, imageURL: url)
            }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            Capture.run(arguments: arguments, to: url) { [weak self] succeeded in
                guard succeeded else {
                    self?.captureInFlight = false
                    self?.thumbnail.resume()
                    Toast.shared.show("macOS no entregó la imagen. Inténtalo de nuevo.")
                    return
                }
                TextReader.read(from: url) { text in
                    self?.finishText(text, imageURL: url)
                }
            }
        }
    }

    private func finishText(_ text: String, imageURL: URL) {
        captureInFlight = false
        thumbnail.resume()
        // La imagen muestra lo que había en pantalla: no debe quedarse en disco.
        let image = NSImage(contentsOf: imageURL)
        try? FileManager.default.removeItem(at: imageURL)

        guard !text.isEmpty else {
            Toast.shared.show("No hay texto en esa área")
            return
        }
        Capture.copyText(text)
        Capture.playSound()
        if let image {
            thumbnail.show(image: image, file: imageURL, kind: .text, text: text)
        }
    }

    private func openEditor(image: NSImage, file: URL, selectingText: Bool = false, document: AnnotationDocument? = nil) {
        let editor = AnnotationEditor(image: image, file: file)
        if let document {
            editor.canvas.load(document)
        }
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
        if selectingText {
            editor.openTextMode()
        }
    }

    // MARK: - Video

    @objc private func toggleRecording() {
        if recorder != nil {
            stopRecording()
            return
        }
        beginSelection(.recording)
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
        let settings = Settings.shared
        let overlayEffects = RecordingEffects(screen: selection.screen)
        effects = overlayEffects

        Task { @MainActor in
            await overlayEffects.start(clicks: settings.videoClicks, keys: settings.videoKeys, showsCamera: settings.videoCamera)
            do {
                try await newRecorder.start(
                    displayID: displayID,
                    rect: rect,
                    scale: scale,
                    microphone: microphone,
                    to: url,
                    systemAudio: Settings.shared.systemAudio,
                    fps: Settings.shared.videoFPS,
                    showsCursor: Settings.shared.videoCursor,
                    visibleWindows: overlayEffects.windowIDs
                )
                self.showRecordingUI(selection)
            } catch {
                overlayEffects.stop()
                self.effects = nil
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
                if recorder.microphoneDenied {
                    self.showError(
                        "El video quedó sin voz",
                        "macOS no dio acceso al micrófono. Actívalo en Ajustes del Sistema, Privacidad y seguridad, Micrófono."
                    )
                }
            } else {
                self.showError("No se pudo guardar el video", "La grabación no generó ningún archivo.")
            }
        }
    }

    private func finishVideo(_ url: URL) {
        Capture.copyFile(at: url)
        Capture.playSound()
        let copiesSummary = Settings.shared.videoCopiesSummary
        showVideoThumbnail(url, inClipboard: !copiesSummary)
        if copiesSummary {
            copySummary(of: url)
        }
    }

    /// Crea la imagen con los momentos clave del video y la deja lista para pegar en Claude.
    private func copySummary(of video: URL) {
        Task { @MainActor in
            let result = await VideoSheet.pages(from: video, folder: Capture.imageFolder, every: Settings.shared.videoEvery)
            guard let last = result.files.last, Capture.copyImage(at: last) != nil else {
                Toast.shared.show("No se pudo crear el resumen. El video sigue guardado.")
                return
            }
            self.thumbnail.clipboardChanged()
            if result.files.count > 1 {
                for file in result.files {
                    if let image = NSImage(contentsOf: file) {
                        self.thumbnail.show(image: image, file: file, kind: .screenshot, inClipboard: file == last)
                    }
                }
            }
            let pages = result.files.count > 1 ? " en \(result.files.count) hojas" : ""
            Toast.shared.show("Resumen de \(result.moments) imágenes\(pages) copiado. Pégalo en Claude.")
        }
    }

    private func showVideoThumbnail(_ url: URL, inClipboard: Bool) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 560, height: 400)
        generator.requestedTimeToleranceAfter = .positiveInfinity
        imageGenerators.append(generator)

        generator.generateCGImageAsynchronously(for: .zero) { [weak self] cgImage, _, _ in
            Task { @MainActor in
                let image: NSImage
                if let cgImage {
                    image = NSImage(cgImage: cgImage, size: .zero)
                } else {
                    image = NSImage(systemSymbolName: "film", accessibilityDescription: "Video") ?? NSImage()
                }
                self?.thumbnail.show(image: image, file: url, kind: .video, inClipboard: inClipboard)
                self?.imageGenerators.removeAll { $0 === generator }
            }
        }
    }

    private func showRecordingUI(_ selection: Selection) {
        // Sin menú, el clic en la barra llama a toggleRecording y detiene.
        statusItem.menu = nil
        // Colores fijos: la barra de menú ignora el tinte en los iconos de plantilla.
        let stopIcon = NSImage(
            systemSymbolName: "stop.circle.fill",
            accessibilityDescription: "Detener grabación"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        stopIcon?.isTemplate = false
        statusItem.button?.image = stopIcon
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusItem.button?.title = " 0:00"

        recordingStart = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsedTime()
            }
        }

        // Una grabación larga no debe cortarse porque el Mac se duerma.
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "Grabando la pantalla"
        )

        if !selection.isFullScreen {
            showRecordingBorder(around: selection.appKitRect)
        }

        // Zas queda excluida del video, así que este aviso no sale en la grabación.
        let stop = Settings.shared.shortcut(for: .record).displayString
        Toast.shared.show("Grabando. \(stop) para detener", seconds: 3)
    }

    private func hideRecordingUI() {
        effects?.stop()
        effects = nil
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
            self.recordingActivity = nil
        }
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
        let limit = Settings.shared.videoLimit
        if limit > 0, Double(seconds) >= limit {
            stopRecording()
        }
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

    // MARK: - Capturas recientes

    func menuWillOpen(_ menu: NSMenu) {
        recentsStrip.reload(Recents.files(limit: 4))
    }

    private func reopenRecent(_ file: URL) {
        if file.pathExtension == "mp4" {
            Capture.copyFile(at: file)
            Capture.playSound()
            showVideoThumbnail(file, inClipboard: true)
        } else if let image = Capture.copyImage(at: file) {
            Capture.playSound()
            thumbnail.show(image: image, file: file, kind: .screenshot)
        } else {
            Toast.shared.show("Ese archivo ya no existe.")
        }
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

        // En cuanto el permiso se activa en Ajustes, Zas se reinicia sin tener que pedirlo.
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, CGPreflightScreenCaptureAccess() else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.relaunch()
            }
        }
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

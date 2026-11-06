import AVFoundation
import AppKit

/// Pruebas que corren en un Mac real: lógica, captura, video e imágenes de cada pantalla.
/// Solo se compilan con -D ZAS_TEST; no forman parte de la app que se instala.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var passes = 0
    private static var output = URL(fileURLWithPath: "/tmp/zas-escenas")
    private static var keepAlive: [AnyObject] = []

    static func run() {
        if CommandLine.arguments.count > 1 {
            output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await runAll()
            print("RESULTADO: \(passes) correctas, \(failures) fallidas")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }

    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            passes += 1
            print("ok    \(name)")
        } else {
            failures += 1
            print("FALLA \(name)")
        }
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func capture(_ arguments: [String], to url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            Capture.run(arguments: arguments, to: url) { continuation.resume(returning: $0) }
        }
    }

    private static func shoot(_ name: String) async {
        await wait(0.6)
        let url = output.appendingPathComponent("\(name).png")
        let ok = await capture(["-x"], to: url)
        print("escena \(name): \(ok ? "lista" : "SIN IMAGEN")")
    }

    private static func runAll() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zas-pruebas-\(UUID().uuidString)")
        Settings.shared.saveFolder = folder
        Settings.shared.playSound = false

        logic()
        await canvasTests()
        await systemTests()
        await recorderTest()
        await scenes()
    }

    // MARK: - Lógica

    private static func logic() {
        let region = HotKeyAction.region.defaultShortcut
        check(region.displayString == "⇧⌘2", "el atajo se muestra como ⇧⌘2 (\(region.displayString))")
        check(region.menuKeyEquivalent == "2", "equivalente de menú del atajo")
        check(region.menuModifiers == [.command, .shift], "modificadores del atajo")

        let saved: [HotKeyAction: Shortcut] = [.text: Shortcut(keyCode: 5, modifiers: 256)]
        let data = try? JSONEncoder().encode(saved)
        let loaded = data.flatMap { try? JSONDecoder().decode([HotKeyAction: Shortcut].self, from: $0) }
        check(loaded == saved, "los atajos se guardan y se recuperan")

        check(
            Capture.regionArgument(CGRect(x: 10.4, y: 20.6, width: 100, height: 50)) == "-R10,21,100,50",
            "argumento de región"
        )

        let screen = NSScreen.screens[0]
        let selection = Selection(screen: screen, rect: CGRect(x: 40, y: 30, width: 100, height: 80))
        check(selection.globalTopLeftRect == CGRect(x: 40, y: 30, width: 100, height: 80), "coordenadas globales en la pantalla principal")
        check(selection.appKitRect.minY == screen.frame.maxY - 110, "coordenadas de AppKit")
        check(Selection.fullScreen(screen).isFullScreen, "selección de pantalla completa")
        check(!Selection(screen: screen, rect: selection.rect, windowID: 3).isFullScreen, "una ventana no es pantalla completa")
        check(Selection(screen: screen, rect: selection.rect, windowID: 7).captureArguments == ["-x", "-o", "-l7"], "argumentos de captura de ventana")

        let arrow = Annotation(tool: .arrow, color: .red, lineWidth: 5, points: [.zero, CGPoint(x: 100, y: 100)])
        check(arrow.hitTest(CGPoint(x: 50, y: 50)), "se puede tocar una flecha")
        check(!arrow.hitTest(CGPoint(x: 80, y: 10)), "tocar lejos de la flecha no la selecciona")
        let box = Annotation(tool: .rectangle, color: .red, lineWidth: 5, points: [.zero, CGPoint(x: 200, y: 200)])
        check(box.hitTest(CGPoint(x: 1, y: 100)), "se puede tocar el borde de un cuadro")
        check(!box.hitTest(CGPoint(x: 100, y: 100)), "el centro de un cuadro deja pasar el clic")
        check(abs(Annotation.distance(from: CGPoint(x: 0, y: 5), toSegment: .zero, CGPoint(x: 10, y: 0)) - 5) < 0.001, "distancia a un segmento")

        var moved = box
        moved.translate(dx: 10, dy: -4)
        check(moved.points[1] == CGPoint(x: 210, y: 196), "mover una marca")

        var document = AnnotationDocument()
        check(document.nextCounter == 1, "el primer número es 1")
        document.annotations.append(Annotation(tool: .counter, color: .red, lineWidth: 5, points: [.zero], number: 4))
        check(document.nextCounter == 5, "los números siguen la secuencia")
    }

    // MARK: - Editor

    private static func demoImage(scale: Int = 2, width: Int = 900, height: Int = 560) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawDemo(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: width, height: height)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Una ventana inventada de una app de pedidos, para que las escenas parezcan uso real.
    private static func drawDemo(in rect: CGRect) {
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
        rect.fill()
        NSColor(srgbRed: 0.13, green: 0.15, blue: 0.22, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 190, height: rect.height).fill()

        let side: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        for (index, title) in ["Inicio", "Pedidos", "Clientes", "Reportes", "Ajustes"].enumerated() {
            (title as NSString).draw(at: NSPoint(x: 26, y: rect.height - 70 - CGFloat(index) * 38), withAttributes: side)
        }

        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor.black]
        ("Pedidos de hoy" as NSString).draw(at: NSPoint(x: 220, y: rect.height - 64), withAttributes: heading)

        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.darkGray]
        let rows: [(String, String, String, NSColor)] = [
            ("Pedido 1042", "María Pérez", "$ 128.000", .systemGreen),
            ("Pedido 1043", "Carlos Rojas", "$ 54.500", .systemOrange),
            ("Pedido 1044", "Ana Gómez", "$ 312.900", .systemGreen),
            ("Pedido 1045", "Luis Torres", "Error al guardar", .systemRed),
        ]
        for (index, row) in rows.enumerated() {
            let y = rect.height - 130 - CGFloat(index) * 66
            NSColor.white.setFill()
            NSBezierPath(roundedRect: CGRect(x: 220, y: y - 16, width: rect.width - 250, height: 54), xRadius: 8, yRadius: 8).fill()
            (row.0 as NSString).draw(at: NSPoint(x: 240, y: y), withAttributes: body)
            (row.1 as NSString).draw(at: NSPoint(x: 400, y: y), withAttributes: body)
            var status = body
            status[.foregroundColor] = row.3
            (row.2 as NSString).draw(at: NSPoint(x: 640, y: y), withAttributes: status)
        }
    }

    private static func pngFile(_ image: NSImage) -> URL {
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).png")
        try? rep?.representation(using: .png, properties: [:])?.write(to: url)
        return url
    }

    private static func sampleAnnotations(on canvas: AnnotationCanvas) {
        canvas.add(Annotation(tool: .highlight, color: .systemYellow, lineWidth: 5, points: [CGPoint(x: 630, y: 214), CGPoint(x: 780, y: 244)]))
        canvas.add(Annotation(tool: .arrow, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 520, y: 92), CGPoint(x: 628, y: 208)]))
        canvas.add(Annotation(tool: .rectangle, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 226, y: 200), CGPoint(x: 370, y: 256)]))
        canvas.add(Annotation(tool: .ellipse, color: .systemBlue, lineWidth: 5, points: [CGPoint(x: 18, y: 480), CGPoint(x: 106, y: 516)]))
        canvas.add(Annotation(tool: .pixelate, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 396, y: 268), CGPoint(x: 500, y: 300)]))
        canvas.add(Annotation(tool: .counter, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 800, y: 400)], number: 1))
        canvas.add(Annotation(tool: .counter, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 800, y: 330)], number: 2))
        canvas.add(Annotation(tool: .text, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 400, y: 60)], text: "Esto debería guardar"))
        var squiggle: [CGPoint] = []
        for step in 0..<40 {
            squiggle.append(CGPoint(x: 240 + CGFloat(step) * 3.6, y: 120 + sin(CGFloat(step) * 0.7) * 7))
        }
        canvas.add(Annotation(tool: .pencil, color: .systemGreen, lineWidth: 3, points: squiggle))
    }

    private static func canvasTests() async {
        let image = demoImage()
        let canvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 560), image: image)

        let plain = canvas.exportPNG()
        let plainRep = plain.flatMap { NSBitmapImageRep(data: $0) }
        check(plainRep?.pixelsWide == 1800 && plainRep?.pixelsHigh == 1120, "la exportación conserva la resolución Retina")
        check(plainRep?.size == NSSize(width: 900, height: 560), "la exportación conserva el tamaño en puntos")

        canvas.add(Annotation(tool: .rectangle, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 10, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)]))
        check(canvas.canUndo, "dibujar habilita deshacer")
        let marked = canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
        // (100, 200) en puntos, sobre el borde izquierdo del cuadro. Las filas van de arriba abajo.
        let edge = marked?.colorAt(x: 200, y: 1120 - 400)?.usingColorSpace(.sRGB)
        check((edge?.redComponent ?? 0) > 0.8 && (edge?.greenComponent ?? 1) < 0.3, "la marca sale en la imagen exportada")

        canvas.undo(nil)
        check(canvas.document.annotations.isEmpty, "deshacer quita la marca")
        check(canvas.canRedo, "deshacer habilita rehacer")
        canvas.redo(nil)
        check(canvas.document.annotations.count == 1, "rehacer devuelve la marca")

        canvas.applyCrop(CGRect(x: 100, y: 100, width: 300, height: 200))
        let cropped = canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
        check(cropped?.pixelsWide == 600 && cropped?.pixelsHigh == 400, "el recorte cambia el tamaño exportado")
        canvas.undo(nil)
        check(canvas.document.crop == nil, "deshacer quita el recorte")

        let pixelCanvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 560), image: image)
        pixelCanvas.add(Annotation(tool: .pixelate, color: .red, lineWidth: 5, points: [CGPoint(x: 220, y: 200), CGPoint(x: 400, y: 260)]))
        let pixelated = pixelCanvas.exportPNG()
        check(pixelated != nil && pixelated != plain, "pixelar cambia la imagen")
    }

    // MARK: - Sistema

    private static func colorPanel(_ rect: CGRect, _ color: NSColor) -> NSPanel {
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = color
        panel.isOpaque = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.orderFrontRegardless()
        return panel
    }

    private static func systemTests() async {
        check(CGPreflightScreenCaptureAccess(), "permiso de Grabación de pantalla")

        // Coloca un cuadro de color en un sitio conocido y lo captura por región.
        let screen = NSScreen.screens[0]
        let selection = Selection(screen: screen, rect: CGRect(x: 200, y: 150, width: 160, height: 90))
        let panel = colorPanel(selection.appKitRect, NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        await wait(0.4)
        let file = Capture.newFileURL(extension: "png")
        let ok = await capture(selection.captureArguments, to: file)
        check(ok, "la captura por región genera archivo")
        let rep = (try? Data(contentsOf: file)).flatMap { NSBitmapImageRep(data: $0) }
        let center = rep?.colorAt(x: (rep?.pixelsWide ?? 0) / 2, y: (rep?.pixelsHigh ?? 0) / 2)?.usingColorSpace(.sRGB)
        let corner = rep?.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)
        check((center?.greenComponent ?? 0) > 0.7 && (center?.redComponent ?? 1) < 0.4, "la región capturada es el sitio correcto")
        check((corner?.greenComponent ?? 0) > 0.7, "la esquina de la región también coincide")
        let expectedWidth = Int(160 * screen.backingScaleFactor)
        check(rep?.pixelsWide == expectedWidth, "el ancho capturado es exacto (\(rep?.pixelsWide ?? 0))")
        panel.orderOut(nil)

        let second = Capture.newFileURL(extension: "png")
        check(second != file, "dos capturas seguidas no se pisan")

        let image = Capture.copyImage(at: file)
        check(image != nil, "copiar imagen al portapapeles")
        let types = NSPasteboard.general.types ?? []
        check(types.contains(.png) && types.contains(.tiff), "el portapapeles tiene PNG y TIFF")

        // Ventana real: buscarla y capturarla por identificador.
        WindowFinder.includesOwnWindows = true
        let window = NSWindow(contentRect: CGRect(x: 300, y: 200, width: 400, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        await wait(0.5)
        let found = WindowFinder.onScreenWindows().first { $0.id == CGWindowID(window.windowNumber) }
        check(found != nil, "encuentra las ventanas en pantalla")
        if let found {
            let url = Capture.temporaryFileURL()
            let captured = await capture(Selection(screen: screen, rect: .zero, windowID: found.id).captureArguments, to: url)
            let windowRep = (try? Data(contentsOf: url)).flatMap { NSBitmapImageRep(data: $0) }
            check(captured && windowRep != nil, "captura una ventana por su identificador")
            check(windowRep?.pixelsWide == Int(found.frame.width * screen.backingScaleFactor), "la ventana sale sin sombra")
        }
        window.orderOut(nil)

        // Texto de la pantalla.
        let textURL = pngFile(demoImage())
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            TextReader.read(from: textURL) { continuation.resume(returning: $0) }
        }
        check(text.contains("Pedidos de hoy"), "lee texto en una imagen")
        check(text.contains("Error al guardar"), "lee texto en español")

        Capture.copyText("hola")
        check(NSPasteboard.general.string(forType: .string) == "hola", "copiar texto al portapapeles")
    }

    private static func recorderTest() async {
        let screen = NSScreen.screens[0]
        guard let displayID = screen.displayID else {
            check(false, "identificador de pantalla")
            return
        }
        let url = Capture.newFileURL(extension: "mp4")
        let recorder = ScreenRecorder()
        var failed: Error?
        do {
            try await recorder.start(
                displayID: displayID,
                rect: CGRect(x: 100, y: 100, width: 501, height: 301),
                scale: screen.backingScaleFactor,
                microphone: false,
                to: url
            )
        } catch {
            failed = error
        }
        check(failed == nil, "inicia la grabación \(failed.map { "(\($0.localizedDescription))" } ?? "")")
        guard failed == nil else { return }

        // Algo que se mueva, para que haya cuadros que grabar.
        let panel = colorPanel(CGRect(x: 120, y: 300, width: 80, height: 80), .systemBlue)
        for step in 0..<30 {
            panel.setFrameOrigin(NSPoint(x: 120 + CGFloat(step) * 10, y: 300))
            await wait(0.1)
        }
        panel.orderOut(nil)

        let result = await recorder.stop()
        check(result == url, "la grabación genera archivo")
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        check(duration >= 2.5, "el video dura lo esperado (\(String(format: "%.1f", duration)) s)")
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        check(tracks.count == 1, "el video tiene una pista")
        if let track = tracks.first, let size = try? await track.load(.naturalSize) {
            check(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0, "las dimensiones son pares (\(size))")
            let frames = (try? await track.load(.nominalFrameRate)) ?? 0
            check(frames > 5, "el video tiene movimiento (\(frames) fps)")
        }
    }

    // MARK: - Escenas

    private static func backdrop() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 90, y: 110, width: 780, height: 500), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Pedidos"
        window.isReleasedWhenClosed = false
        let imageView = NSImageView(image: demoImage(scale: 1, width: 780, height: 472))
        imageView.imageScaling = .scaleAxesIndependently
        window.contentView = imageView
        window.orderFrontRegardless()
        return window
    }

    private static func scenes() async {
        for (label, appearance) in [("claro", NSAppearance.Name.aqua), ("oscuro", NSAppearance.Name.darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let back = backdrop()
            await wait(0.4)

            let overlay = SelectionOverlay()
            overlay.begin(mode: .screenshot) { _ in }
            overlay.simulateHover(at: CGPoint(x: 400, y: 330))
            await shoot("\(label)-01-seleccion-ventana")
            overlay.simulateDrag(from: CGPoint(x: 310, y: 200), to: CGPoint(x: 760, y: 470))
            await shoot("\(label)-02-seleccion-area")
            overlay.cancel()

            let recording = SelectionOverlay()
            recording.begin(mode: .recording) { _ in }
            recording.simulateDrag(from: CGPoint(x: 310, y: 200), to: CGPoint(x: 760, y: 470))
            await shoot("\(label)-03-seleccion-video")
            recording.cancel()

            let thumbs = ThumbnailController()
            Settings.shared.thumbnailSeconds = 60
            let file = pngFile(demoImage())
            thumbs.show(image: demoImage(), file: file, kind: .text)
            thumbs.show(image: demoImage(width: 500, height: 620), file: file, kind: .video)
            thumbs.show(image: demoImage(width: 1000, height: 300), file: file, kind: .screenshot)
            thumbs.show(image: demoImage(), file: file, kind: .screenshot)
            thumbs.show(image: demoImage(), file: file, kind: .screenshot)
            check(thumbs.visibleCount == 4, "la pila no pasa de cuatro miniaturas")
            await wait(0.4)
            thumbs.simulateHover(index: 0)
            await shoot("\(label)-04-miniaturas")
            thumbs.dismissAll()

            let pins = PinController()
            pins.pin(demoImage(scale: 2, width: 420, height: 260))
            pins.simulateHover()
            await shoot("\(label)-05-fijada")
            pins.closeAll()

            let editor = AnnotationEditor(image: demoImage(), file: pngFile(demoImage()))
            sampleAnnotations(on: editor.canvas)
            editor.show()
            await shoot("\(label)-06-editor")
            editor.testSelect(tool: .highlight)
            await shoot("\(label)-07-editor-resaltar")
            editor.testWindow.close()

            let small = AnnotationEditor(image: demoImage(scale: 2, width: 240, height: 90), file: pngFile(demoImage()))
            small.show()
            await shoot("\(label)-08-editor-pequena")
            small.testWindow.close()

            let windows = WindowCoordinator()
            keepAlive.append(windows)
            windows.showSettings()
            await shoot("\(label)-09-ajustes")
            windows.closeAll()
            windows.showWelcome(hasPermission: false, openSettings: {}, relaunch: {})
            await shoot("\(label)-10-permiso")
            windows.closeAll()
            windows.showWelcome(hasPermission: true, openSettings: {}, relaunch: {})
            await shoot("\(label)-11-bienvenida")
            windows.closeAll()

            back.orderOut(nil)
            await wait(0.3)
        }
    }
}

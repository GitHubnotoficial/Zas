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

        // Hoja de fotogramas de un video, para revisar el demo sin tener un Mac.
        if let flag = CommandLine.arguments.firstIndex(of: "--resumen"), CommandLine.arguments.count > flag + 2 {
            let video = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            let sheet = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
            let moments = await VideoSheet.make(from: video, to: sheet)
            check(moments > 0, "el video demo se puede leer (\(moments) momentos)")
            return
        }

        if CommandLine.arguments.contains("--pantallas") {
            await displayTests()
            return
        }

        logic()
        await canvasTests()
        await polishTests()
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

        // Segunda pantalla a la izquierda y más arriba que la principal de 1080 de alto.
        let secondary = CGRect(x: -1920, y: 300, width: 1920, height: 1200)
        check(NSScreen.topLeftOrigin(of: secondary, primaryHeight: 1080) == CGPoint(x: -1920, y: -420), "origen de una pantalla secundaria arriba a la izquierda")
        let below = CGRect(x: 200, y: -900, width: 1600, height: 900)
        check(NSScreen.topLeftOrigin(of: below, primaryHeight: 1080) == CGPoint(x: 200, y: 1080), "origen de una pantalla secundaria debajo")
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
        canvas.add(Annotation(tool: .highlight, color: NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1), lineWidth: 28, points: [CGPoint(x: 634, y: 242), CGPoint(x: 700, y: 243), CGPoint(x: 760, y: 242)]))
        canvas.add(Annotation(tool: .arrow, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 560, y: 92), CGPoint(x: 660, y: 218)]))
        canvas.add(Annotation(tool: .rectangle, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 230, y: 222), CGPoint(x: 340, y: 262)]))
        canvas.add(Annotation(tool: .ellipse, color: .systemBlue, lineWidth: 5, points: [CGPoint(x: 8, y: 478), CGPoint(x: 92, y: 518)]))
        canvas.add(Annotation(tool: .pixelate, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 396, y: 424), CGPoint(x: 510, y: 454)]))
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

        // Mover y cambiar de tamaño, como en los estados de WhatsApp.
        let moveCanvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 560), image: image)
        moveCanvas.add(Annotation(tool: .rectangle, color: .red, lineWidth: 6, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)]))
        check(moveCanvas.selectionForTesting == 0, "lo recién dibujado queda seleccionado")
        check(moveCanvas.beginDrag(at: CGPoint(x: 200, y: 150)), "se puede agarrar una marca")
        moveCanvas.continueDrag(to: CGPoint(x: 250, y: 190))
        moveCanvas.endDrag()
        check(moveCanvas.document.annotations[0].points[0] == CGPoint(x: 150, y: 140), "mover lleva la marca al sitio nuevo")
        moveCanvas.undo(nil)
        check(moveCanvas.document.annotations[0].points[0] == CGPoint(x: 100, y: 100), "mover se puede deshacer")
        moveCanvas.redo(nil)
        moveCanvas.add(Annotation(tool: .ellipse, color: .blue, lineWidth: 4, points: [CGPoint(x: 400, y: 100), CGPoint(x: 500, y: 200)]))
        check(moveCanvas.beginDrag(at: CGPoint(x: 500, y: 200)), "se puede agarrar una esquina")
        moveCanvas.continueDrag(to: CGPoint(x: 600, y: 300))
        moveCanvas.endDrag()
        check(moveCanvas.document.annotations[1].points[1] == CGPoint(x: 600, y: 300), "la esquina cambia el tamaño")
        var bigger = Annotation(tool: .text, color: .red, lineWidth: 5, points: [CGPoint(x: 10, y: 10)], text: "hola")
        bigger.scale(from: .zero, x: 2, y: 2)
        check(bigger.lineWidth == 10, "el texto crece sin deformarse")

        // Censura con pincel: solo toca el trazo.
        let brushCanvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 560), image: image)
        brushCanvas.add(Annotation(tool: .pixelate, color: .red, lineWidth: 40, points: [CGPoint(x: 220, y: 300), CGPoint(x: 420, y: 300), CGPoint(x: 700, y: 300)], pixelBrush: true, blockSize: 20))
        check(brushCanvas.exportPNG() != plain, "el pincel de censura cambia la imagen")

        // Borrador: quita lo dibujado y deja intacta la captura.
        let eraseCanvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 560), image: image)
        eraseCanvas.add(Annotation(tool: .rectangle, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 10, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)]))
        eraseCanvas.add(Annotation(tool: .eraser, color: .black, lineWidth: 40, points: [CGPoint(x: 100, y: 180), CGPoint(x: 100, y: 220)]))
        let erased = eraseCanvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
        let erasedEdge = erased?.colorAt(x: 200, y: 1120 - 400)?.usingColorSpace(.sRGB)
        let originalEdge = plainRep?.colorAt(x: 200, y: 1120 - 400)?.usingColorSpace(.sRGB)
        check(abs((erasedEdge?.redComponent ?? 9) - (originalEdge?.redComponent ?? 0)) < 0.05, "el borrador quita la marca y deja la captura")
        let keptEdge = erased?.colorAt(x: 200, y: 1120 - 560)?.usingColorSpace(.sRGB)
        check((keptEdge?.redComponent ?? 0) > 0.8 && (keptEdge?.greenComponent ?? 1) < 0.3, "el borrador respeta lo que no tocó")

        // Resaltador: tiñe sin tapar.
        let markerCanvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 560), image: image)
        markerCanvas.add(Annotation(tool: .highlight, color: NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1), lineWidth: 30, points: [CGPoint(x: 240, y: 300), CGPoint(x: 420, y: 300)]))
        let marked2 = markerCanvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
        let tint = marked2?.colorAt(x: 660, y: 1120 - 600)?.usingColorSpace(.sRGB)
        let under = plainRep?.colorAt(x: 660, y: 1120 - 600)?.usingColorSpace(.sRGB)
        check((tint?.blueComponent ?? 1) < (under?.blueComponent ?? 0) - 0.1 && (tint?.redComponent ?? 0) > 0.5, "el resaltador tiñe y deja ver lo de abajo")

        let pixelCanvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 560), image: image)
        pixelCanvas.add(Annotation(tool: .pixelate, color: .red, lineWidth: 5, points: [CGPoint(x: 220, y: 200), CGPoint(x: 400, y: 260)]))
        let pixelated = pixelCanvas.exportPNG()
        check(pixelated != nil && pixelated != plain, "pixelar cambia la imagen")
    }

    // MARK: - Defectos encontrados al usarla

    private static func polishTests() async {
        let edited = URL(fileURLWithPath: "/x/Zas 2026 anotada 2.png")
        check(AnnotationEditor.baseName(of: edited) == "Zas 2026", "editar dos veces no acumula \"anotada\" en el nombre")
        check(AnnotationEditor.baseName(of: URL(fileURLWithPath: "/x/Zas 2026.png")) == "Zas 2026", "el nombre original no cambia")

        // Física de la interfaz.
        check(abs(Spring.value(at: 2, response: 0.42, damping: 0.86) - 1) < 0.001, "el resorte se asienta en su destino")
        let peak = stride(from: 0.0, to: 1.0, by: 0.01).map { Spring.value(at: $0, response: 0.42, damping: 0.86) }.max() ?? 0
        check(peak > 1 && peak < 1.08, "el resorte se pasa apenas, como un objeto real (\(peak))")
        check(CardSwipe.shouldClose(offset: 100, width: 224, velocity: 0), "deslizar pasado el 40 % cierra la tarjeta")
        check(CardSwipe.shouldClose(offset: 20, width: 224, velocity: 900), "un toque rápido también la cierra")
        check(!CardSwipe.shouldClose(offset: 40, width: 224, velocity: 100), "un gesto corto la devuelve a su sitio")
        check(CardSwipe.resisted(-1000) > -24, "hacia dentro cede muy poco")

        // Resumen de video para Claude.
        check(VideoSheet.frameTimes(duration: 0) == [0], "un video vacío no rompe el resumen")
        check(VideoSheet.frameTimes(duration: 3).count == 2, "un video corto da dos momentos")
        check(VideoSheet.frameTimes(duration: 10, every: 1).count == 11, "se puede pedir una imagen por segundo")
        check(VideoSheet.frameTimes(duration: 600, every: 60).count == 11, "se puede pedir una imagen por minuto")
        check(VideoSheet.frameTimes(duration: 7200, every: 1).count == 120, "un video largo no pasa del tope")
        check(VideoSheet.outputName(for: URL(fileURLWithPath: "/x/Zas 1.mp4"), page: 2) == "Zas 1 resumen 2.png", "nombre de la segunda hoja")
        check((VideoSheet.frameTimes(duration: 60).last ?? 99) < 60, "el último momento cae dentro del video")
        check(VideoSheet.timeLabel(83) == "1:23", "el minuto se escribe bien")
        check(VideoSheet.outputName(for: URL(fileURLWithPath: "/x/Zas 1.mp4")) == "Zas 1 resumen.png", "nombre del resumen")

        // Copiar sin guardar.
        Settings.shared.saveCaptures = false
        check(Capture.isScratch(Capture.newFileURL(extension: "png")), "sin guardar, la imagen va a un archivo temporal")
        check(!Capture.isScratch(Capture.newFileURL(extension: "mp4")), "sin guardar, el video sí se conserva")
        Settings.shared.saveCaptures = true
        check(!Capture.isScratch(Capture.newFileURL(extension: "png")), "guardando, la imagen va a la carpeta")

        // Carpeta que dejó de existir, como un disco desconectado.
        let chosen = Settings.shared.saveFolder
        Settings.shared.saveFolder = URL(fileURLWithPath: "/dev/null/zas", isDirectory: true)
        check(Capture.folder == Settings.defaultFolder, "si la carpeta no sirve, se usa la de siempre")
        Settings.shared.saveFolder = chosen

        // Cerrar sin perder marcas.
        let canvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 300, height: 200), image: demoImage(width: 300, height: 200))
        check(!canvas.hasUnsavedMarks, "un editor sin marcas cierra sin preguntar")
        canvas.add(Annotation(tool: .arrow, color: .red, lineWidth: 5, points: [.zero, CGPoint(x: 50, y: 50)]))
        check(canvas.hasUnsavedMarks, "con marcas, cerrar pregunta")
        canvas.undo(nil)
        check(!canvas.hasUnsavedMarks, "al deshacerlo todo ya no pregunta")

        // Grabador de atajos: cambiar de ventana no debe dejar los atajos apagados.
        var recordingChanges: [Bool] = []
        let previous = ShortcutRecorderButton.onRecordingChanged
        ShortcutRecorderButton.onRecordingChanged = { recordingChanges.append($0) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = ShortcutRecorderButton(shortcut: HotKeyAction.region.defaultShortcut)
        window.contentView?.addSubview(button)
        button.performClick(nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        await wait(0.1)
        check(recordingChanges == [true, false], "cambiar de ventana devuelve los atajos globales")
        ShortcutRecorderButton.onRecordingChanged = previous

        // Miniaturas. El cursor se deja lejos de la esquina.
        CGWarpMouseCursorPosition(CGPoint(x: 300, y: 300))
        await wait(0.2)
        Settings.shared.thumbnailSeconds = 60
        let file = pngFile(demoImage())
        let thumbs = ThumbnailController()
        thumbs.show(image: demoImage(), file: file, kind: .screenshot)
        thumbs.show(image: demoImage(), file: file, kind: .screenshot)
        await wait(0.4)
        check(thumbs.testActionCount(index: 0) == 4, "la tarjeta muestra solo cuatro acciones")
        check(thumbs.testBadge(index: 0) == "Copiado", "la última miniatura dice Copiado")
        check(thumbs.testBadge(index: 1) == nil, "las anteriores no dicen Copiado, porque ya no lo están")

        thumbs.testCopy(index: 1)
        check(thumbs.testIsInClipboard(index: 1) && !thumbs.testIsInClipboard(index: 0), "copiar otra vez cambia cuál está copiada")
        check(NSPasteboard.general.data(forType: .png) != nil, "copiar otra vez deja la imagen en el portapapeles")

        thumbs.simulateLostExit(index: 0)
        check(!thumbs.testHasTimer(index: 0), "la miniatura perdió el aviso de salida")
        thumbs.testSyncHover()
        check(!thumbs.testIsHovering(index: 0) && thumbs.testHasTimer(index: 0), "la miniatura se recupera y volverá a cerrarse sola")

        thumbs.simulateHover(index: 1)
        thumbs.suspend()
        thumbs.resume()
        check(!thumbs.testIsHovering(index: 1) && thumbs.testHasTimer(index: 1), "tras capturar otra vez no queda atascada")
        thumbs.dismissAll()

        Settings.shared.thumbnailSeconds = 0.4
        thumbs.show(image: demoImage(), file: file, kind: .text, text: "hola de nuevo")
        await wait(0.1)
        NSPasteboard.general.clearContents()
        thumbs.testCopy(index: 0)
        check(NSPasteboard.general.string(forType: .string) == "hola de nuevo", "se puede volver a copiar un texto")
        await wait(1)
        check(thumbs.visibleCount == 0, "la miniatura se cierra sola")
        Settings.shared.thumbnailSeconds = 6
    }

    // MARK: - Todas las pantallas

    /// Repite lo esencial en cada pantalla conectada. En GitHub, la segunda es una Retina virtual.
    private static func displayTests() async {
        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() {
            print("pantalla \(index): \(screen.frame) escala \(screen.backingScaleFactor)")
        }
        check(screens.count >= 2, "hay más de una pantalla (\(screens.count))")
        check(screens.contains { $0.backingScaleFactor == 2 }, "hay una pantalla Retina")

        for (index, screen) in screens.enumerated() {
            let name = "pantalla \(index) a \(Int(screen.backingScaleFactor))x"
            let scale = screen.backingScaleFactor
            let origin = screen.globalTopLeftOrigin
            CGWarpMouseCursorPosition(CGPoint(x: origin.x + 40, y: origin.y + 300))
            await wait(0.3)
            check(NSScreen.underMouse == screen, "\(name): el cursor está en ella")

            // Captura por región de algo que está en un sitio conocido.
            let selection = Selection(screen: screen, rect: CGRect(x: 200, y: 150, width: 160, height: 90))
            let panel = colorPanel(selection.appKitRect, NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            await wait(0.5)
            let file = Capture.newFileURL(extension: "png")
            let captured = await capture(selection.captureArguments, to: file)
            panel.orderOut(nil)
            check(captured, "\(name): la región genera archivo")
            let rep = (try? Data(contentsOf: file)).flatMap { NSBitmapImageRep(data: $0) }
            check(rep?.pixelsWide == Int(160 * scale) && rep?.pixelsHigh == Int(90 * scale), "\(name): la región tiene todos los pixeles (\(rep?.pixelsWide ?? 0)×\(rep?.pixelsHigh ?? 0))")
            let center = rep?.colorAt(x: (rep?.pixelsWide ?? 0) / 2, y: (rep?.pixelsHigh ?? 0) / 2)?.usingColorSpace(.sRGB)
            let corner = rep?.colorAt(x: 3, y: 3)?.usingColorSpace(.sRGB)
            check((center?.greenComponent ?? 0) > 0.7 && (corner?.greenComponent ?? 0) > 0.7, "\(name): la región es el sitio correcto")

            let image = Capture.copyImage(at: file, pointSize: selection.imagePointSize)
            check(image?.size == CGSize(width: 160, height: 90), "\(name): la imagen pega a su tamaño real (\(image?.size ?? .zero))")
            let reread = (try? Data(contentsOf: file)).flatMap { NSBitmapImageRep(data: $0) }
            check(reread?.size == CGSize(width: 160, height: 90) && reread?.pixelsWide == Int(160 * scale), "\(name): el archivo guarda la densidad correcta")

            // Ventana por identificador.
            WindowFinder.includesOwnWindows = true
            // Con `screen`, el rectángulo es relativo a esa pantalla y la ventana nace con su densidad.
            let target = NSWindow(contentRect: CGRect(x: 300, y: 200, width: 400, height: 260), styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
            target.isReleasedWhenClosed = false
            target.orderFrontRegardless()
            target.display()
            await wait(0.5)
            print("\(name): ventana a escala \(target.backingScaleFactor)")
            if let found = WindowFinder.onScreenWindows().first(where: { $0.id == CGWindowID(target.windowNumber) }) {
                let url = Capture.temporaryFileURL()
                _ = await capture(Selection(screen: screen, rect: .zero, windowID: found.id).captureArguments, to: url)
                let windowRep = (try? Data(contentsOf: url)).flatMap { NSBitmapImageRep(data: $0) }
                check(target.backingScaleFactor == scale, "\(name): la ventana usa la densidad de la pantalla (\(target.backingScaleFactor))")
                check(windowRep?.pixelsWide == Int(found.frame.width * scale), "\(name): la ventana tiene todos los pixeles (\(windowRep?.pixelsWide ?? 0))")
            } else {
                check(false, "\(name): encuentra la ventana")
            }
            target.orderOut(nil)

            // La selección dibujada en esta pantalla.
            let overlay = SelectionOverlay()
            overlay.begin(mode: .screenshot) { _ in }
            overlay.simulateDrag(from: CGPoint(x: 120, y: 100), to: CGPoint(x: 620, y: 400))
            await wait(0.5)
            _ = await capture(["-x", "-D\(index + 1)"], to: output.appendingPathComponent("pantalla-\(index)-seleccion.png"))
            overlay.cancel()

            // Miniatura y editor en la pantalla del cursor.
            guard let image else { continue }
            Settings.shared.thumbnailSeconds = 60
            let thumbs = ThumbnailController()
            thumbs.show(image: image, file: file, kind: .screenshot)
            await wait(0.5)
            check(screen.visibleFrame.contains(thumbs.testFrames.first ?? .zero), "\(name): la miniatura aparece en esta pantalla")
            _ = await capture(["-x", "-D\(index + 1)"], to: output.appendingPathComponent("pantalla-\(index)-miniatura.png"))
            thumbs.dismissAll()
            Settings.shared.thumbnailSeconds = 6

            let editor = AnnotationEditor(image: image, file: file)
            editor.canvas.add(Annotation(tool: .rectangle, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 70)]))
            editor.show()
            await wait(0.6)
            check(editor.testWindow.screen == screen, "\(name): el editor abre en esta pantalla")
            _ = await capture(["-x", "-D\(index + 1)"], to: output.appendingPathComponent("pantalla-\(index)-editor.png"))
            let exported = editor.canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
            check(exported?.pixelsWide == Int(160 * scale), "\(name): la anotada conserva los pixeles (\(exported?.pixelsWide ?? 0))")
            editor.testWindow.close()

            await recording(on: screen, name: name)
        }
    }

    private static func recording(on screen: NSScreen, name: String) async {
        guard let displayID = screen.displayID else {
            check(false, "\(name): identificador de pantalla")
            return
        }
        let rect = CGRect(x: 60, y: 60, width: 501, height: 301)
        let url = Capture.newFileURL(extension: "mp4")
        let recorder = ScreenRecorder()
        do {
            try await recorder.start(displayID: displayID, rect: rect, scale: screen.backingScaleFactor, microphone: false, to: url)
        } catch {
            check(false, "\(name): inicia la grabación (\(error.localizedDescription))")
            return
        }
        let area = Selection(screen: screen, rect: rect).appKitRect
        let panel = colorPanel(CGRect(x: area.minX + 20, y: area.minY + 100, width: 80, height: 80), .systemBlue)
        for step in 0..<20 {
            panel.setFrameOrigin(NSPoint(x: area.minX + 20 + CGFloat(step) * 10, y: area.minY + 100))
            await wait(0.1)
        }
        panel.orderOut(nil)

        let result = await recorder.stop()
        check(result == url, "\(name): la grabación genera archivo")
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)) ?? []
        if let track = tracks.first, let size = try? await track.load(.naturalSize) {
            let expected = Int(501 * screen.backingScaleFactor) & ~1
            check(Int(size.width) == expected, "\(name): el video mide lo seleccionado (\(size))")
        } else {
            check(false, "\(name): el video tiene imagen")
        }
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

        let sheet = Capture.newFileURL(extension: "png")
        let moments = await VideoSheet.make(from: url, to: sheet)
        check(moments >= 2, "el video se convierte en imágenes (\(moments))")
        let sheetRep = (try? Data(contentsOf: sheet)).flatMap { NSBitmapImageRep(data: $0) }
        check(max(sheetRep?.pixelsWide ?? 9999, sheetRep?.pixelsHigh ?? 9999) <= 1568, "el resumen no supera el tamaño que Claude lee sin reducir")
        try? FileManager.default.copyItem(at: sheet, to: output.appendingPathComponent("resumen-video.png"))

        // Las capturas recientes incluyen lo último y salen en orden.
        let recent = Recents.files()
        check(recent.first?.lastPathComponent == sheet.lastPathComponent, "las recientes empiezan por lo último")
        check(recent.contains { $0.lastPathComponent == url.lastPathComponent }, "las recientes incluyen videos")
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        check(duration >= 2.5, "el video dura lo esperado (\(String(format: "%.1f", duration)) s)")
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        check(tracks.count == 1, "el video tiene una pista")
        if let track = tracks.first, let size = try? await track.load(.naturalSize) {
            check(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0, "las dimensiones son pares (\(size))")
            let frames = (try? await track.load(.nominalFrameRate)) ?? 0
            // Solo se guardan cuadros cuando algo cambia, y este Mac virtual es lento.
            check(frames >= 2, "el video tiene movimiento (\(frames) fps)")
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

            // El cursor real va sobre la ventana: así el resaltado es el de verdad.
            CGWarpMouseCursorPosition(CGPoint(x: 400, y: 330))
            await wait(0.2)
            let overlay = SelectionOverlay()
            overlay.begin(mode: .screenshot) { _ in }
            await shoot("\(label)-01-seleccion-ventana")
            overlay.simulateDrag(from: CGPoint(x: 310, y: 200), to: CGPoint(x: 760, y: 470))
            await shoot("\(label)-02-seleccion-area")
            overlay.simulateHover(at: CGPoint(x: 400, y: 330))
            overlay.testChoose(mode: .recording)
            check(overlay.mode == .recording, "la barra de vidrio cambia el modo")
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
            editor.testOpenPalette()
            await shoot("\(label)-07b-mini-paleta")
            editor.testOpenPalette()
            editor.testSelect(tool: .pixelate)
            await shoot("\(label)-07e-censura")
            editor.testSelect(tool: .eraser)
            await shoot("\(label)-07f-borrador")
            editor.testSelect(tool: .highlight)
            editor.testOpenPalette()
            editor.testOpenPalette()
            check(editor.testZoom() == 2, "el editor hace zoom")
            await shoot("\(label)-07c-zoom")
            editor.testResetZoom()
            let foundText = await editor.testLiveTextFindsText()
            print("Live Text: \(foundText ? "encontró texto" : "sin resultado en este Mac")")
            if label == "claro" {
                check(foundText, "Live Text encuentra el texto de la captura")
            }
            editor.testTextMode()
            await wait(1.5)
            await shoot("\(label)-07d-seleccion-texto")
            editor.testTextMode()
            editor.testWindow.close()

            let small = AnnotationEditor(image: demoImage(scale: 2, width: 240, height: 90), file: pngFile(demoImage()))
            small.show()
            await shoot("\(label)-08-editor-pequena")
            small.testWindow.close()

            Settings.shared.thumbnailSeconds = 6
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

import AVFoundation
import AppKit
import CoreImage.CIFilterBuiltins
import VisionKit

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
        // Las pruebas no viven en un paquete .app: se les da el icono real para que las escenas sean fieles.
        if let icon = NSImage(contentsOf: output.appendingPathComponent("icono.png")) {
            app.applicationIconImage = icon
        }
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
        Settings.shared.soundEffects = false

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
        soundTests()
        textLayoutTests()
        await canvasTests()
        await polishTests()
        await systemTests()
        await recorderTest()
        await historyTests()
        await desktopCoverTests()
        await textBattery()
        await functionalTests()
        await responsivenessTests()
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
        canvas.add(Annotation(tool: .arrow, color: Palette.markDefault, lineWidth: 5, points: [CGPoint(x: 420, y: 105), CGPoint(x: 660, y: 218)]))
        canvas.add(Annotation(tool: .rectangle, color: Palette.markDefault, lineWidth: 5, points: [CGPoint(x: 230, y: 222), CGPoint(x: 340, y: 262)]))
        canvas.add(Annotation(tool: .ellipse, color: .systemBlue, lineWidth: 5, points: [CGPoint(x: 8, y: 478), CGPoint(x: 92, y: 518)]))
        canvas.add(Annotation(tool: .pixelate, color: .systemRed, lineWidth: 5, points: [CGPoint(x: 396, y: 424), CGPoint(x: 510, y: 454)]))
        canvas.add(Annotation(tool: .counter, color: Palette.markDefault, lineWidth: 5, points: [CGPoint(x: 800, y: 400)], number: 1))
        canvas.add(Annotation(tool: .counter, color: Palette.markDefault, lineWidth: 5, points: [CGPoint(x: 800, y: 330)], number: 2))
        canvas.add(Annotation(tool: .text, color: Palette.markDefault, lineWidth: 5, points: [CGPoint(x: 400, y: 60)], text: "Esto debería guardar"))
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

    // MARK: - Fondo no destructivo

    /// El fondo es una receta: la imagen y las marcas no se enteran de que existe.
    private static func backdropTests(_ image: NSImage) {
        func isRed(_ color: NSColor?) -> Bool {
            let rgb = color?.usingColorSpace(.sRGB)
            return (rgb?.redComponent ?? 0) > 0.8 && (rgb?.greenComponent ?? 1) < 0.3
        }
        func isGreen(_ color: NSColor?) -> Bool {
            let rgb = color?.usingColorSpace(.sRGB)
            return (rgb?.greenComponent ?? 0) > 0.7 && (rgb?.redComponent ?? 1) < 0.4
        }

        let canvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 600, height: 400), image: image)
        let points = [CGPoint(x: 40, y: 50), CGPoint(x: 120, y: 90)]
        canvas.add(Annotation(tool: .arrow, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), lineWidth: 6, points: points))
        let withoutBackdrop = canvas.exportPNG()
        let plainRep = withoutBackdrop.flatMap { NSBitmapImageRep(data: $0) }
        // Mitad de la flecha: (80, 70) en puntos. Las filas van de arriba abajo.
        check(isRed(plainRep?.colorAt(x: 160, y: 400 - 140)), "sin fondo, la marca está donde se dibujó")

        var backdrop = Backdrop()
        backdrop.kind = .solid
        backdrop.color = [0, 1, 0]
        backdrop.margin = 50
        backdrop.shadow = 0
        backdrop.corners = 0

        canvas.setBackdrop(backdrop)
        check(canvas.document.annotations[0].points == points, "el fondo no mueve las coordenadas de la marca")
        let composed = canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
        check(composed?.pixelsWide == 800 && composed?.pixelsHigh == 600, "el fondo añade su margen a la exportación (\(composed?.pixelsWide ?? 0)×\(composed?.pixelsHigh ?? 0))")
        check(composed?.size == NSSize(width: 400, height: 300), "con fondo se conserva la densidad Retina")
        check(isGreen(composed?.colorAt(x: 6, y: 6)), "el fondo aparece en la imagen exportada")
        check(isRed(composed?.colorAt(x: 260, y: 600 - 240)), "la marca sale en su sitio sobre la captura con fondo")

        // Cambiar el margen no desplaza nada, tampoco al convertir entre pantalla e imagen.
        for margin in [CGFloat(0), 20, 120, 240] {
            var wider = backdrop
            wider.margin = margin
            canvas.setBackdrop(wider, finished: false)
            let onScreen = canvas.testViewPoint(fromImage: points[0])
            let back = canvas.testImagePoint(fromView: onScreen)
            check(canvas.document.annotations[0].points == points, "con margen \(Int(margin)) la marca conserva sus coordenadas")
            check(hypot(back.x - points[0].x, back.y - points[0].y) < 0.001, "con margen \(Int(margin)) el cursor apunta al mismo sitio de la imagen")
        }

        // Un deslizador en movimiento es un solo paso de deshacer.
        let steps = canvas.historyCount
        var settled = backdrop
        settled.margin = 120
        canvas.setBackdrop(settled)
        check(canvas.historyCount == steps + 1, "mover un deslizador ocupa un solo paso de deshacer")
        canvas.undo(nil)
        canvas.undo(nil)
        check(canvas.document.backdrop == nil, "el fondo se puede deshacer")
        canvas.redo(nil)
        check(canvas.document.backdrop != nil, "el fondo se puede rehacer")

        canvas.setBackdrop(nil)
        check(canvas.exportPNG() == withoutBackdrop, "quitar el fondo devuelve la imagen original")
        check(canvas.document.annotations[0].points == points, "quitar el fondo deja la marca igual")

        // Guardar y abrir un proyecto.
        canvas.setBackdrop(backdrop)
        let reopened = canvas.projectData().flatMap { try? JSONDecoder().decode(ZasProject.self, from: $0) }
        check(reopened?.document().backdrop == backdrop, "el fondo sobrevive a guardar y abrir un proyecto")
        check(reopened?.document().annotations.first?.points == points, "las marcas siguen en su sitio al abrir un proyecto con fondo")
        if let reopened, let base = reopened.baseImage() {
            let second = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 600, height: 400), image: base)
            second.load(reopened.document())
            let again = second.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
            check(again?.pixelsWide == 800 && isGreen(again?.colorAt(x: 6, y: 6)), "un proyecto abierto exporta con su fondo")
            second.setBackdrop(nil)
            check(second.document.annotations.count == 1, "en un proyecto abierto el fondo se sigue pudiendo quitar")
        } else {
            check(false, "se puede abrir un proyecto con fondo")
        }

        // Rotar integra las marcas, no el fondo: sigue siendo editable.
        canvas.applyImage { ImageTools.rotated($0, clockwise: true) }
        check(canvas.document.backdrop == backdrop, "rotar conserva el fondo aparte")
        let rotated = canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
        check(rotated?.pixelsWide == 600 && rotated?.pixelsHigh == 800, "el fondo se recompone alrededor de la imagen rotada")

        // Autoequilibrar: añade espacio solo del lado que tiene menos.
        var balanced = Backdrop()
        balanced.margin = 10
        balanced.inset = 2
        balanced.autoBalance = true
        let layout = balanced.layout(
            content: CGRect(x: 0, y: 0, width: 100, height: 80),
            edge: EdgeInfo(color: [1, 1, 1], left: 10, right: 30, top: 4, bottom: 4)
        )
        check(layout.card == CGRect(x: -22, y: -2, width: 124, height: 84), "autoequilibrar centra el contenido (\(layout.card))")
        check(layout.outer == CGRect(x: -32, y: -12, width: 144, height: 104), "el margen rodea la tarjeta equilibrada")

        let flat = ImageTools.edgeInfo(of: demoImage(scale: 1, width: 120, height: 80), crop: CGRect(x: 0, y: 0, width: 120, height: 80))
        check(flat.color.count == 3, "se lee el color del borde de la captura")
    }

    // MARK: - Defectos encontrados al usarla

    private static func polishTests() async {
        let edited = URL(fileURLWithPath: "/x/Zas 2026 anotada 2.png")
        check(AnnotationEditor.baseName(of: edited) == "Zas 2026", "editar dos veces no acumula \"anotada\" en el nombre")
        check(AnnotationEditor.baseName(of: URL(fileURLWithPath: "/x/Zas 2026.png")) == "Zas 2026", "el nombre original no cambia")

        // Captura con desplazamiento: tres tramos solapados de una columna de franjas.
        func strip(from start: Int) -> CGImage {
            let width = 40, height = 120
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for row in 0..<height {
                let value = start + row
                context.setFillColor(CGColor(red: CGFloat((value * 37) % 251) / 255, green: CGFloat((value * 91) % 241) / 255, blue: CGFloat((value * 17) % 239) / 255, alpha: 1))
                context.fill(CGRect(x: 0, y: height - 1 - row, width: width, height: 1))
            }
            return context.makeImage()!
        }
        var stitcher = ScrollStitcher()
        stitcher.add(strip(from: 0))
        check(stitcher.add(strip(from: 50)), "une un tramo desplazado")
        check(!stitcher.add(strip(from: 50)), "ignora un tramo repetido")
        stitcher.add(strip(from: 100))
        check(stitcher.height == 220 && stitcher.composed()?.height == 220, "la imagen larga mide lo correcto (\(stitcher.height))")

        // Cabecera y pie fijos, como un navegador con una barra abajo.
        func page(from start: Int) -> CGImage {
            let width = 40, height = 200
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for row in 0..<height {
                let isChrome = row < 30 || row >= 170
                let value = isChrome ? 7 + row : start + row
                context.setFillColor(CGColor(red: CGFloat((value * 37) % 251) / 255, green: CGFloat((value * 91) % 241) / 255, blue: CGFloat((value * 17) % 239) / 255, alpha: 1))
                context.fill(CGRect(x: 0, y: height - 1 - row, width: width, height: 1))
            }
            return context.makeImage()!
        }
        var chrome = ScrollStitcher()
        chrome.add(page(from: 1000))
        check(chrome.add(page(from: 1060)), "une tramos con cabecera y pie fijos")
        check(chrome.composed()?.height == 260, "el pie fijo sale una sola vez (\(chrome.composed()?.height ?? 0))")
        var jump = ScrollStitcher()
        jump.add(page(from: 1000))
        check(!jump.add(page(from: 3000)) && jump.lostTrack, "avisa cuando el contenido saltó demasiado")

        // Controles de la captura con desplazamiento: nunca sobre lo que se está capturando.
        let previewBig = stitcher.tailPreview(width: 20, maxHeight: 40)
        check(previewBig?.width == 20 && previewBig?.height == 40, "la vista previa se queda con lo último y no pasa del tope")
        check(stitcher.tailPreview(width: 20, maxHeight: 400)?.height == 110, "la vista previa crece con la imagen")
        let desk = CGRect(x: 0, y: 0, width: 1440, height: 860)
        let area = CGRect(x: 400, y: 300, width: 600, height: 400)
        let scrollBar = ScrollHUDLayout.barFrame(selection: area, visible: desk)
        check(scrollBar.midX == desk.midX && scrollBar.minY == desk.minY + ScrollHUDLayout.margin, "Cancelar y Listo van abajo y centrados")
        let tallArea = CGRect(x: 300, y: 0, width: 500, height: 860)
        check(!ScrollHUDLayout.barFrame(selection: tallArea, visible: desk).intersects(tallArea), "con una selección alta, los botones se apartan")
        let scrollPreview = ScrollHUDLayout.previewFrame(height: 120, selection: area, visible: desk)
        check(scrollPreview.maxX <= area.minX && scrollPreview.height == 120, "la vista previa va a la izquierda de la selección")
        check(ScrollHUDLayout.previewFrame(height: 5000, selection: area, visible: desk).height == ScrollHUDLayout.previewMaxHeight, "la vista previa tiene un alto máximo")

        // Herramientas de imagen.
        let tall = demoImage(scale: 2, width: 300, height: 200)
        check(ImageTools.rotated(tall, clockwise: true)?.size == CGSize(width: 200, height: 300), "rotar intercambia ancho y alto")
        check(ImageTools.resized(tall, factor: 0.5)?.size == CGSize(width: 150, height: 100), "cambiar el tamaño reduce la imagen")
        check(ImageTools.withBackground(tall, colors: ImageTools.backgrounds[0].colors, padding: 50)?.size == CGSize(width: 400, height: 300), "el fondo añade margen")
        let toolCanvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 300, height: 200), image: tall)
        toolCanvas.add(Annotation(tool: .rectangle, color: .red, lineWidth: 4, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 60)], filled: true))
        toolCanvas.applyImage { ImageTools.rotated($0, clockwise: true) }
        check(toolCanvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 400, "rotar en el editor cambia la exportación")
        check(toolCanvas.document.annotations.isEmpty, "rotar integra las marcas")
        toolCanvas.undo(nil)
        check(toolCanvas.document.annotations.count == 1, "rotar se puede deshacer")
        let spot = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 300, height: 200), image: tall)
        let spotBefore = spot.exportPNG().flatMap { NSBitmapImageRep(data: $0) }?.colorAt(x: 590, y: 390)?.usingColorSpace(.sRGB)
        spot.add(Annotation(tool: .spotlight, color: .black, lineWidth: 1, points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)]))
        let spotAfter = spot.exportPNG().flatMap { NSBitmapImageRep(data: $0) }?.colorAt(x: 590, y: 390)?.usingColorSpace(.sRGB)
        check((spotAfter?.brightnessComponent ?? 1) < (spotBefore?.brightnessComponent ?? 0) * 0.7, "el foco oscurece lo de alrededor")
        let blur = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 300, height: 200), image: tall)
        let blurPlain = blur.exportPNG()
        blur.add(Annotation(tool: .pixelate, color: .red, lineWidth: 5, points: [CGPoint(x: 10, y: 10), CGPoint(x: 280, y: 180)], smoothBlur: true))
        check(blur.exportPNG() != blurPlain, "el desenfoque suave cambia la imagen")
        let picture = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 300, height: 200), image: tall)
        picture.addPicture(demoImage(scale: 1, width: 80, height: 60))
        check(picture.document.annotations.first?.tool == .picture, "se puede añadir otra imagen")

        // Proyecto editable: se guarda y se recupera con todas sus marcas.
        let projectCanvas = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 300, height: 200), image: tall)
        projectCanvas.add(Annotation(tool: .text, color: .systemBlue, lineWidth: 6, points: [CGPoint(x: 20, y: 30)], text: "Hola"))
        projectCanvas.add(Annotation(tool: .rectangle, color: .systemRed, lineWidth: 3, points: [.zero, CGPoint(x: 40, y: 40)], filled: true))
        let projectData = projectCanvas.projectData()
        let restored = projectData.flatMap { try? JSONDecoder().decode(ZasProject.self, from: $0) }
        check(restored?.document().annotations.count == 2, "un proyecto guarda sus marcas")
        check(restored?.document().annotations[0].text == "Hola", "un proyecto recupera el texto")
        check(restored?.document().annotations[1].filled == true, "un proyecto recupera las opciones")
        check(restored?.baseImage()?.size == tall.size, "un proyecto conserva el tamaño")

        backdropTests(tall)

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
        check(thumbs.testActionCount(index: 0) == 6, "la tarjeta tiene seis acciones al pasar el cursor")
        check(
            thumbs.testActionLabels(index: 0) == ["Copiar", "Guardar", "Cerrar", "Fijar en pantalla", "Anotar", "Copiar ruta para un agente"],
            "cada botón de la tarjeta tiene su etiqueta (\(thumbs.testActionLabels(index: 0)))"
        )
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

        // El contorno y el aviso son breves, y solo en la más reciente.
        thumbs.show(image: demoImage(), file: file, kind: .screenshot)
        thumbs.show(image: demoImage(), file: file, kind: .screenshot)
        await wait(0.3)
        check(thumbs.testIsOutlined(index: 0) && !thumbs.testIsOutlined(index: 1), "solo la tarjeta más reciente lleva contorno")

        // En reposo los botones no responden: el clic es de la tarjeta.
        let cardCenter = CGPoint(x: 112, y: 70)
        let copyPill = CGPoint(x: cardCenter.x, y: cardCenter.y + 15)
        check(!thumbs.testHitsButton(index: 0, at: copyPill), "en reposo, un clic en el centro es de la tarjeta")
        thumbs.simulateHover(index: 0)
        check(thumbs.testHitsButton(index: 0, at: copyPill), "con el cursor encima, el centro es la píldora Copiar")
        check(!thumbs.testHitsButton(index: 0, at: CGPoint(x: 16, y: 70)), "fuera de los botones, el clic sigue siendo de la tarjeta")
        check(thumbs.testHitsButton(index: 0, at: CGPoint(x: 18, y: 122)), "arriba a la izquierda hay un círculo")
        thumbs.testSyncHover()

        await wait(2.2)
        check(!thumbs.testIsOutlined(index: 0), "el contorno dura un instante")
        check(thumbs.testBadge(index: 0) == nil && thumbs.testIsInClipboard(index: 0), "el aviso se va, aunque siga copiada")

        let copied = FileManager.default.temporaryDirectory.appendingPathComponent("zas-guardada-\(UUID().uuidString).png")
        check(thumbs.testSave(index: 0, to: copied), "guardar escribe el archivo elegido")
        check((try? Data(contentsOf: copied)) == (try? Data(contentsOf: file)), "lo guardado es la misma captura")
        check(thumbs.testSave(index: 0, to: copied), "guardar encima de un archivo también funciona")
        try? FileManager.default.removeItem(at: copied)
        thumbs.dismissAll()

        // La marca de video se queda. Copiar y Guardar siempre; Resumen pasa a la fila de iconos.
        thumbs.show(image: demoImage(), file: file, kind: .video)
        check(
            thumbs.testActionLabels(index: 0) == ["Copiar", "Guardar", "Cerrar", "Fijar en pantalla", "Copiar resumen en imágenes para Claude", "Copiar ruta para un agente", "Reproducir"],
            "el video lleva Guardar, Resumen y Reproducir (\(thumbs.testActionLabels(index: 0)))"
        )
        check(thumbs.testBadge(index: 0) == "Video copiado", "un video recién copiado lo dice")
        await wait(2.2)
        check(thumbs.testBadge(index: 0) == "Video", "en reposo, el video conserva su marca")
        thumbs.dismissAll()

        // Tarjeta baja: Copiar y Guardar van en fila, con el aire justo entre los dos.
        thumbs.show(image: demoImage(width: 1000, height: 300), file: file, kind: .screenshot)
        await wait(0.8)
        thumbs.simulateHover(index: 0)
        check(thumbs.testHitsButton(index: 0, at: CGPoint(x: 77, y: 42)) && thumbs.testHitsButton(index: 0, at: CGPoint(x: 147, y: 42)), "en una tarjeta baja, Copiar y Guardar van en fila")
        check(!thumbs.testHitsButton(index: 0, at: CGPoint(x: 112, y: 42)), "entre Copiar y Guardar el clic es de la tarjeta")
        thumbs.dismissAll()

        // Video: reproducir al centro de la imagen, y las píldoras donde no lo pisen.
        thumbs.show(image: demoImage(width: 500, height: 620), file: file, kind: .video)
        await wait(0.8)
        thumbs.simulateHover(index: 0)
        check(thumbs.testHitsButton(index: 0, at: CGPoint(x: 80, y: 84)), "en un video alto, reproducir queda en el centro")
        check(thumbs.testHitsButton(index: 0, at: CGPoint(x: 45, y: 49)) && thumbs.testHitsButton(index: 0, at: CGPoint(x: 115, y: 49)), "en un video alto, Copiar y Guardar van bajo reproducir")
        thumbs.dismissAll()
        thumbs.show(image: demoImage(width: 900, height: 500), file: file, kind: .video)
        await wait(0.8)
        thumbs.simulateHover(index: 0)
        check(thumbs.testHitsButton(index: 0, at: CGPoint(x: 112, y: 62)), "en un video bajo, reproducir también queda en el centro")
        check(thumbs.testHitsButton(index: 0, at: CGPoint(x: 116, y: 107)) && thumbs.testHitsButton(index: 0, at: CGPoint(x: 186, y: 107)), "en un video bajo, Copiar y Guardar suben a la fila de Cerrar")
        thumbs.dismissAll()

        // La tarjeta sigue la forma de la captura, dentro de sus límites.
        thumbs.show(image: demoImage(width: 1000, height: 300), file: file, kind: .screenshot)
        thumbs.show(image: demoImage(width: 500, height: 620), file: file, kind: .screenshot)
        thumbs.show(image: demoImage(width: 900, height: 450), file: file, kind: .screenshot)
        await wait(0.8)
        check(thumbs.testFrames.map(\.size) == [
            CGSize(width: 224, height: 112), CGSize(width: 160, height: 168), CGSize(width: 224, height: 84),
        ], "la tarjeta sigue la forma de la captura (\(thumbs.testFrames.map(\.size)))")
        thumbs.dismissAll()

        // Lado de la pila. El ajuste se guarda como los demás.
        let suite = "zas-pruebas-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            check(Settings(defaults: defaults).thumbnailsOnLeft, "las tarjetas van a la izquierda por defecto")
            Settings(defaults: defaults).thumbnailsOnLeft = false
            check(!Settings(defaults: defaults).thumbnailsOnLeft, "el lado de las tarjetas se recuerda")
            defaults.removePersistentDomain(forName: suite)
        }

        let savedSide = Settings.shared.thumbnailsOnLeft
        let display = NSScreen.underMouse
        for onLeft in [true, false] {
            let side = onLeft ? "izquierda" : "derecha"
            let outward: CGFloat = onLeft ? -1 : 1
            Settings.shared.thumbnailsOnLeft = onLeft
            thumbs.show(image: demoImage(), file: file, kind: .screenshot)
            thumbs.show(image: demoImage(), file: file, kind: .screenshot)
            await wait(0.8)

            let home = thumbs.testFrames[0]
            let visible = display.visibleFrame
            let margin = onLeft ? home.minX - visible.minX : visible.maxX - home.maxX
            check(abs(margin - Design.edgeMargin) < 1, "\(side): la tarjeta queda pegada a su borde (\(margin))")
            check(abs(home.minY - visible.minY - Design.edgeMargin) < 1, "\(side): la tarjeta queda abajo")
            check(abs(thumbs.testFrames[1].minY - home.maxY - Design.stackGap) < 1, "\(side): la pila crece hacia arriba con su separación")

            thumbs.testSwipe(index: 0, delta: -outward * 300)
            let inward = (thumbs.testFrames[0].minX - home.minX) * outward
            check(inward < 0 && inward > -24, "\(side): hacia dentro cede muy poco (\(inward))")
            thumbs.testEndSwipe(index: 0)
            check(thumbs.visibleCount == 2, "\(side): un gesto hacia dentro no cierra")
            await wait(0.8)

            thumbs.testSwipe(index: 0, delta: outward * 150)
            check(abs(thumbs.testFrames[0].minX - (home.minX + outward * 150)) < 1, "\(side): el gesto la lleva hacia su borde")
            let outside = thumbs.testExitFrame(from: home)
            check(onLeft ? outside.maxX < display.frame.minX : outside.minX > display.frame.maxX, "\(side): sale por el borde más cercano (\(outside))")
            thumbs.testEndSwipe(index: 0)
            check(thumbs.visibleCount == 1, "\(side): deslizar hacia el borde la cierra")
            thumbs.dismissAll()
        }
        Settings.shared.thumbnailsOnLeft = savedSide
        await wait(0.5)

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

        // Congelar no esconde nada en macOS 14 o más nuevo: la capa oscura queda fuera del filtro.
        let frozenMark = colorPanel(selection.appKitRect, NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        await wait(0.4)
        let freezer = SelectionOverlay()
        freezer.begin(mode: .screenshot) { _ in }
        await wait(0.3)
        freezer.testFreeze()
        check(freezer.testFreezeCaption == "Congelada", "el botón queda activo y dice Congelada")
        check(await until(3) { freezer.testFrozenImage != nil }, "congelar deja la imagen de la pantalla")
        if let frozen = freezer.testFrozenImage {
            let frozenRep = NSBitmapImageRep(cgImage: frozen)
            let frozenScale = CGFloat(frozen.width) / screen.frame.width
            let spot = frozenRep.colorAt(x: Int(280 * frozenScale), y: Int(195 * frozenScale))?.usingColorSpace(.sRGB)
            check((spot?.greenComponent ?? 0) > 0.85, "la imagen congelada no lleva la capa oscura (\(spot?.greenComponent ?? 0))")
        }
        freezer.simulateHover(at: CGPoint(x: 400, y: 300))
        check(freezer.testLoupeSide == 96, "la lupa es un círculo de 96")
        freezer.cancel()
        frozenMark.orderOut(nil)

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
        let textScan = await scan(textURL)
        check(textScan.text.contains("Pedidos de hoy"), "lee texto en una imagen")
        check(textScan.text.contains("Error al guardar"), "lee texto en español")
        check(textScan.code == nil, "una imagen sin código QR no inventa uno")

        let payload = "https://ejemplo.test/zas?pedido=1045"
        if let qrURL = qrFile(payload) {
            let qrScan = await scan(qrURL)
            check(qrScan.code == payload, "lee el contenido de un código QR (\(qrScan.code ?? "nada"))")
        } else {
            check(false, "genera un código QR de prueba")
        }

        Capture.copyText("hola")
        check(NSPasteboard.general.string(forType: .string) == "hola", "copiar texto al portapapeles")
    }

    private static func scan(_ url: URL) async -> TextScan {
        await withCheckedContinuation { (continuation: CheckedContinuation<TextScan, Never>) in
            TextReader.scan(from: url) { continuation.resume(returning: $0) }
        }
    }

    /// Un código QR nítido sobre blanco, con el margen que pide el formato.
    private static func qrFile(_ message: String, pixels: CGFloat = 10) -> URL? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage?
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: pixels, y: pixels))
        else { return nil }
        let extent = code.extent
        guard let cgCode = CIContext().createCGImage(code, from: extent) else { return nil }
        let margin = 60
        let width = cgCode.width + margin * 2
        let height = cgCode.height + margin * 2
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(cgCode, in: CGRect(x: margin, y: margin, width: cgCode.width, height: cgCode.height))
        guard let image = context.makeImage() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qr-\(UUID().uuidString).png")
        return Capture.writePNG(image, to: url, pointSize: CGSize(width: width, height: height)) ? url : nil
    }

    // MARK: - Historial y escritorio

    private static func historyTests() async {
        let shotFile = URL(fileURLWithPath: "/x/Zas 1.png")
        let videoFile = URL(fileURLWithPath: "/x/Zas 2.mp4")
        let gifFile = URL(fileURLWithPath: "/x/Zas 3.gif")
        let upperFile = URL(fileURLWithPath: "/x/Zas 4.PNG")
        let model = HistoryModel(files: [shotFile, videoFile, gifFile, upperFile])
        check(model.visible.count == 4 && model.focused == shotFile, "Todo muestra cada archivo y enfoca el primero")
        model.select(.images)
        check(model.visible == [shotFile, upperFile], "Capturas filtra las imágenes")
        model.select(.videos)
        check(model.visible == [videoFile], "Videos filtra los videos")
        model.select(.gifs)
        check(model.visible == [gifFile], "GIF filtra por extensión")
        model.select(.all)
        model.move(by: 2)
        check(model.focused == gifFile, "las flechas mueven el enfoque")
        model.move(by: 9)
        check(model.focused == upperFile, "el enfoque se detiene en la última")
        model.move(by: -9)
        check(model.focused == shotFile, "el enfoque se detiene en la primera")
        model.move(by: 1)
        model.load([shotFile, gifFile, upperFile])
        check(model.focused == gifFile, "al borrar la enfocada, pasa a la siguiente")
        model.select(.videos)
        check(model.focused == nil, "un filtro vacío no enfoca nada")
        model.cycleFilter(by: 1)
        check(model.filter == .gifs, "Tab pasa al filtro siguiente")
        model.cycleFilter(by: -2)
        check(model.filter == .images, "volver atrás recorre los filtros")

        // Archivos reales, para probar la lista y el panel.
        let samples = historySamples()
        check(Recents.files(limit: 500).contains { HistoryFilter.gifs.includes($0) }, "el historial incluye los GIF")
        check(Recents.preview(of: samples[samples.count - 1]) != nil, "un GIF tiene carátula")

        CGWarpMouseCursorPosition(CGPoint(x: 300, y: 300))
        await wait(0.2)
        let windows = WindowCoordinator()
        keepAlive.append(windows)
        var opened: URL?
        windows.showHistory { opened = $0 }
        guard let history = windows.testHistory else {
            check(false, "se abre el historial")
            return
        }
        history.closesOnFocusLoss = false
        await wait(0.9)
        check(history.testCanBecomeKey, "el panel del historial puede recibir teclado")
        check(history.testFrame.width == NSScreen.underMouse.frame.width - HistoryController.inset * 2, "el historial ocupa todo el ancho, con su margen a cada lado")
        check(history.testFrame.minY == NSScreen.underMouse.frame.minY + HistoryController.inset, "el historial queda a su margen del borde inferior")
        history.testKey(124)
        check(history.model.focus == 1, "la flecha derecha pasa a la siguiente tarjeta")
        history.testKey(123)
        check(history.model.focus == 0, "la flecha izquierda vuelve")
        history.testWheel(lines: -1)
        check(history.model.focus == 1, "la rueda pasa tarjetas")
        history.testKey(48)
        check(history.model.filter == .images, "Tab cambia de filtro")
        let expected = history.model.focused
        history.testKey(36)
        check(opened != nil && opened == expected, "Enter abre la enfocada")
        check(windows.testHistory == nil, "abrir cierra el historial")

        windows.showHistory { _ in }
        windows.testHistory?.closesOnFocusLoss = false
        await wait(0.3)
        windows.testHistory?.testKey(53)
        check(windows.testHistory == nil, "Esc cierra el historial")
        await wait(0.3)
        samples.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Carátulas de muestra en la carpeta real. La última de la lista es un GIF.
    private static func historySamples() -> [URL] {
        let sizes = [(900, 560), (640, 400), (1000, 300), (500, 620), (760, 480)]
        var files: [URL] = []
        for (index, size) in sizes.enumerated() {
            let source = pngFile(demoImage(scale: 1, width: size.0, height: size.1))
            let file = Capture.folder.appendingPathComponent("Zas muestra \(index).png")
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: source, to: file)
            files.append(file)
        }
        let gif = Capture.folder.appendingPathComponent("Zas muestra.gif")
        if let rep = demoImage(scale: 1, width: 640, height: 400).representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            try? rep.representation(using: .gif, properties: [:])?.write(to: gif)
        }
        files.append(gif)
        return files
    }

    private static func desktopCoverTests() async {
        check(!Settings(defaults: UserDefaults(suiteName: "zas-pruebas-\(UUID().uuidString)")!).hidesDesktopIcons, "al abrir Zas, los iconos se ven")
        check(DesktopCover.gravity(scaling: .scaleProportionallyUpOrDown, allowsClipping: true) == .resizeAspectFill, "la copia del fondo llena la pantalla igual que el original")
        check(DesktopCover.gravity(scaling: .scaleProportionallyUpOrDown, allowsClipping: false) == .resizeAspect, "la copia respeta el ajuste a la pantalla")
        check(DesktopCover.gravity(scaling: .scaleAxesIndependently, allowsClipping: false) == .resize, "la copia respeta el estirado")

        let cover = DesktopCover()
        cover.setOn(true)
        for _ in 0..<50 where cover.testWindows.isEmpty {
            await wait(0.1)
        }
        check(cover.testWindows.count == NSScreen.screens.count, "hay una cubierta por pantalla (\(cover.testWindows.count))")
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        check(cover.testWindows.allSatisfy { $0.level.rawValue == iconLevel + 1 }, "la cubierta queda justo encima de los iconos")
        check(cover.testWindows.allSatisfy { $0.ignoresMouseEvents }, "la cubierta deja pasar el ratón")
        check(cover.testWindows.allSatisfy { $0.collectionBehavior.contains(.canJoinAllSpaces) && $0.collectionBehavior.contains(.stationary) }, "la cubierta sigue en todos los Espacios")
        check(cover.testWindows.allSatisfy { $0.sharingType != .none }, "la cubierta sale en las capturas")
        check(cover.windowIDs.count == NSScreen.screens.count, "el video puede incluir la cubierta")
        cover.setOn(false)
        check(cover.testWindows.isEmpty, "la cubierta se apaga")
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

        // GIF y recorte, sobre el video recién grabado.
        let gif = FileManager.default.temporaryDirectory.appendingPathComponent("(UUID().uuidString).gif")
        let gifOK = await GifExporter.export(video: url, to: gif)
        check(gifOK && NSImage(contentsOf: gif) != nil, "se puede crear un GIF")
        let trimmed = FileManager.default.temporaryDirectory.appendingPathComponent("(UUID().uuidString).mp4")
        let trimOK = await VideoTrimmer.export(video: url, from: .zero, to: CMTime(seconds: 1, preferredTimescale: 600), output: trimmed)
        let trimmedLength = (try? await AVURLAsset(url: trimmed).load(.duration))?.seconds ?? 0
        check(trimOK && trimmedLength < 1.6, "se puede recortar un video (\(String(format: "%.1f", trimmedLength)) s)")

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

    /// Lleva el cursor real a la tarjeta: uno simulado se perdería al revisar dónde está de verdad.
    private static func hoverCard(_ thumbs: ThumbnailController, index: Int) async {
        let frame = thumbs.testFrames[index]
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: NSScreen.screens[0].frame.maxY - frame.midY))
        await wait(0.2)
        thumbs.testSyncHover()
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
            // Sobre el escritorio, sin ventana resaltada: solo la cruz y las coordenadas.
            overlay.simulateHover(at: CGPoint(x: 950, y: 90))
            let pointScale = NSScreen.screens[0].backingScaleFactor
            check(overlay.testCoordinates == "\(Int(950 * pointScale)), \(Int(90 * pointScale))", "las coordenadas van en una línea (\(overlay.testCoordinates ?? "nada"))")
            await shoot("\(label)-01b-cruz-coordenadas")
            overlay.simulateDrag(from: CGPoint(x: 310, y: 200), to: CGPoint(x: 760, y: 470))
            await shoot("\(label)-02-seleccion-area")
            // La firma de la captura, detenida a medio camino: en la app solo dura un instante.
            let signatureZone = Selection(screen: NSScreen.screens[0], rect: CGRect(x: 310, y: 200, width: 450, height: 270)).appKitRect
            CaptureSignature.shared.testFreeze(in: signatureZone, progress: 0.45)
            await shoot("\(label)-02c-firma-captura")
            CaptureSignature.shared.cancel()
            overlay.testFreeze()
            await wait(1)
            overlay.simulateHover(at: CGPoint(x: 400, y: 300))
            await shoot("\(label)-02b-congelada-lupa")
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
            // En reposo: que se asienten el resorte y los avisos.
            await wait(2.5)
            await shoot("\(label)-04-miniaturas")
            await hoverCard(thumbs, index: 0)
            await shoot("\(label)-04b-tarjeta-cursor")
            await hoverCard(thumbs, index: 2)
            await shoot("\(label)-04c-tarjeta-ancha")
            await hoverCard(thumbs, index: 3)
            await shoot("\(label)-04d-tarjeta-video")
            CGWarpMouseCursorPosition(CGPoint(x: 400, y: 330))
            await wait(0.2)
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

            // La antigua fila de opciones ya no existe: el lienzo ocupa todo menos las dos barras.
            if let room = editor.testWindow.contentView?.bounds.height {
                check(editor.testCanvasArea.height == room - Design.editorBar - Design.editorBottomBar, "el lienzo gana la altura de la fila de opciones")
            }
            editor.testSelect(tool: .arrow)
            editor.testOpenSizePopover()
            await shoot("\(label)-07g-popover-grosor")
            editor.testOpenSizePopover()
            await wait(0.3)

            // Cada casilla con variantes las reúne en el popover de estilo.
            let variantScenes: [(AnnotationTool, String)] = [(.rectangle, "07j-popover-forma"), (.pixelate, "07k-popover-ocultar"), (.pencil, "07l-popover-dibujar")]
            for (tool, scene) in variantScenes {
                editor.testSelect(tool: tool)
                editor.testOpenStylePopover()
                check(editor.testStylePopoverShown, "se abre el popover de \(tool.label)")
                await shoot("\(label)-\(scene)")
                editor.testOpenStylePopover()
                await wait(0.3)
            }

            editor.testOpenBackgroundPanel(gradient: 7)
            await wait(1)
            check(editor.testBackgroundPanelOpen && editor.testCanvasArea.minX == BackgroundPanel.width, "el panel Fondo abre y el lienzo le hace sitio")
            await shoot("\(label)-07h-panel-fondo")
            editor.testCloseBackgroundPanel()
            await wait(1)
            check(editor.testCanvasArea.minX == 0, "el panel Fondo se cierra y el lienzo recupera su sitio")
            await shoot("\(label)-07i-fondo-sin-panel")
            editor.canvas.setBackdrop(nil)

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
            windows.testSettingsPane(1)
            await shoot("\(label)-09a-atajos")
            check(windows.testSettingsTitle == "Atajos", "la ventana de ajustes nombra su pestaña")
            windows.testSettingsPane(2)
            await shoot("\(label)-09c-video")
            check(windows.testSettingsTitle == "Video", "el título sigue a la pestaña elegida")
            windows.closeAll()
            let samples = historySamples()
            windows.showHistory { _ in }
            windows.testHistory?.closesOnFocusLoss = false
            windows.testHistory?.testKey(124)
            await shoot("\(label)-09b-historial")
            windows.closeAll()
            samples.forEach { try? FileManager.default.removeItem(at: $0) }

            let visible = NSScreen.screens[0].frame
            let scrollArea = Selection(screen: NSScreen.screens[0], rect: CGRect(
                x: (visible.width * 0.3).rounded(),
                y: (visible.height * 0.12).rounded(),
                width: (visible.width * 0.5).rounded(),
                height: (visible.height * 0.62).rounded()
            ))
            let scrollHUD = ScrollCaptureHUD(selection: scrollArea.appKitRect, screen: scrollArea.screen, hiddenFromCapture: false)
            scrollHUD.show()
            if let long = demoImage(scale: 1, width: 296, height: 420).cgImage(forProposedRect: nil, context: nil, hints: nil) {
                scrollHUD.update(preview: long)
            }
            await shoot("\(label)-09e-desplazamiento")
            scrollHUD.close()

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

// MARK: - Apoyo de las pruebas nuevas

/// Números pseudoaleatorios propios (SplitMix64): la misma semilla da las mismas imágenes en cualquier Mac.
private struct SeededNumbers {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53)
    }

    mutating func below(_ limit: Int) -> Int {
        Int(next() % UInt64(limit))
    }

    mutating func pick<Item>(_ items: [Item]) -> Item {
        items[below(items.count)]
    }
}

/// Una imagen de la batería. Un tabulador separa columnas: Vision las entrega como trozos sueltos.
private struct TextCase {
    enum Surface {
        case plain(NSColor)
        case gradient(NSColor, NSColor, CGFloat)
        case noise(NSColor, CGFloat)
    }

    let category: String
    let surface: Surface
    let ink: NSColor
    let lines: [(text: String, font: NSFont)]
    let scale: Int
    let angle: CGFloat
    let margin: CGFloat

    var expected: String {
        lines.map { $0.text.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\n")
    }

    var name: String {
        "\(category) \(lines.first?.font.fontName ?? "") \(scale)x"
    }
}

private struct TextResult {
    let item: TextCase
    let image: NSImage
    let copied: Double
    let live: Double
    let copiedText: String
    let liveText: String

    var worst: Double { min(copied, live) }
}

/// Mide cuánto tiempo seguido estuvo ocupado el hilo principal: eso es lo que se siente como un tirón.
@MainActor
private final class StallProbe {
    private var timer: Timer?
    private var last = Date()
    private var worst = 0.0

    func start() {
        last = Date()
        worst = 0
        let ticking = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(ticking, forMode: .common)
        timer = ticking
    }

    private func tick() {
        let now = Date()
        worst = max(worst, now.timeIntervalSince(last) * 1000)
        last = now
    }

    /// El tirón más largo, en milisegundos.
    func stop() -> Double {
        tick()
        timer?.invalidate()
        timer = nil
        return worst
    }
}

private final class ValueBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

// MARK: - Sonidos

@MainActor
extension SelfTest {
    private static func soundTests() {
        for effect in SoundEffect.allCases {
            let samples = SoundSynth.samples(for: effect)
            let seconds = Double(samples.count) / SoundSynth.sampleRate
            let peak = samples.map { abs($0) }.max() ?? 1
            check(seconds > 0.03 && seconds <= effect.maximumDuration, "\(effect): dura lo debido (\(Int(seconds * 1000)) ms)")
            check(peak > 0.05 && peak < 0.5, "\(effect): suena suave, con pico bajo 0,5 (\(peak))")
            check(abs(samples.first ?? 1) < 0.001 && abs(samples.last ?? 1) < 0.001, "\(effect): empieza y acaba en cero")
            // Un clic es un salto brusco en los extremos.
            let edge = Int(SoundSynth.sampleRate * 0.0006)
            let jumps = zip(samples.prefix(edge), samples.dropFirst().prefix(edge)).map { abs($0 - $1) }
            let tailJumps = zip(samples.suffix(edge), samples.suffix(edge).dropFirst()).map { abs($0 - $1) }
            check((jumps + tailJumps).allSatisfy { $0 < 0.08 }, "\(effect): el fundido evita el clic")
            check(SoundSynth.samples(for: effect) == samples, "\(effect): siempre suena igual")

            let data = SoundSynth.wav(samples)
            check(data.count == 44 + samples.count * 2 && data.prefix(4) == Data("RIFF".utf8), "\(effect): es un WAV válido")
            let sound = NSSound(data: data)
            check(sound != nil && abs((sound?.duration ?? 0) - seconds) < 0.02, "\(effect): NSSound lo abre (\(sound?.duration ?? 0) s)")
        }

        let suite = "zas-pruebas-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            check(Settings(defaults: defaults).soundEffects, "los efectos de sonido vienen encendidos")
            Settings(defaults: defaults).soundEffects = false
            check(!Settings(defaults: defaults).soundEffects, "el ajuste de sonidos se recuerda")
            // Quien ya había apagado "Sonido al capturar" lo conserva.
            check(defaults.object(forKey: "playSound") as? Bool == false, "el ajuste usa la clave de antes")
            defaults.removePersistentDomain(forName: suite)
        }

        let saved = Settings.shared.soundEffects
        Settings.shared.soundEffects = true
        check(Sounds.canPlay, "con el ajuste encendido, Zas puede sonar")
        Sounds.isMuted = true
        check(!Sounds.canPlay && !Sounds.play(.copy), "durante una grabación no suena nada")
        Sounds.isMuted = false
        Settings.shared.soundEffects = false
        check(!Sounds.canPlay && !Sounds.play(.shutter), "con el ajuste apagado no suena nada")
        Settings.shared.soundEffects = saved
    }

    // MARK: - Orden del texto

    private static func textLayoutTests() {
        func piece(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 0.3, _ height: CGFloat = 0.05) -> TextPiece {
            TextPiece(text: text, box: CGRect(x: x, y: y, width: width, height: height))
        }
        check(
            TextLayout.ordered([piece("primera", 0.1, 0.8), piece("segunda", 0.1, 0.7)]) == "primera\nsegunda",
            "dos líneas en orden siguen igual"
        )
        check(
            TextLayout.ordered([piece("segunda", 0.1, 0.7), piece("primera", 0.1, 0.8)]) == "primera\nsegunda",
            "una línea que llega después de la de abajo vuelve a su sitio"
        )
        check(
            TextLayout.ordered([piece("precio", 0.6, 0.5), piece("nombre", 0.1, 0.5)]) == "nombre precio",
            "una fila partida se une de izquierda a derecha"
        )
        check(
            TextLayout.ordered([
                piece("a1", 0.05, 0.8), piece("a2", 0.05, 0.7), piece("b1", 0.55, 0.85), piece("b2", 0.55, 0.75),
            ]) == "a1\na2\nb1\nb2",
            "dos columnas no se mezclan"
        )
        check(
            TextLayout.ordered([
                piece("a1", 0.05, 0.8, 0.42), piece("a2", 0.05, 0.7, 0.42), piece("b1", 0.52, 0.8, 0.42), piece("b2", 0.52, 0.7, 0.42),
            ]) == "a1\na2\nb1\nb2",
            "un artículo a dos columnas alineadas se sigue leyendo por columnas"
        )
        check(
            TextLayout.ordered([
                piece("1042", 0.05, 0.8, 0.15), piece("1043", 0.05, 0.7, 0.15),
                piece("María", 0.4, 0.8, 0.15), piece("Carlos", 0.4, 0.7, 0.15),
                piece("$ 128", 0.75, 0.8, 0.15), piece("$ 54", 0.75, 0.7, 0.15),
            ]) == "1042 María $ 128\n1043 Carlos $ 54",
            "una tabla entregada por columnas se lee por filas"
        )
        check(TextLayout.ordered([]).isEmpty, "sin texto no sale nada")

        check(TextReader.enlargement(width: 1600, height: 900) == 2, "una captura mediana se duplica para leerla")
        check(TextReader.enlargement(width: 5120, height: 2880) == 1, "una pantalla 5K se lee tal cual")
        check(TextReader.enlargement(width: 380, height: 22) == 4, "una tira de una línea se amplía más")
        check(TextReader.enlargement(width: 5000, height: 20) == 1, "ampliar nunca pasa del tamaño máximo")
    }

    // MARK: - Selección de texto con imágenes aleatorias

    private static func color(_ value: UInt32) -> NSColor { NSColor.hex(value) }

    private static func textFonts() -> [(CGFloat) -> NSFont] {
        func named(_ name: String) -> (CGFloat) -> NSFont {
            { size in NSFont(name: name, size: size) ?? .systemFont(ofSize: size) }
        }
        return [
            { .systemFont(ofSize: $0) },
            named("Times New Roman"),
            { .monospacedSystemFont(ofSize: $0, weight: .regular) },
            named("Helvetica Neue"),
            named("Georgia"),
            named("Menlo"),
            { .systemFont(ofSize: $0, weight: .semibold) },
            named("Palatino"),
            named("Courier New"),
            named("Arial"),
            named("Baskerville"),
            named("Avenir Next"),
        ]
    }

    /// Sesenta imágenes, cuatro por categoría, siempre las mismas: la semilla es fija.
    private static func textCases() -> [TextCase] {
        let spanish = [
            "El pingüino comió piñas en el muelle",
            "Mañana habrá reunión a las ocho",
            "La canción del niño sonó así",
            "Añade más azúcar al café de Begoña",
            "Último aviso: revisión técnica pendiente",
            "¿Dónde está la cámara de fotos?",
            "¡Qué día tan útil para programar!",
            "El señor Núñez pagó la factura en enero",
        ]
        let english = [
            "The quick brown fox jumps over the lazy dog",
            "Please review the pull request before lunch",
            "Build failed on line 42 of main.swift",
            "Could not connect to the server",
            "Saved to the shared folder at noon",
            "Open the settings and turn it on",
        ]
        let numbers = [
            "Factura 2026-1187 total 4.530,75",
            "Teléfono 300 555 0142",
            "12:45 08/11/2026 turno 7731",
            "3.14159 2.71828 1.41421",
            "$ 128.000 + 19 % = $ 152.320",
            "Pedido 90210 caja 16 lote 305",
        ]
        let short = ["Hola mundo", "Guardar cambios", "Zas copia texto", "Abrir archivo", "Reunión mañana", "Copiar ruta", "Open file", "Año nuevo"]
        let table = [
            "Pedido 1042\tMaría Pérez\t$ 128.000",
            "Pedido 1043\tCarlos Rojas\t$ 54.500",
            "Pedido 1044\tAna Gómez\t$ 312.900",
            "Pedido 1045\tLuis Torres\t$ 87.250",
        ]
        func palette(_ values: [UInt32]) -> [NSColor] { values.map { NSColor.hex($0) } }
        let light = palette([0xFFFFFF, 0xF5F5F7, 0xFBF7EC, 0xEAF2FB, 0xE9E9EC])
        let dark = palette([0x000000, 0x1B1B1D, 0x10223F, 0x23172E, 0x2B2B2D])
        let darkInks = palette([0x000000, 0x1C1C1E, 0x2B2B33, 0x20304F])
        let lightInks = palette([0xFFFFFF, 0xF2F2F4, 0xE8EEF7, 0xFFF6DF])
        // Parejas con contraste de al menos 4,5 a 1: lo que se pide a una interfaz legible.
        let inkPairs: [(NSColor, NSColor)] = [
            (color(0xB3261E), color(0xFFF4F2)),
            (color(0x0B57D0), color(0xEEF3FE)),
            (color(0x0B6B3A), color(0xEAF7EF)),
            (color(0x6B21A8), color(0xF5EEFC)),
            (color(0xFFD60A), color(0x1C1C1E)),
            (color(0x7CF2D6), color(0x0F2B46)),
        ]

        var dice = SeededNumbers(state: 0x5A41_5320_5445_5854)
        var cases: [TextCase] = []
        var turn = 0
        let fonts = textFonts()

        func add(
            _ category: String,
            _ lines: [(text: String, size: CGFloat)],
            surface: TextCase.Surface,
            ink: NSColor,
            angle: CGFloat = 0,
            margin: CGFloat = 28
        ) {
            let font = fonts[turn % fonts.count]
            cases.append(TextCase(
                category: category,
                surface: surface,
                ink: ink,
                lines: lines.map { (text: $0.text, font: font($0.size)) },
                scale: turn % 2 == 0 ? 2 : 1,
                angle: angle,
                margin: margin
            ))
            turn += 1
        }
        func sized(_ size: CGFloat, _ texts: String...) -> [(text: String, size: CGFloat)] {
            texts.map { (text: $0, size: size) }
        }

        for _ in 0..<4 {
            let phrase = dice.pick(spanish + english)
            let size = CGFloat(14 + dice.below(15))
            add("oscuro sobre claro", sized(size, phrase), surface: .plain(dice.pick(light)), ink: dice.pick(darkInks))
        }
        for _ in 0..<4 {
            let phrase = dice.pick(spanish + english)
            let size = CGFloat(14 + dice.below(15))
            add("claro sobre oscuro", sized(size, phrase), surface: .plain(dice.pick(dark)), ink: dice.pick(lightInks))
        }
        for _ in 0..<4 {
            let pair = dice.pick(inkPairs)
            let size = CGFloat(15 + dice.below(14))
            add("colores", sized(size, dice.pick(spanish + english)), surface: .plain(pair.1), ink: pair.0)
        }
        for index in 0..<4 {
            let isLight = index % 2 == 0
            let surface = TextCase.Surface.gradient(
                isLight ? color(0xFFFFFF) : color(0x0F2B46),
                isLight ? color(0xBFD7F5) : color(0x3A1F5C),
                dice.unit() * 180
            )
            add("degradado", sized(CGFloat(16 + dice.below(16)), dice.pick(spanish + english)), surface: surface, ink: isLight ? color(0x111114) : color(0xFFFFFF))
        }
        for index in 0..<4 {
            let isLight = index % 2 == 0
            let amount = 0.06 + dice.unit() * 0.08
            let surface = TextCase.Surface.noise(isLight ? color(0xEDEDED) : color(0x202024), amount)
            add("ruido", sized(CGFloat(16 + dice.below(16)), dice.pick(spanish + english)), surface: surface, ink: isLight ? color(0x000000) : color(0xFFFFFF))
        }
        for index in 0..<4 {
            let size = CGFloat(14 + dice.below(10))
            let lines = (0..<(3 + index % 2)).map { step in (text: spanish[(step + index * 3) % spanish.count], size: size) }
            add("varias líneas", lines, surface: .plain(dice.pick(light)), ink: dice.pick(darkInks))
        }
        for index in 0..<4 {
            add("español", sized(CGFloat(16 + dice.below(12)), spanish[(index * 2 + 1) % spanish.count]), surface: .plain(dice.pick(light)), ink: dice.pick(darkInks))
        }
        for index in 0..<4 {
            add("inglés", sized(CGFloat(16 + dice.below(12)), english[index]), surface: .plain(dice.pick(light)), ink: dice.pick(darkInks))
        }
        for index in 0..<4 {
            add("números", sized(CGFloat(16 + dice.below(12)), numbers[index]), surface: .plain(dice.pick(light)), ink: dice.pick(darkInks))
        }
        for index in 0..<4 {
            let lines: [(text: String, size: CGFloat)] = [
                (short[index], 34), (spanish[index], 16), (english[index], 12),
            ]
            add("tamaños mezclados", lines, surface: .plain(dice.pick(light)), ink: dice.pick(darkInks))
        }
        for index in 0..<4 {
            let degrees = (1.5 + dice.unit() * 3) * (index % 2 == 0 ? 1 : -1)
            add("girado", sized(CGFloat(18 + dice.below(10)), dice.pick(spanish + english)), surface: .plain(dice.pick(light)), ink: dice.pick(darkInks), angle: degrees * .pi / 180)
        }
        for index in 0..<4 {
            let phrase = index % 2 == 0 ? spanish[index + 1] : english[index + 1]
            add("pequeño", sized(index < 2 ? 12 : 13, phrase), surface: .plain(dice.pick(light)), ink: dice.pick(darkInks))
        }
        for index in 0..<4 {
            add("grande", sized(index < 2 ? 64 : 56, short[index + 4]), surface: .plain(dice.pick(light)), ink: dice.pick(darkInks))
        }
        for index in 0..<4 {
            add("recorte justo", sized(CGFloat(13 + index), short[index]), surface: .plain(dice.pick(light)), ink: dice.pick(darkInks), margin: 2)
        }
        for index in 0..<4 {
            let rows = table.map { (text: $0, size: CGFloat(14 + index * 2)) }
            add("tabla", rows, surface: .plain(dice.pick(light)), ink: dice.pick(darkInks))
        }
        return cases
    }

    private static func render(_ item: TextCase, dice: inout SeededNumbers) -> NSImage? {
        func parts(of line: (text: String, font: NSFont)) -> [NSAttributedString] {
            line.text.components(separatedBy: "\t").map {
                NSAttributedString(string: $0, attributes: [.font: line.font, .foregroundColor: item.ink])
            }
        }
        let rows = item.lines.map { parts(of: $0) }
        let column = (rows.flatMap { $0 }.map { $0.size().width }.max() ?? 0) + 36
        let widths = rows.map { row in row.count > 1 ? column * CGFloat(row.count) : (row.first?.size().width ?? 0) }
        let gaps = item.lines.map { $0.font.pointSize * 0.45 }
        let heights = rows.map { row in row.map { $0.size().height }.max() ?? 0 }
        let contentWidth = widths.max() ?? 0
        let contentHeight = heights.reduce(0, +) + gaps.dropLast().reduce(0, +)
        let turn = abs(sin(item.angle))
        let room = item.margin + (turn * (contentWidth + contentHeight) / 2).rounded(.up)
        let width = Int((contentWidth + room * 2).rounded(.up))
        let height = Int((contentHeight + room * 2).rounded(.up))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * item.scale, pixelsHigh: height * item.scale, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = CGFloat(item.scale)
        context.cgContext.scaleBy(x: scale, y: scale)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        switch item.surface {
        case .plain(let fill):
            fill.setFill()
            bounds.fill()
        case .gradient(let start, let end, let angle):
            NSGradient(starting: start, ending: end)?.draw(in: bounds, angle: angle)
        case .noise(let fill, let amount):
            fill.setFill()
            bounds.fill()
            context.flushGraphics()
            addNoise(to: rep, amount: amount, dice: &dice)
        }

        let cg = context.cgContext
        cg.saveGState()
        cg.translateBy(x: bounds.midX, y: bounds.midY)
        cg.rotate(by: item.angle)
        cg.translateBy(x: -bounds.midX, y: -bounds.midY)
        var top = bounds.midY + contentHeight / 2
        for (index, row) in rows.enumerated() {
            top -= heights[index]
            let left = bounds.midX - contentWidth / 2
            for (place, part) in row.enumerated() {
                part.draw(at: CGPoint(x: left + CGFloat(place) * column, y: top))
            }
            top -= gaps[index]
        }
        cg.restoreGState()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        rep.size = NSSize(width: width, height: height)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private static func addNoise(to rep: NSBitmapImageRep, amount: CGFloat, dice: inout SeededNumbers) {
        guard let pixels = rep.bitmapData else { return }
        var table = [Int](repeating: 0, count: 8192)
        for index in table.indices {
            table[index] = Int((dice.unit() * 2 - 1) * amount * 255)
        }
        for y in 0..<rep.pixelsHigh {
            var index = dice.below(table.count)
            let row = pixels + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let change = table[index]
                index = (index + 1) & 8191
                for channel in 0..<3 {
                    let value = Int(row[x * 4 + channel]) + change
                    row[x * 4 + channel] = UInt8(max(min(value, 255), 0))
                }
            }
        }
    }

    /// Los espacios y saltos de línea no cuentan como error: sí el orden, las letras y las tildes.
    private static func normalized(_ text: String) -> [Character] {
        Array(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    /// 1 si son iguales. Es la distancia de edición dividida por el largo del texto más largo.
    static func similarity(_ first: String, _ second: String) -> Double {
        let a = normalized(first)
        let b = normalized(second)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for row in 0..<a.count {
            current[0] = row + 1
            for column in 0..<b.count {
                let swap = previous[column] + (a[row] == b[column] ? 0 : 1)
                current[column + 1] = min(swap, previous[column + 1] + 1, current[column] + 1)
            }
            (previous, current) = (current, previous)
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    private static func scan(image: CGImage) async -> TextScan {
        await withCheckedContinuation { (continuation: CheckedContinuation<TextScan, Never>) in
            TextReader.scan(image: image) { continuation.resume(returning: $0) }
        }
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f %%", value * 100)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Cada imagen pasa por el camino real: el lienzo la exporta y de ahí salen el texto que se copia
    /// y el análisis de Live Text que permite seleccionarlo.
    private static func textBattery() async {
        // Mínimo de acierto medio por categoría. Si una categoría no llega, primero se mira la imagen
        // `texto-peor-*`: un fallo de Zas se corrige en la app, una limitación de Vision se documenta
        // en CONTEXTO.md con el dato medido. El umbral no se baja para que la prueba pase.
        let thresholds: [(category: String, minimum: Double)] = [
            ("oscuro sobre claro", 0.95), ("claro sobre oscuro", 0.93), ("colores", 0.92),
            ("degradado", 0.90), ("ruido", 0.85), ("varias líneas", 0.92), ("español", 0.93),
            ("inglés", 0.95), ("números", 0.90), ("tamaños mezclados", 0.88), ("girado", 0.85),
            ("pequeño", 0.85), ("grande", 0.93), ("recorte justo", 0.85), ("tabla", 0.88),
        ]
        var dice = SeededNumbers(state: 0x5A41_5320_4E4F_4953)
        let cases = textCases()
        check(cases.count >= 40, "la batería tiene al menos 40 imágenes distintas (\(cases.count))")

        var results: [TextResult] = []
        for (index, item) in cases.enumerated() {
            guard let image = render(item, dice: &dice) else {
                check(false, "se puede dibujar la imagen \(item.name)")
                continue
            }
            let canvas = AnnotationCanvas(frame: CGRect(origin: .zero, size: image.size), image: image)
            guard let snapshot = canvas.textSnapshot() else {
                check(false, "el lienzo exporta la imagen \(item.name)")
                continue
            }
            let copied = await scan(image: snapshot.pixels)
            let live = await LiveText.analysis(of: snapshot.image)?.transcript ?? ""
            // ⇧⌘7 lee un archivo: cada cuatro imágenes se comprueba que da lo mismo.
            if index % 4 == 0 {
                let file = await scan(pngFile(snapshot.image, pixels: snapshot.pixels))
                check(file.text == copied.text, "leer desde archivo da lo mismo: \(item.name)")
            }
            let result = TextResult(
                item: item,
                image: snapshot.image,
                copied: similarity(item.expected, copied.text),
                live: similarity(item.expected, live),
                copiedText: copied.text,
                liveText: live
            )
            results.append(result)
            print(String(format: "texto %2d %3.0f %% copiar, %3.0f %% Live Text: %@", index, result.copied * 100, result.live * 100, item.name))
        }

        var report: [String] = []
        func say(_ line: String) {
            print(line)
            report.append(line)
        }
        let copiedScores = results.map(\.copied)
        let liveScores = results.map(\.live)
        say("Selección de texto: \(results.count) imágenes")
        say("Acierto medio: copiar \(percent(mean(copiedScores))), Live Text \(percent(mean(liveScores)))")
        say("Peor caso: copiar \(percent(copiedScores.min() ?? 0)), Live Text \(percent(liveScores.min() ?? 0))")
        for scale in [1, 2] {
            let group = results.filter { $0.item.scale == scale }
            say("\(scale)x: copiar \(percent(mean(group.map(\.copied)))), Live Text \(percent(mean(group.map(\.live))))")
        }

        for entry in thresholds {
            let group = results.filter { $0.item.category == entry.category }
            let copiedMean = mean(group.map(\.copied))
            let liveMean = mean(group.map(\.live))
            let worst = group.map(\.worst).min() ?? 0
            say("\(entry.category): copiar \(percent(copiedMean)), Live Text \(percent(liveMean)), peor \(percent(worst)), mínimo \(percent(entry.minimum))")
            check(!group.isEmpty && copiedMean >= entry.minimum, "copiar texto, \(entry.category): \(percent(copiedMean))")
            // Live Text usa otro modelo y parte las líneas a su manera: se le dan cinco puntos de margen.
            check(!group.isEmpty && liveMean >= entry.minimum - 0.05, "Live Text, \(entry.category): \(percent(liveMean))")
        }
        check(mean(copiedScores) >= 0.92, "acierto medio al copiar texto (\(percent(mean(copiedScores))))")
        check((copiedScores.min() ?? 0) >= 0.6, "ninguna imagen se lee mal del todo (\(percent(copiedScores.min() ?? 0)))")
        for scale in [1, 2] {
            let group = results.filter { $0.item.scale == scale }.map(\.copied)
            check(mean(group) >= 0.9, "acierto medio en capturas \(scale)x (\(percent(mean(group))))")
        }

        // Las tildes y la eñe son lo primero que se pierde.
        let marks = Set("áéíóúüñÁÉÍÓÚÜÑ¿¡")
        var expectedMarks = 0
        var foundMarks = 0
        for result in results where result.item.category == "español" || result.item.category == "varias líneas" {
            let wanted = Array(result.item.expected).filter { marks.contains($0) }
            var read = Array(result.copiedText).filter { marks.contains($0) }
            expectedMarks += wanted.count
            for mark in wanted {
                if let place = read.firstIndex(of: mark) {
                    read.remove(at: place)
                    foundMarks += 1
                }
            }
        }
        let keptMarks = Double(foundMarks) / Double(max(expectedMarks, 1))
        say("Tildes y eñes conservadas: \(percent(keptMarks)) de \(expectedMarks)")
        check(keptMarks >= 0.85, "se conservan las tildes y la eñe (\(percent(keptMarks)))")

        let worst = results.sorted { $0.worst < $1.worst }.prefix(3)
        for (index, result) in worst.enumerated() {
            say("Peor \(index + 1): \(result.item.name), \(percent(result.worst))")
            say("  esperado: \(result.item.expected.replacingOccurrences(of: "\n", with: " | "))")
            say("  copiado: \(result.copiedText.replacingOccurrences(of: "\n", with: " | "))")
            say("  Live Text: \(result.liveText.replacingOccurrences(of: "\n", with: " | "))")
            if let rep = result.image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: output.appendingPathComponent("texto-peor-\(index + 1).png"))
            }
        }
        try? report.joined(separator: "\n").write(to: output.appendingPathComponent("texto-resumen.txt"), atomically: true, encoding: .utf8)
    }

    private static func pngFile(_ image: NSImage, pixels: CGImage) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("texto-\(UUID().uuidString).png")
        _ = Capture.writePNG(pixels, to: url, pointSize: image.size)
        return url
    }

    // MARK: - Repaso de funciones

    private static func until(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
        let limit = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < limit else { return false }
            await wait(0.02)
        }
        return true
    }

    private static func isRed(_ color: NSColor?) -> Bool {
        let rgb = color?.usingColorSpace(.sRGB)
        return (rgb?.redComponent ?? 0) > 0.8 && (rgb?.greenComponent ?? 1) < 0.3
    }

    private static func representation(of url: URL?) -> NSBitmapImageRep? {
        url.flatMap { try? Data(contentsOf: $0) }.flatMap { NSBitmapImageRep(data: $0) }
    }

    /// Un editor de 600 × 400 a escala 2 con una flecha roja que pasa por (80, 70).
    private static func markedEditor() -> AnnotationEditor {
        let editor = AnnotationEditor(image: demoImage(width: 600, height: 400), file: pngFile(demoImage(width: 600, height: 400)))
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        editor.canvas.add(Annotation(tool: .arrow, color: red, lineWidth: 6, points: [CGPoint(x: 40, y: 50), CGPoint(x: 120, y: 90)]))
        return editor
    }

    private static func hasMark(_ rep: NSBitmapImageRep?) -> Bool {
        guard let rep else { return false }
        return isRed(rep.colorAt(x: 160, y: rep.pixelsHigh - 140))
    }

    /// El panel Fondo de principio a fin: se elige, se exporta, se guarda el proyecto y se vuelve a abrir.
    private static func backgroundFlowTests(_ app: AppDelegate) async {
        let editor = markedEditor()
        editor.show()
        check(!editor.testPanel.testIsBuilt, "el panel Fondo no se construye hasta abrirlo")
        editor.testOpenBackgroundPanel(gradient: 3)
        await wait(0.9)
        check(editor.testPanel.testChosenGradient == 3, "el panel marca el degradado elegido")
        check(editor.canvas.document.backdrop?.kind == .gradient, "elegir un degradado lo aplica al lienzo")
        check(await until { editor.testPanel.testHasBlurSwatch }, "la muestra difuminada llega sin frenar el panel")

        let exported = editor.canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
        check(exported?.pixelsWide == 1456 && exported?.pixelsHigh == 1056, "con fondo, la exportación crece su margen (\(exported?.pixelsWide ?? 0)×\(exported?.pixelsHigh ?? 0))")
        check(isRed(exported?.colorAt(x: 288, y: 1056 - 268)), "la marca sale en su sitio sobre el fondo exportado")
        let corner = exported?.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB)
        check((corner?.alphaComponent ?? 0) > 0.99, "el degradado llena la esquina exportada")

        let steps = editor.canvas.historyCount
        editor.testPanel.testSetMargin(120)
        check(editor.canvas.document.backdrop?.margin == 120 && editor.canvas.historyCount == steps + 1, "el deslizador de margen aplica el cambio en un paso")
        check(editor.canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 1680, "el margen nuevo sale en la exportación")

        let project = FileManager.default.temporaryDirectory.appendingPathComponent("fondo-\(UUID().uuidString).zas")
        try? editor.canvas.projectData()?.write(to: project)
        if let reopened = app.testOpenProject(project) {
            check(reopened.canvas.document.backdrop == editor.canvas.document.backdrop, "el proyecto reabierto conserva el fondo")
            check(reopened.canvas.document.annotations.count == 1, "el proyecto reabierto conserva la marca")
            let again = reopened.canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
            check(again?.pixelsWide == 1680 && again?.pixelsHigh == 1280, "el proyecto reabierto exporta igual")
            reopened.testShowBackgroundPanel()
            check(reopened.testPanel.testChosenGradient == 3, "al reabrir, el panel muestra el degradado guardado")
            await wait(0.2)
            reopened.testCloseEditor()
        } else {
            check(false, "se reabre el proyecto con fondo")
        }

        editor.testPanel.testChooseBlur()
        check(editor.canvas.document.backdrop?.kind == .ownBlur, "se puede elegir la captura difuminada")
        check(editor.canvas.exportPNG() != nil, "el fondo difuminado se exporta")
        editor.testPanel.testChooseTransparent()
        let clear = editor.canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }
        check((clear?.colorAt(x: 2, y: 2)?.alphaComponent ?? 1) < 0.01, "el fondo transparente sale transparente")
        check(editor.testPanel.testGradientCount == 10, "el panel ofrece diez degradados")
        check(!editor.testPanel.testNoneIsChosen, "con un fondo elegido, Ninguno no está marcado")
        editor.testPanel.testChooseNone()
        check(editor.canvas.document.backdrop == nil, "Ninguno quita el fondo")
        check(editor.testPanel.testNoneIsChosen, "Ninguno es una muestra más y queda marcada")
        check(editor.canvas.exportPNG().flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 1200, "sin fondo, la exportación vuelve a su tamaño")
        check(editor.canvas.document.annotations.count == 1, "cambiar de fondo nunca toca la marca")
        await wait(0.2)
        editor.testCloseEditor()
    }

    /// Cada salida del editor debe llevar las marcas: copiar, ruta, fijar, Arrástrame, Compartir, guardar y Listo.
    private static func editorOutputTests() async {
        let pasteboard = NSPasteboard.general
        let editor = markedEditor()
        editor.show()
        await wait(0.2)

        pasteboard.clearContents()
        editor.testQuickCopy()
        check(await until { pasteboard.data(forType: .png) != nil }, "Copiar sin cerrar llena el portapapeles")
        check(hasMark(pasteboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }), "lo copiado lleva las marcas")
        check(pasteboard.types?.contains(.tiff) == true, "lo copiado también se ofrece como TIFF")

        editor.testCopyPath()
        let path = pasteboard.string(forType: .string) ?? ""
        check(path.contains("anotada") && hasMark(representation(of: URL(fileURLWithPath: path))), "la ruta copiada es de una copia con las marcas")
        editor.testCopyPath()
        check(pasteboard.string(forType: .string) == path, "sin cambios, la ruta no crea otra copia")

        let pinned = AnnotationEditor.testPinCount()
        editor.testPin()
        check(AnnotationEditor.testPinCount() == pinned + 1, "Fijar deja la imagen en pantalla")
        AnnotationEditor.testClosePins()

        // El arrastre real pide un ratón: aquí se prueba lo que recibe la otra app.
        let dragged = editor.testDragFile()
        check(dragged?.lastPathComponent.contains("anotada") == true && hasMark(representation(of: dragged)), "Arrástrame entrega el archivo con las marcas")
        let writable = (dragged as NSURL?)?.writableTypes(for: .general) ?? []
        check(writable.contains(.fileURL), "Arrástrame se puede soltar como archivo")

        // El selector abre un menú del sistema que detendría la prueba: se revisa lo que recibiría.
        let items = editor.testShareItems() ?? []
        check((items.first as? URL).map { hasMark(representation(of: $0)) } == true, "Compartir recibe el archivo con las marcas")
        check(items.count == 1, "Compartir recibe una sola imagen")
        _ = NSSharingServicePicker(items: items)

        let saved = Set(Recents.files(limit: 500))
        editor.testSaveCopy()
        let newFile = Set(Recents.files(limit: 500)).subtracting(saved).first
        check(newFile?.lastPathComponent.contains("anotada") == true && hasMark(representation(of: newFile)), "⌘S guarda una copia con las marcas")

        let finished = ValueBox(0)
        let finalFile = ValueBox<URL?>(nil)
        editor.onFinish = { _, file in
            finished.value += 1
            finalFile.value = file
        }
        pasteboard.clearContents()
        // Enter pulsado dos veces: una sola imagen.
        editor.testFinish()
        editor.testFinish()
        check(await until { finished.value > 0 }, "Listo termina")
        await wait(0.2)
        check(finished.value == 1, "Listo pulsado dos veces guarda una sola vez")
        check(hasMark(representation(of: finalFile.value)), "Listo guarda el resultado con las marcas")
        check(pasteboard.data(forType: .png) != nil, "Listo deja la imagen copiada")
        check(!editor.testWindow.isVisible, "Listo cierra el editor")
    }

    private static func editorControlTests() async {
        let editor = markedEditor()
        editor.show()
        await wait(0.3)

        for tool in AnnotationTool.allCases where !tool.key.isEmpty {
            editor.testKeyDown(tool.key.lowercased())
            check(editor.canvas.tool == tool, "la tecla \(tool.key) elige \(tool.label)")
        }
        let chosen = editor.canvas.tool
        editor.testKeyDown("")
        check(editor.canvas.tool == chosen, "una tecla muerta no elige la herramienta Imagen")
        editor.testKeyDown("a")

        Design.testReduceMotion = true
        editor.testZoomPreset(200)
        check(editor.testZoomLabel == "200%", "el zoom del menú cuenta sobre el tamaño real (\(editor.testZoomLabel ?? "nada"))")
        editor.testZoomPreset(100)
        check(editor.testZoomLabel == "100%", "el zoom vuelve al 100 %")

        // Ocho casillas quietas: elegir otra herramienta solo mueve el cuadrado activo.
        check(editor.testSlotCount == 8, "la barra tiene ocho herramientas")
        let toolFrames = editor.testToolFrames
        check(toolFrames.allSatisfy { $0.width == 30 && $0.height == 30 }, "cada herramienta mide 30 × 30")
        for slot in 0..<editor.testSlotCount {
            editor.testPressSlot(slot)
            check(editor.testToolFrames == toolFrames, "elegir la casilla \(slot) no mueve ninguna otra")
            check(editor.testCurrentSlot == slot && editor.testMarkerFrame == toolFrames[slot], "el cuadrado activo llega a la casilla \(slot)")
        }
        editor.testKeyDown("c")
        check(editor.testMarkerFrame == nil, "Recortar vive fuera de la tira: el cuadrado se aparta")

        // Cada letra sigue siendo su herramienta, aunque compartan casilla.
        for (key, slot) in [("r", 2), ("o", 2), ("x", 5), ("f", 5), ("p", 6), ("h", 6)] {
            editor.testKeyDown(key)
            check(editor.testCurrentSlot == slot, "la tecla \(key) enciende su casilla")
        }
        editor.testChooseShape(3)
        check(editor.canvas.tool == .arrow && editor.canvas.plainLine && editor.testCurrentSlot == 2, "Línea es una variante de Forma")
        editor.testKeyDown("a")
        check(editor.canvas.tool == .arrow && !editor.canvas.plainLine && editor.testCurrentSlot == 1, "la A devuelve la flecha con su punta")
        editor.testChooseShape(1)
        check(editor.canvas.tool == .rectangle && editor.canvas.filled, "Relleno es una variante de Forma")
        editor.testChooseShape(2)
        check(editor.canvas.tool == .ellipse && !editor.canvas.filled, "Círculo es una variante de Forma")
        editor.testPressSlot(0)
        check(!editor.testStyleEnabled, "Mover no tiene estilo que ajustar")
        editor.testPressSlot(2)
        check(editor.canvas.tool == .ellipse, "Forma vuelve a la última variante usada")
        editor.testChooseHide(1)
        check(editor.canvas.tool == .pixelate && editor.canvas.smoothBlur, "Desenfoque es una variante de Ocultar")
        editor.testChooseHide(2)
        check(editor.canvas.tool == .spotlight && editor.testStyleEnabled, "Foco es una variante de Ocultar y conserva su estilo")
        editor.testPressSlot(5)
        check(editor.testStylePopoverShown && editor.canvas.tool == .spotlight, "pulsar la casilla activa abre su estilo sin cambiar de herramienta")
        editor.testOpenStylePopover()
        await wait(0.3)
        editor.testKeyDown("a")
        Design.testReduceMotion = nil

        // El zoom con resorte: la etiqueta pasa por los valores de en medio. La máquina de pruebas
        // puede tener Reducir movimiento encendido: aquí se pide el movimiento completo.
        Design.testReduceMotion = false
        let zoomLabels = ValueBox<Set<String>>([])
        editor.testZoomPreset(200)
        _ = await until(1) {
            zoomLabels.value.insert(editor.testZoomLabel ?? "")
            return editor.testZoomLabel == "200%"
        }
        check(zoomLabels.value.count > 2, "el zoom se actualiza en vivo (\(zoomLabels.value.count) valores)")
        Design.testReduceMotion = true
        editor.testZoomPreset(100)
        Design.testReduceMotion = nil

        // Ventana al mínimo: nada se pisa y el lienzo sigue dentro.
        let window = editor.testWindow
        window.setContentSize(window.minSize)
        await wait(0.2)
        check(editor.testBarOverlaps == 0, "con el ancho mínimo, los controles no se pisan (\(editor.testBarOverlaps))")
        check(editor.testCanvasArea.height == (window.contentView?.bounds.height ?? 0) - Design.editorBar - Design.editorBottomBar, "con el alto mínimo, el lienzo llena su sitio")
        editor.testShowBackgroundPanel()
        await wait(0.9)
        check(editor.testCanvasArea.width == window.minSize.width - BackgroundPanel.width, "con el panel abierto y la ventana mínima, el lienzo se adapta")
        editor.testCloseBackgroundPanel()
        await wait(0.9)

        editor.testTextMode()
        check(editor.testTextPaneScaling == .scaleProportionallyDown, "seleccionar texto no agranda una captura pequeña")
        check(editor.testTextPaneFrames?.image == editor.testCanvasImageFrame, "al seleccionar texto la imagen se queda en su sitio")
        check(editor.testTextPaneFrames?.overlay == editor.testCanvasImageFrame, "la capa de Live Text mide lo mismo que la imagen")
        editor.testTextMode()
        await wait(0.2)
        editor.testCloseEditor()

        // Una tira de menú en una ventana alta: era donde cada palabra se resaltaba cuatro veces su alto.
        let strip = AnnotationEditor(image: demoImage(scale: 1, width: 380, height: 22), file: pngFile(demoImage(scale: 1, width: 380, height: 22)))
        strip.show()
        await wait(0.2)
        strip.testTextMode()
        check(strip.testTextPaneFrames?.overlay.size == CGSize(width: 380, height: 22), "en una tira, la capa de Live Text mide lo que la tira (\(strip.testTextPaneFrames?.overlay.size ?? .zero))")
        strip.testTextMode()
        await wait(0.2)
        strip.testCloseEditor()

        let wide = demoImage(scale: 1, width: 120, height: 80)
        let flipped = ImageTools.flipped(wide, horizontally: true)
        let flippedRep = flipped?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { NSBitmapImageRep(cgImage: $0) }
        let original = wide.representations.compactMap { $0 as? NSBitmapImageRep }.first
        let left = original?.colorAt(x: 2, y: 40)?.usingColorSpace(.sRGB)
        let right = flippedRep?.colorAt(x: 117, y: 40)?.usingColorSpace(.sRGB)
        check(abs((left?.redComponent ?? 9) - (right?.redComponent ?? 0)) < 0.05, "voltear pasa la izquierda a la derecha")
    }

    private static func reopenTests(_ app: AppDelegate) async {
        let pasteboard = NSPasteboard.general
        let samples = historySamples()
        defer { samples.forEach { try? FileManager.default.removeItem(at: $0) } }

        Settings.shared.thumbnailSeconds = 60
        pasteboard.clearContents()
        app.testReopen(samples[0])
        check(pasteboard.data(forType: .png) != nil, "abrir una captura del historial la copia")
        check(app.testCardCount == 1, "abrir una captura del historial saca su tarjeta")

        if let gif = samples.last {
            app.testReopen(gif)
            let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
            check(urls?.first?.lastPathComponent == gif.lastPathComponent, "abrir un GIF copia el archivo, con su movimiento")
        }
        let cards = app.testCardCount
        app.testReopen(URL(fileURLWithPath: "/tmp/zas-no-existe-\(UUID().uuidString).png"))
        check(app.testCardCount == cards, "un archivo borrado solo avisa")
        Toast.shared.hide()

        if let video = Recents.files(limit: 500).first(where: { HistoryFilter.videos.includes($0) }) {
            app.testReopen(video)
            check(await until { app.testCardCount == cards + 1 }, "abrir un video del historial saca su tarjeta")
        } else {
            check(false, "hay un video para abrir desde el historial")
        }
        app.testDismissCards()
        Settings.shared.thumbnailSeconds = 6

        let history = HistoryController { _ in }
        history.reload()
        // Se compara por nombre: la carpeta temporal puede llegar como /var o como /private/var.
        let trashed = samples[0]
        check(history.model.visible.contains { $0.lastPathComponent == trashed.lastPathComponent }, "el historial lista el archivo")
        try? FileManager.default.removeItem(at: trashed)
        history.reload()
        check(!history.model.visible.contains { $0.lastPathComponent == trashed.lastPathComponent }, "lo que se borra sale del historial")

        let strip = RecentsStripView()
        strip.reload(Array(samples.dropFirst().prefix(4)))
        check(await until { strip.testTileImages == 4 }, "el menú llena sus cuatro recientes sin esperar en el hilo principal")
    }

    private static func qrFlowTests() async {
        let payload = "https://ejemplo.test/zas?pedido=1045"
        guard let tiny = qrFile(payload, pixels: 3) else {
            check(false, "genera un código QR pequeño")
            return
        }
        let small = await scan(tiny)
        check(small.code == payload, "lee un código QR pequeño (\(small.code ?? "nada"))")

        // Un QR dentro de una pantalla con texto: es lo que pasa de verdad.
        guard let qr = qrFile(payload), let code = NSImage(contentsOf: qr) else {
            check(false, "genera un código QR de prueba")
            return
        }
        let image = demoImage(scale: 2, width: 900, height: 560)
        let combined = NSImage(size: image.size)
        combined.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: image.size))
        code.draw(in: CGRect(x: 600, y: 20, width: 280, height: 280))
        combined.unlockFocus()
        let tiff = combined.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qr-texto-\(UUID().uuidString).png")
        try? tiff?.representation(using: .png, properties: [:])?.write(to: url)
        let both = await scan(url)
        check(both.code == payload, "encuentra el QR entre el texto")
        check(both.text.contains("Pedidos de hoy"), "también lee el texto de alrededor")
        check(both.clipboardText == payload, "el QR manda sobre el texto que lo rodea")
        check(TextScan(text: "hola", code: nil).clipboardText == "hola", "sin QR se copia el texto")
    }

    /// Un cuadro al nivel de los iconos hace de icono: con la cubierta encendida no debe salir en la captura.
    private static func desktopIconTests() async {
        let screen = NSScreen.screens[0]
        let selection = Selection(screen: screen, rect: CGRect(x: 40, y: 200, width: 120, height: 80))
        let icon = colorPanel(selection.appKitRect, NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        icon.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        icon.orderFrontRegardless()
        await wait(0.4)

        func iconIsVisible() async -> Bool {
            let url = Capture.temporaryFileURL()
            _ = await capture(selection.captureArguments, to: url)
            let rep = representation(of: url)
            let center = rep?.colorAt(x: (rep?.pixelsWide ?? 0) / 2, y: (rep?.pixelsHigh ?? 0) / 2)?.usingColorSpace(.sRGB)
            try? FileManager.default.removeItem(at: url)
            return (center?.redComponent ?? 0) > 0.8 && (center?.greenComponent ?? 1) < 0.3 && (center?.blueComponent ?? 0) > 0.8
        }

        if await iconIsVisible() {
            let cover = DesktopCover()
            cover.setOn(true)
            check(await until { !cover.testWindows.isEmpty }, "la cubierta aparece")
            await wait(0.4)
            let hidden = await iconIsVisible()
            check(!hidden, "con Ocultar iconos, lo que está al nivel de los iconos no sale en la captura")
            cover.setOn(false)
            await wait(0.3)
            let back = await iconIsVisible()
            check(back, "al apagarlo, los iconos vuelven")
        } else {
            // Una ventana del sistema tapa esa esquina del escritorio virtual.
            print("sin comprobar: algo tapa el escritorio en esta máquina")
        }
        icon.orderOut(nil)
    }

    private static func picture(of view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.tiffRepresentation
    }

    private static func interactionTests() async {
        let pill = PillControl(content: .text("Hola"), width: 80, tooltip: "Prueba", target: nil, action: nil)
        let resting = picture(of: pill)
        pill.testSetHovering(true)
        let hovered = picture(of: pill)
        pill.testSetPressed(true)
        let pressed = picture(of: pill)
        pill.testSetPressed(false)
        pill.testSetHovering(false)
        check(resting != nil && hovered != resting && pressed != hovered, "la píldora cambia al pasar el cursor y al pulsarla")

        let glass = GlassButton(symbol: "pause", tooltip: "Prueba", target: nil, action: nil)
        let glassResting = glass.testFill
        glass.testSetHovering(true)
        let glassHovered = glass.testFill
        glass.testSetPressed(true)
        let glassPressed = glass.testFill
        check(glassHovered != glassResting && glassPressed != glassHovered, "el botón de vidrio cambia al pasar el cursor y al pulsarlo")

        // Un solo resorte, con la duración prometida.
        check(Design.springResponse == 0.42 && Design.springDamping == 0.86, "el resorte de Design es el decidido")
        let steps = ValueBox<[CGFloat]>([])
        Design.testReduceMotion = true
        Spring.run(step: { steps.value.append($0) })
        check(steps.value == [1], "con Reducir movimiento se llega al destino sin viaje")
        Design.testReduceMotion = false

        let started = Date()
        let ended = ValueBox<Date?>(nil)
        Spring.run(step: { steps.value.append($0) }, completion: { ended.value = Date() })
        check(await until(2) { ended.value != nil }, "el resorte termina")
        let length = ended.value?.timeIntervalSince(started) ?? 0
        check(length > 0.6 && length < 0.95, "el resorte dura lo debido (\(String(format: "%.2f", length)) s)")
        check(steps.value.count > 10 && steps.value.last == 1, "el resorte pasa por cuadros intermedios y acaba en su destino")
        Design.testReduceMotion = nil

        // La firma: acompaña al obturador, nunca entra en una captura y se va sola.
        check(Palette.bolt == NSColor.hex(0xFFCC00), "el amarillo de la firma es el del rayo")
        Design.testReduceMotion = false
        let signature = CaptureSignature.shared
        let signatureZone = CGRect(x: 200, y: 200, width: 300, height: 200)
        signature.play(in: signatureZone)
        check(signature.testIsShowing && signature.testHasEdge, "la firma recorre la zona capturada")
        check(signature.testIsHiddenFromCapture, "la firma se esconde de cualquier captura")
        signature.cancel()
        check(!signature.testIsShowing, "una captura nueva cancela la firma anterior")
        Design.testReduceMotion = nil
        Design.testReduceMotion = true
        signature.play(in: signatureZone)
        check(signature.testIsShowing && !signature.testHasEdge, "con Reducir movimiento la firma es solo un fundido")
        check(await until(1) { !signature.testIsShowing }, "el fundido se va solo")
        Design.testReduceMotion = false
        signature.play(in: signatureZone)
        check(await until(2) { !signature.testIsShowing }, "la firma se va sola al terminar su vuelta")
        Design.testReduceMotion = nil

        // Ajustes mide lo que su pestaña y se adapta a una pantalla baja.
        let windows = WindowCoordinator()
        keepAlive.append(windows)
        windows.showSettings()
        await wait(0.3)
        if let window = windows.testSettingsWindow {
            check(windows.testSettingsTabCount == 3, "Ajustes tiene sus tres pestañas en la barra")
            check(window.frame.width == Design.SettingsWindow.width, "Ajustes mide 500 de ancho")
            check(!window.styleMask.contains(.resizable) && !window.styleMask.contains(.miniaturizable), "Ajustes no se estira ni se minimiza, como el Settings del sistema")
            Design.testReduceMotion = true
            let general = window.frame.height
            let top = window.frame.maxY
            windows.testSettingsPane(1)
            check(window.frame.height != general && window.frame.maxY == top, "cada pestaña da su altura sin mover el borde de arriba")
            check(windows.testSettingsContentFits, "con espacio, el contenido no se desplaza")
            windows.testSettingsRoom = 320
            windows.testSettingsPane(2)
            check(window.frame.height == 320, "en una pantalla baja, Ajustes no pasa de lo que cabe (\(window.frame.height))")
            check(!windows.testSettingsContentFits, "en una pantalla baja, el contenido se desplaza")
            check(window.contentView?.subviews.first?.frame.size == window.contentView?.bounds.size, "el contenido de Ajustes sigue a la ventana")
            windows.testSettingsRoom = nil
            Design.testReduceMotion = nil
        } else {
            check(false, "se abre Ajustes")
        }
        windows.closeAll()

        // La tecla de la bienvenida se enciende con el atajo y la primera captura la despide.
        windows.showWelcome(hasPermission: true, openSettings: {}, relaunch: {})
        await wait(0.2)
        windows.lightWelcomeKey()
        check(windows.testWelcomeKeyIsLit, "el atajo se ilumina en la bienvenida")
        windows.dimWelcomeKey()
        check(!windows.testWelcomeKeyIsLit, "al cancelar, el atajo se apaga")
        windows.lightWelcomeKey()
        windows.finishWelcome()
        await wait(0.2)
        check(!windows.testWelcomeIsOpen, "la bienvenida se va con la primera captura")
        windows.closeAll()
    }

    private static func functionalTests() async {
        let app = AppDelegate()
        keepAlive.append(app)
        await backgroundFlowTests(app)
        await editorOutputTests()
        await editorControlTests()
        await reopenTests(app)
        await qrFlowTests()
        await desktopIconTests()
        await interactionTests()
    }

    // MARK: - Responsividad

    private static func milliseconds(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000
    }

    private static func middle(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func ninetyFifth(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count * 95 / 100, sorted.count - 1)]
    }

    private static func timing(_ value: Double) -> String {
        String(format: "%.0f ms", value)
    }

    /// PNG de una pantalla Retina con la densidad mal anotada, como a veces lo deja `screencapture`:
    /// es el peor caso, porque obliga a volver a codificarlo.
    private static func heavyCaptureFile() -> URL? {
        guard let rep = demoImage(scale: 2, width: 1440, height: 900).representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            return nil
        }
        rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pesada-\(UUID().uuidString).png")
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil ? url : nil
    }

    /// Los topes son para la máquina virtual de GitHub, sin GPU y con tres núcleos: un Mac real va varias veces más rápido.
    private static func responsivenessTests() async {
        CGWarpMouseCursorPosition(CGPoint(x: 300, y: 300))
        await wait(0.2)

        // Atajo a selección visible.
        var selectionTimes: [Double] = []
        for _ in 0..<5 {
            let overlay = SelectionOverlay()
            let start = Date()
            overlay.begin(mode: .screenshot) { _ in }
            CATransaction.flush()
            _ = await until(1) { overlay.testIsShowing }
            selectionTimes.append(milliseconds(since: start))
            overlay.cancel()
            await wait(0.15)
        }
        print("tiempo: atajo a selección \(timing(middle(selectionTimes))), peor \(timing(selectionTimes.max() ?? 0))")
        check(middle(selectionTimes) <= 150, "del atajo a la selección visible (\(timing(middle(selectionTimes))))")

        // Captura a tarjeta.
        Settings.shared.thumbnailSeconds = 60
        let thumbs = ThumbnailController()
        let probe = StallProbe()
        var cardTimes: [Double] = []
        var cardStalls: [Double] = []
        var springStalls: [Double] = []
        if let heavy = heavyCaptureFile() {
            let pointSize = CGSize(width: 1440, height: 900)
            for _ in 0..<5 {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tarjeta-\(UUID().uuidString).png")
                try? FileManager.default.copyItem(at: heavy, to: url)
                probe.start()
                let start = Date()
                guard let prepared = await Capture.prepare(at: url, pointSize: pointSize) else {
                    check(false, "se prepara la captura")
                    break
                }
                Capture.publish(prepared.data)
                thumbs.show(image: prepared.image, file: url, kind: .screenshot, from: CGRect(x: 200, y: 200, width: 720, height: 450), preview: prepared.preview)
                cardTimes.append(milliseconds(since: start))
                cardStalls.append(probe.stop())
                // La tarjeta encoge desde la selección: ahí es donde redibujar la imagen entera perdía cuadros.
                probe.start()
                await wait(0.7)
                springStalls.append(probe.stop())
            }
            check(thumbs.testDrawnPixels(index: 0) <= 900, "la tarjeta pinta una copia pequeña, no la captura entera (\(thumbs.testDrawnPixels(index: 0)) px)")
            check(await until { thumbs.testHasVeil(index: 0) }, "el velo de la tarjeta ya está listo antes de pasar el cursor")
            thumbs.dismissAll()
            print("tiempo: captura a tarjeta \(timing(middle(cardTimes))), tirón \(timing(cardStalls.max() ?? 0)), resorte \(timing(springStalls.max() ?? 0))")
            check(middle(cardTimes) <= 400, "de la captura a la tarjeta (\(timing(middle(cardTimes))))")
            check(middle(cardStalls) <= 120, "terminar una captura no traba la interfaz (\(timing(middle(cardStalls))))")
            check(middle(springStalls) <= 120, "el resorte de la tarjeta no pierde cuadros (\(timing(middle(springStalls))))")
        } else {
            check(false, "se crea la captura pesada")
        }
        Settings.shared.thumbnailSeconds = 6

        // Clic a editor abierto.
        let image = demoImage(scale: 2, width: 1440, height: 900)
        let file = pngFile(image)
        var editorTimes: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            let editor = AnnotationEditor(image: image, file: file)
            editor.show()
            editor.testWindow.displayIfNeeded()
            editorTimes.append(milliseconds(since: start))
            editor.testCloseEditor()
            await wait(0.2)
        }
        print("tiempo: clic a editor \(timing(middle(editorTimes))), peor \(timing(editorTimes.max() ?? 0))")
        check(middle(editorTimes) <= 300, "del clic al editor abierto (\(timing(middle(editorTimes))))")

        // Arrastre en un lienzo con doscientas marcas.
        let editor = AnnotationEditor(image: image, file: file)
        var dice = SeededNumbers(state: 0x5A41_5320_4D41_5243)
        for index in 0..<199 {
            let x = dice.unit() * 1300 + 40
            let y = dice.unit() * 780 + 40
            let tint = dice.pick([NSColor.systemRed, .systemBlue, .systemGreen, .systemOrange])
            switch index % 5 {
            case 0:
                editor.canvas.add(Annotation(tool: .rectangle, color: tint, lineWidth: 4, points: [CGPoint(x: x, y: y), CGPoint(x: x + 80, y: y + 50)]))
            case 1:
                editor.canvas.add(Annotation(tool: .arrow, color: tint, lineWidth: 5, points: [CGPoint(x: x, y: y), CGPoint(x: x + 90, y: y + 40)]))
            case 2:
                editor.canvas.add(Annotation(tool: .text, color: tint, lineWidth: 4, points: [CGPoint(x: x, y: y)], text: "Marca \(index)"))
            case 3:
                editor.canvas.add(Annotation(tool: .counter, color: tint, lineWidth: 5, points: [CGPoint(x: x, y: y)], number: index))
            default:
                let stroke = (0..<30).map { CGPoint(x: x + CGFloat($0) * 3, y: y + sin(CGFloat($0)) * 8) }
                editor.canvas.add(Annotation(tool: .pencil, color: tint, lineWidth: 3, points: stroke))
            }
        }
        editor.canvas.add(Annotation(tool: .rectangle, color: .systemPink, lineWidth: 5, points: [CGPoint(x: 400, y: 300), CGPoint(x: 520, y: 380)]))
        check(editor.canvas.document.annotations.count == 200, "el lienzo tiene doscientas marcas")
        editor.show()
        editor.testWindow.displayIfNeeded()
        await wait(0.3)

        var dragTimes: [Double] = []
        _ = editor.canvas.beginDrag(at: CGPoint(x: 460, y: 340))
        for step in 0..<120 {
            let target = CGPoint(x: 460 + CGFloat(step) * 4, y: 340 + sin(CGFloat(step) * 0.2) * 120)
            let start = Date()
            editor.canvas.continueDrag(to: target)
            editor.testWindow.displayIfNeeded()
            dragTimes.append(milliseconds(since: start))
        }
        editor.canvas.endDrag()
        print("tiempo: arrastre con 200 marcas, mitad \(timing(middle(dragTimes))), p95 \(timing(ninetyFifth(dragTimes)))")
        check(ninetyFifth(dragTimes) <= 33, "arrastrar con doscientas marcas va a 30 cuadros o más (p95 \(timing(ninetyFifth(dragTimes))))")

        // Censurar por primera vez: calcular la versión pixelada no debe frenar el dibujo.
        let plain = editor.canvas.exportPNG()
        let start = Date()
        editor.canvas.add(Annotation(tool: .pixelate, color: .red, lineWidth: 5, points: [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 300)], smoothBlur: true))
        editor.testWindow.displayIfNeeded()
        let censorTime = milliseconds(since: start)
        print("tiempo: primera censura \(timing(censorTime))")
        check(censorTime <= 100, "censurar no frena el dibujo (\(timing(censorTime)))")
        check(editor.canvas.exportPNG() != plain, "lo censurado sale en la exportación aunque se pida enseguida")
        await wait(0.3)
        editor.testCloseEditor()

        // Leer texto no ocupa el hilo principal.
        let snapshot = AnnotationCanvas(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), image: image).textSnapshot()
        if let snapshot {
            probe.start()
            _ = await scan(image: snapshot.pixels)
            let stall = probe.stop()
            print("tiempo: tirón al leer texto \(timing(stall))")
            check(stall <= 120, "leer texto no traba la interfaz (\(timing(stall)))")
        }
    }
}

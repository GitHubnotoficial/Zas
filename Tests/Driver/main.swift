// Usa Zas ya instalada como lo haría una persona: atajos reales, ratón real y portapapeles real.
// Se compila aparte y necesita el permiso de Accesibilidad para enviar eventos.
// Uso: ZasConductor <carpeta-de-imágenes>
import AVFoundation
import AppKit
import Carbon

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Zas", isDirectory: true)
let source = CGEventSource(stateID: .hidSystemState)
var passes = 0
var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        passes += 1
        print("ok    \(name)")
    } else {
        failures += 1
        print("FALLA \(name)")
    }
}

func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func press(_ keyCode: Int, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        wait(0.05)
    }
}

func hotKey(_ keyCode: Int) {
    press(keyCode, [.maskCommand, .maskShift])
}

func moveMouse(to point: CGPoint) {
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    wait(0.06)
}

func drag(from start: CGPoint, to end: CGPoint) {
    moveMouse(to: start)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    wait(0.08)
    for step in 1...12 {
        let t = CGFloat(step) / 12
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        wait(0.03)
    }
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    wait(0.1)
}

func click(at point: CGPoint) {
    moveMouse(to: point)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        wait(0.08)
    }
}

/// En la grabación demo se hace una pausa en cada paso para poder seguirlo.
let pace = Double(ProcessInfo.processInfo.environment["ZAS_PAUSA"] ?? "") ?? 0

func shot(_ name: String) {
    defer { wait(pace) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", output.appendingPathComponent("\(name).png").path]
    try? process.run()
    process.waitUntilExit()
}

func files(_ ext: String) -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return Set(names.filter { $0.hasSuffix(".\(ext)") })
}

/// Hace `action` y devuelve el archivo nuevo que aparezca en la carpeta.
func newFile(_ ext: String, timeout: Double = 4, _ action: () -> Void) -> URL? {
    let before = files(ext)
    action()
    let started = Date()
    let limit = started.addingTimeInterval(timeout)
    while Date() < limit {
        if let name = files(ext).subtracting(before).first {
            print(String(format: "tiempo: %@ apareció en %.2f s", name, Date().timeIntervalSince(started)))
            wait(0.3)
            return folder.appendingPathComponent(name)
        }
        wait(0.1)
    }
    print(String(format: "tiempo: nada nuevo tras %.1f s", timeout))
    return nil
}

func pixelSize(_ url: URL?) -> (Int, Int)? {
    guard let url else { return nil }
    // El archivo aparece antes de que screencapture termine de escribirlo.
    for _ in 0..<30 {
        if let rep = (try? Data(contentsOf: url)).flatMap({ NSBitmapImageRep(data: $0) }) {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        wait(0.1)
    }
    return nil
}

func windowFrame(owner: String) -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    for info in list ?? [] where (info[kCGWindowOwnerName as String] as? String) == owner {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else { continue }
        return rect
    }
    return nil
}

func zasWindowCount(minimumWidth: CGFloat) -> Int {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    return (list ?? []).filter { info in
        guard (info[kCGWindowOwnerName as String] as? String) == "Zas",
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else { return false }
        return rect.width >= minimumWidth
    }.count
}

/// El icono de Zas en la barra de menú.
func menuBarItem() -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    for info in list ?? [] where (info[kCGWindowOwnerName as String] as? String) == "Zas" {
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              rect.minY < 30, rect.height < 40, rect.width < 80
        else { continue }
        return rect
    }
    return nil
}

/// Ventana del aviso del sistema, sea cual sea el sitio donde aparezca.
func systemPromptFrame() -> CGRect? {
    let ignored: Set<String> = ["Zas", "Calculator", "Dock", "Window Server", "Control Center", "SystemUIServer", "Finder"]
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    for info in list ?? [] {
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        guard !ignored.contains(owner),
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              rect.width > 230, rect.width < 320, rect.height > 280, rect.height < 380
        else { continue }
        print("aviso del sistema: \(owner) \(rect)")
        return rect
    }
    return nil
}

func dismissSystemPrompt() {
    for _ in 0..<4 {
        guard let frame = systemPromptFrame() else { return }
        // El botón Allow queda 263 puntos por debajo del borde superior del aviso.
        click(at: CGPoint(x: frame.midX, y: frame.minY + 263))
        wait(0.8)
    }
}

let screen = NSScreen.screens[0]
let scale = Int(screen.backingScaleFactor)
print("pantalla \(screen.frame.size) escala \(scale)")

// Una app ajena con ventana, para probar la captura de ventana.
NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
wait(3)
let calculator = windowFrame(owner: "Calculator")
check(calculator != nil, "hay una ventana ajena en pantalla")

// 1. Área: atajo, arrastre y portapapeles.
moveMouse(to: CGPoint(x: 150, y: 120))
let region = newFile("png") {
    hotKey(kVK_ANSI_2)
    wait(0.7)
    shot("e2e-01-seleccion")
    drag(from: CGPoint(x: 160, y: 130), to: CGPoint(x: 460, y: 380))
}
check(region != nil, "⇧⌘2 y arrastrar crea el archivo")

// macOS 15 muestra su propio aviso en la primera captura. Se acepta como lo haría una persona.
wait(1.5)
shot("e2e-00-aviso-macos")
dismissSystemPrompt()

if let size = pixelSize(region) {
    check(size == (300 * scale, 250 * scale), "el área mide lo arrastrado (\(size))")
}
wait(0.6)
let types = NSPasteboard.general.types ?? []
check(types.contains(.png), "la captura queda en el portapapeles")
check(NSPasteboard.general.data(forType: .png)?.count ?? 0 > 1000, "el portapapeles tiene la imagen")
check(NSPasteboard.general.data(forType: .tiff)?.count ?? 0 > 1000, "el TIFF se genera cuando otra app lo pide")

// Lee el portapapeles desde otro proceso, con un comando de macOS, como PNG.
let reader = Process()
let readerOutput = Pipe()
reader.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
reader.arguments = ["-e", "the clipboard as «class PNGf»"]
reader.standardOutput = readerOutput
try? reader.run()
let pasted = readerOutput.fileHandleForReading.readDataToEndOfFile()
reader.waitUntilExit()
check(pasted.count > 1000, "otro proceso lee la captura como PNG (\(pasted.count) bytes)")
shot("e2e-02-miniatura")

// El menú de la barra, con sus recientes.
if let item = menuBarItem() {
    click(at: CGPoint(x: item.midX, y: item.midY))
    wait(0.7)
    shot("e2e-02b-menu")
    press(kVK_Escape)
    wait(0.4)
}

// 2. Miniatura: pasar el cursor y abrir el editor.
let visible = screen.visibleFrame
let thumbnailPoint = CGPoint(x: visible.maxX - 16 - 112, y: screen.frame.height - visible.minY - 16 - 40)
moveMouse(to: thumbnailPoint)
wait(0.5)
shot("e2e-03-miniatura-hover")
click(at: CGPoint(x: thumbnailPoint.x - 70, y: thumbnailPoint.y - 30))
wait(1.2)
check(zasWindowCount(minimumWidth: 700) >= 1, "clic en la miniatura abre el editor")
shot("e2e-04-editor")

// 3. Editor: dibujar con el ratón, deshacer, rehacer y copiar con Enter.
dismissSystemPrompt()
check(systemPromptFrame() == nil, "el aviso del sistema se puede aceptar y no tapa el editor")
let editorFrame = windowFrame(owner: "Zas")
if let editorFrame {
    click(at: CGPoint(x: editorFrame.midX, y: editorFrame.maxY - 8))
    wait(0.2)
    let center = CGPoint(x: editorFrame.midX, y: editorFrame.midY + 26)
    drag(from: CGPoint(x: center.x - 90, y: center.y - 50), to: CGPoint(x: center.x + 80, y: center.y + 50))
    wait(0.3)
    press(kVK_ANSI_R)
    wait(0.1)
    drag(from: CGPoint(x: center.x - 100, y: center.y + 30), to: CGPoint(x: center.x - 20, y: center.y + 90))
    wait(0.3)
    shot("e2e-05-editor-dibujado")
    press(kVK_ANSI_Z, .maskCommand)
    wait(0.3)
    shot("e2e-06-editor-deshecho")
    press(kVK_ANSI_Z, [.maskCommand, .maskShift])
    wait(0.3)

    // Esc con marcas pregunta. Un segundo Esc sigue editando.
    press(kVK_Escape)
    wait(0.7)
    shot("e2e-06b-confirmar-cierre")
    press(kVK_Escape)
    wait(0.6)
    check(zasWindowCount(minimumWidth: 700) >= 1, "Esc con marcas no pierde el dibujo")

    let beforeCopy = NSPasteboard.general.changeCount
    let annotated = newFile("png") {
        press(kVK_Return)
    }
    check(annotated?.lastPathComponent.contains("anotada") == true, "Enter guarda la versión anotada")
    // La flecha y el cuadro se dibujaron sobre una imagen negra: buscar su rojo prueba que funcionó el ratón.
    if let annotated, let rep = (try? Data(contentsOf: annotated)).flatMap({ NSBitmapImageRep(data: $0) }) {
        var redPixels = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.redComponent > 0.7, color.greenComponent < 0.4 {
                    redPixels += 1
                }
            }
        }
        check(redPixels > 150, "lo dibujado con el ratón sale en la imagen (\(redPixels) puntos rojos)")
    }
    wait(0.4)
    check(NSPasteboard.general.changeCount != beforeCopy, "la versión anotada queda en el portapapeles")
    check(zasWindowCount(minimumWidth: 700) == 0, "el editor se cierra al copiar")
    shot("e2e-07-tras-copiar")
}

// 4. Cancelar con Esc no deja nada.
let canceled = newFile("png", timeout: 1) {
    hotKey(kVK_ANSI_2)
    wait(0.5)
    press(kVK_Escape)
}
check(canceled == nil, "Esc cancela sin capturar")
wait(0.4)
check(zasWindowCount(minimumWidth: screen.frame.width - 1) == 0, "tras cancelar no queda la pantalla oscurecida")

// Repetir la última captura: la misma área, sin volver a elegirla.
let repeated = newFile("png", timeout: 6) {
    hotKey(kVK_ANSI_9)
}
if let size = pixelSize(repeated) {
    check(size == (300 * scale, 250 * scale), "⇧⌘9 repite la última área (\(size))")
} else {
    check(false, "⇧⌘9 repite la última área")
}
wait(0.8)

// Repetir el atajo también cancela.
let toggled = newFile("png", timeout: 1) {
    hotKey(kVK_ANSI_2)
    wait(0.5)
    hotKey(kVK_ANSI_2)
}
check(toggled == nil, "repetir el atajo cancela sin capturar")
wait(0.4)
check(zasWindowCount(minimumWidth: screen.frame.width - 1) == 0, "tras repetir el atajo no queda la pantalla oscurecida")

// 5. Ventana: clic sobre la ventana ajena.
if let calculator {
    let window = newFile("png") {
        moveMouse(to: CGPoint(x: calculator.midX, y: calculator.midY))
        hotKey(kVK_ANSI_2)
        wait(0.7)
        shot("e2e-08-seleccion-ventana")
        click(at: CGPoint(x: calculator.midX, y: calculator.midY))
    }
    check(window != nil, "clic en una ventana la captura")
    if let size = pixelSize(window) {
        // Con dos pantallas, la ventana puede estar en la que no es la principal.
        let home = NSScreen.screens.first { $0.frame.minX <= calculator.midX && calculator.midX < $0.frame.maxX } ?? screen
        let windowScale = Int(home.backingScaleFactor)
        check(size == (Int(calculator.width) * windowScale, Int(calculator.height) * windowScale), "la captura mide la ventana (\(size))")
    }
}

// 6. Pantalla completa.
moveMouse(to: CGPoint(x: 300, y: 300))
wait(0.3)
let full = newFile("png", timeout: 12) {
    hotKey(kVK_ANSI_1)
}
if let size = pixelSize(full) {
    check(size == (Int(screen.frame.width) * scale, Int(screen.frame.height) * scale), "⇧⌘1 captura toda la pantalla (\(size))")
} else {
    check(false, "⇧⌘1 captura toda la pantalla")
}
wait(0.6)
shot("e2e-09-pila")

// Temporizador: se elige el área y la captura llega tres segundos después.
let timed = newFile("png", timeout: 6) {
    hotKey(kVK_ANSI_8)
    wait(0.6)
    drag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 500, y: 400))
    wait(1)
    shot("e2e-09b-cuenta-atras")
}
if let size = pixelSize(timed) {
    check(size == (300 * scale, 200 * scale), "⇧⌘8 captura el área elegida (\(size))")
} else {
    check(false, "⇧⌘8 captura el área elegida")
}

// 7. Texto: la barra de menú siempre tiene texto.
NSPasteboard.general.clearContents()
hotKey(kVK_ANSI_7)
wait(0.7)
drag(from: CGPoint(x: 40, y: 1), to: CGPoint(x: 420, y: 23))
wait(3)
let recognized = NSPasteboard.general.string(forType: .string) ?? ""
print("texto reconocido: \(recognized.replacingOccurrences(of: "\n", with: " | "))")
check(!recognized.isEmpty, "⇧⌘7 copia texto de la pantalla")

// 8. Video con los atajos reales.
let video = newFile("mp4", timeout: 10) {
    hotKey(kVK_ANSI_6)
    wait(0.7)
    drag(from: CGPoint(x: 120, y: 120), to: CGPoint(x: 620, y: 420))
    wait(1.5)
    shot("e2e-10-grabando")
    hotKey(kVK_ANSI_2)
    wait(0.5)
    shot("e2e-10b-aviso-grabando")
    check(zasWindowCount(minimumWidth: screen.frame.width - 1) == 0, "capturar mientras graba avisa y no abre la selección")
    for step in 0..<12 {
        moveMouse(to: CGPoint(x: 200 + step * 25, y: 250))
        wait(0.15)
    }
    wait(1.2)
    hotKey(kVK_ANSI_6)
}
check(video != nil, "⇧⌘6 graba y guarda un video")
if let video {
    check(((try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0) > 2000, "el video tiene contenido")
}
wait(1)
wait(2.5)
check(NSPasteboard.general.data(forType: .png)?.count ?? 0 > 1000, "al terminar, el resumen del video queda copiado")
check(files("png").contains { $0.hasSuffix(" resumen.png") }, "el resumen queda guardado junto al video")
shot("e2e-11-video-listo")

// 9. Cerrar la app mientras graba no debe perder el video.
let interrupted = newFile("mp4", timeout: 12) {
    hotKey(kVK_ANSI_6)
    wait(0.7)
    drag(from: CGPoint(x: 140, y: 140), to: CGPoint(x: 540, y: 400))
    for step in 0..<20 {
        moveMouse(to: CGPoint(x: 180 + step * 15, y: 260))
        wait(0.1)
    }
    NSRunningApplication.runningApplications(withBundleIdentifier: "local.zas.app").first?.terminate()
}
check(interrupted != nil, "cerrar Zas mientras graba guarda el video")
if let interrupted {
    wait(1)
    let semaphore = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var seconds = 0.0 }
    let box = Box()
    Task.detached {
        box.seconds = (try? await AVURLAsset(url: interrupted).load(.duration))?.seconds ?? 0
        semaphore.signal()
    }
    semaphore.wait()
    check(box.seconds > 1, "ese video se puede reproducir (\(String(format: "%.1f", box.seconds)) s)")
}
wait(1)
check(NSRunningApplication.runningApplications(withBundleIdentifier: "local.zas.app").isEmpty, "Zas termina de cerrarse tras guardar")

print("RESULTADO: \(passes) correctas, \(failures) fallidas")
exit(failures == 0 ? 0 : 1)

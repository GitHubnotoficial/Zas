// Usa Zas ya instalada como lo haría una persona: atajos reales, ratón real y portapapeles real.
// Se compila aparte y necesita el permiso de Accesibilidad para enviar eventos.
// Uso: ZasConductor <carpeta-de-imágenes>
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

func shot(_ name: String) {
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
    let limit = Date().addingTimeInterval(timeout)
    while Date() < limit {
        if let name = files(ext).subtracting(before).first {
            wait(0.3)
            return folder.appendingPathComponent(name)
        }
        wait(0.1)
    }
    return nil
}

func pixelSize(_ url: URL?) -> (Int, Int)? {
    guard let url, let rep = (try? Data(contentsOf: url)).flatMap({ NSBitmapImageRep(data: $0) }) else {
        return nil
    }
    return (rep.pixelsWide, rep.pixelsHigh)
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
if let size = pixelSize(region) {
    check(size == (300 * scale, 250 * scale), "el área mide lo arrastrado (\(size))")
}
wait(0.6)
let types = NSPasteboard.general.types ?? []
check(types.contains(.png), "la captura queda en el portapapeles")
check(NSPasteboard.general.data(forType: .png)?.count ?? 0 > 1000, "el portapapeles tiene la imagen")
shot("e2e-02-miniatura")

// 2. Miniatura: pasar el cursor y abrir el editor.
let visible = screen.visibleFrame
let thumbnailPoint = CGPoint(x: visible.maxX - 16 - 112, y: screen.frame.height - visible.minY - 16 - 40)
moveMouse(to: thumbnailPoint)
wait(0.5)
shot("e2e-03-miniatura-hover")
click(at: CGPoint(x: thumbnailPoint.x - 70, y: thumbnailPoint.y + 30))
wait(1.2)
check(zasWindowCount(minimumWidth: 700) >= 1, "clic en la miniatura abre el editor")
shot("e2e-04-editor")

// 3. Editor: dibujar con el ratón, deshacer, rehacer y copiar con Enter.
let editorFrame = windowFrame(owner: "Zas")
if let editorFrame {
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

    let beforeCopy = NSPasteboard.general.changeCount
    let annotated = newFile("png") {
        press(kVK_Return)
    }
    check(annotated?.lastPathComponent.contains("anotada") == true, "Enter guarda la versión anotada")
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
        check(size == (Int(calculator.width) * scale, Int(calculator.height) * scale), "la captura mide la ventana (\(size))")
    }
}

// 6. Pantalla completa.
let full = newFile("png") {
    hotKey(kVK_ANSI_1)
}
if let size = pixelSize(full) {
    check(size == (Int(screen.frame.width) * scale, Int(screen.frame.height) * scale), "⇧⌘1 captura toda la pantalla (\(size))")
} else {
    check(false, "⇧⌘1 captura toda la pantalla")
}
wait(0.6)
shot("e2e-09-pila")

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
check((NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.pathExtension == "mp4", "el video queda copiado como archivo")
shot("e2e-11-video-listo")

print("RESULTADO: \(passes) correctas, \(failures) fallidas")
exit(failures == 0 ? 0 : 1)

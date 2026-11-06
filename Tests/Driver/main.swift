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
    // screencapture escribe primero en un archivo oculto y luego lo renombra.
    return Set(names.filter { $0.hasSuffix(".\(ext)") && !$0.hasPrefix(".") })
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

/// Marcos de las tarjetas. Flotan, y miden como mucho 224 × 168.
func cardFrames() -> [CGRect] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    return (list ?? []).compactMap { info -> CGRect? in
        guard (info[kCGWindowOwnerName as String] as? String) == "Zas",
              (info[kCGWindowLayer as String] as? Int) == NSWindow.Level.floating.rawValue,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              rect.width <= 224, rect.height >= 84, rect.height <= 168
        else { return nil }
        return rect
    }
}

/// La más reciente es la de más abajo en la pantalla.
func newestCard() -> CGRect? {
    cardFrames().max { $0.maxY < $1.maxY }
}

/// Un sitio de la tarjeta donde no hay botones: las píldoras y los círculos dejan libre el borde del centro.
func freeSpot(in card: CGRect) -> CGPoint { CGPoint(x: card.minX + 16, y: card.midY) }
/// Centros exactos: píldoras de 22 con 6 entre ellas, círculos de 20 a 6 del borde.
func copyButton(in card: CGRect) -> CGPoint { CGPoint(x: card.midX, y: card.midY - 14) }
func saveButton(in card: CGRect) -> CGPoint { CGPoint(x: card.midX, y: card.midY + 14) }
func closeButton(in card: CGRect) -> CGPoint { CGPoint(x: card.minX + 16, y: card.minY + 16) }
func pinButton(in card: CGRect) -> CGPoint { CGPoint(x: card.maxX - 16, y: card.minY + 16) }
func annotateButton(in card: CGRect) -> CGPoint { CGPoint(x: card.minX + 16, y: card.maxY - 16) }
func pathButton(in card: CGRect) -> CGPoint { CGPoint(x: card.maxX - 16, y: card.maxY - 16) }

/// Una captura fijada de la región de 300 × 250.
func pinnedFrame() -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    for info in list ?? [] where (info[kCGWindowOwnerName as String] as? String) == "Zas" {
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              abs(rect.width - 300) < 2, abs(rect.height - 250) < 2
        else { continue }
        return rect
    }
    return nil
}

/// El panel de guardar del sistema. Según la versión de macOS lo dibuja la app o un servicio aparte.
func savePanelVisible() -> Bool { savePanelFrame() != nil }

func savePanelFrame() -> CGRect? {
    let owners: Set<String> = ["Zas", "Open and Save Panel Service"]
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    for info in list ?? [] {
        guard let owner = info[kCGWindowOwnerName as String] as? String, owners.contains(owner),
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              rect.width >= 400, rect.height >= 120, rect.height < 900
        else { continue }
        return rect
    }
    return nil
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

/// Mueve la primera ventana de una app con el permiso de Accesibilidad.
func moveWindow(of app: NSRunningApplication?, to point: CGPoint) {
    guard let app else { return }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
          let window = (value as? [AXUIElement])?.first
    else { return }
    var position = point
    if let axPosition = AXValueCreate(.cgPoint, &position) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axPosition)
    }
}

// Una app ajena con ventana, para probar la captura de ventana.
NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
wait(3)
// Las tarjetas viven abajo a la izquierda: la ventana ajena no debe quedar debajo.
if let frame = windowFrame(owner: "Calculator"), frame.minX < screen.visibleFrame.minX + 262 {
    moveWindow(
        of: NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").first,
        to: CGPoint(x: screen.frame.maxX - frame.width - 80, y: 120)
    )
    wait(0.5)
}
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

// 2. Tarjeta: abajo a la izquierda. Pasar el cursor, usar sus botones y abrir el editor.
let visible = screen.visibleFrame
let cardBottom = screen.frame.height - visible.minY - 18
let foundCard = newestCard()
check(foundCard != nil, "la tarjeta aparece tras capturar")
let firstCard = foundCard ?? CGRect(x: visible.minX + 18, y: cardBottom - 168, width: 202, height: 168)
// El Dock encoge al abrir apps y este proceso no recibe ese cambio: la altura se comprueba con margen.
check(abs(firstCard.minX - visible.minX - 18) < 2 && abs(firstCard.maxY - cardBottom) < 24, "la tarjeta queda abajo a la izquierda (\(firstCard))")
let thumbnailPoint = freeSpot(in: firstCard)
moveMouse(to: thumbnailPoint)
wait(0.5)
shot("e2e-03-miniatura-hover")

NSPasteboard.general.clearContents()
click(at: copyButton(in: firstCard))
wait(0.5)
check(NSPasteboard.general.data(forType: .png)?.count ?? 0 > 1000, "el botón Copiar deja la imagen en el portapapeles")
shot("e2e-03a-tarjeta-copiada")

click(at: pathButton(in: firstCard))
wait(0.5)
check(region != nil && NSPasteboard.general.string(forType: .string) == region?.path, "el botón de terminal copia la ruta")

click(at: saveButton(in: firstCard))
wait(1.2)
shot("e2e-03b-guardar-como")
check(savePanelVisible(), "el botón Guardar abre el panel de guardar")
// El aviso de macOS puede salir aquí y se queda con el teclado: al aceptarlo, se vuelve al panel con un clic.
if systemPromptFrame() != nil {
    dismissSystemPrompt()
    wait(0.5)
    if let frame = savePanelFrame() {
        click(at: CGPoint(x: frame.midX, y: frame.minY + 12))
        wait(0.4)
    }
}
press(kVK_Escape)
wait(0.8)
check(!savePanelVisible(), "Esc cierra el panel de guardar")
check(newestCard() != nil, "tras cancelar el guardado la tarjeta sigue ahí")

moveMouse(to: thumbnailPoint)
wait(0.3)
click(at: thumbnailPoint)
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

// Cada ⇧⌘9 deja una tarjeta nueva abajo del todo para probar un botón más.
func withFreshCard(_ name: String, _ action: (CGRect) -> Void) {
    moveMouse(to: CGPoint(x: screen.frame.midX, y: 200))
    _ = newFile("png", timeout: 6) {
        hotKey(kVK_ANSI_9)
    }
    wait(1.2)
    guard let card = newestCard() else {
        check(false, "\(name): hay una tarjeta")
        return
    }
    moveMouse(to: freeSpot(in: card))
    wait(0.4)
    action(card)
}

withFreshCard("Fijar") { card in
    let before = cardFrames().count
    click(at: pinButton(in: card))
    wait(0.8)
    check(cardFrames().count < before, "Fijar quita la tarjeta")
    guard let pinned = pinnedFrame() else {
        check(false, "Fijar deja la captura en pantalla")
        return
    }
    check(true, "Fijar deja la captura en pantalla")
    moveMouse(to: CGPoint(x: pinned.midX, y: pinned.midY))
    wait(0.4)
    shot("e2e-07b-fijada")
    click(at: CGPoint(x: pinned.minX + 16, y: pinned.minY + 16))
    wait(0.5)
    check(pinnedFrame() == nil, "la captura fijada se cierra con su ×")
}

withFreshCard("Anotar") { card in
    click(at: annotateButton(in: card))
    wait(1.2)
    check(zasWindowCount(minimumWidth: 700) >= 1, "el botón Anotar abre el editor")
    shot("e2e-07c-anotar")
    if let editor = windowFrame(owner: "Zas") {
        click(at: CGPoint(x: editor.midX, y: editor.maxY - 8))
        wait(0.2)
    }
    press(kVK_Escape)
    wait(0.8)
    check(zasWindowCount(minimumWidth: 700) == 0, "sin marcas, Esc cierra el editor")
}

withFreshCard("Cerrar") { card in
    let before = cardFrames().count
    click(at: closeButton(in: card))
    wait(0.8)
    check(cardFrames().count < before, "el botón Cerrar quita la tarjeta")
}

// Congelar: se esconde la Calculadora después de congelar, y debe seguir saliendo en la imagen.
if let calculator {
    let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").first
    moveMouse(to: CGPoint(x: 150, y: 120))
    let frozen = newFile("png", timeout: 6) {
        hotKey(kVK_ANSI_2)
        wait(0.6)
        press(kVK_ANSI_F)
        wait(1.2)
        app?.hide()
        wait(0.8)
        shot("e2e-03c-congelada")
        drag(
            from: CGPoint(x: calculator.minX + 10, y: calculator.minY + 60),
            to: CGPoint(x: calculator.maxX - 10, y: calculator.maxY - 10)
        )
    }
    app?.unhide()
    var bright = 0
    if let frozen, pixelSize(frozen) != nil,
       let rep = (try? Data(contentsOf: frozen)).flatMap({ NSBitmapImageRep(data: $0) }) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                if (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.2 {
                    bright += 1
                }
            }
        }
    }
    check(bright > 100, "congelar conserva lo que ya no está en pantalla (\(bright) puntos)")
    wait(0.8)
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

// Selección de texto sobre la imagen: la tarjeta de texto abre el editor con Live Text.
if !recognized.isEmpty {
    // La de texto es otra tarjeta, más baja: se busca su sitio libre de verdad.
    let textPoint = freeSpot(in: newestCard() ?? firstCard)
    moveMouse(to: textPoint)
    wait(0.4)
    click(at: textPoint)
    wait(3)
    shot("e2e-09c-texto-editor")
    if let editor = windowFrame(owner: "Zas") {
        let middle = editor.midY + 26
        // Las tarjetas que queden flotan sobre el editor: el arrastre empieza a su derecha.
        let start = max(editor.minX + 60, visible.minX + 18 + 224 + 20)
        drag(from: CGPoint(x: start, y: middle), to: CGPoint(x: editor.maxX - 60, y: middle))
        wait(0.5)
        shot("e2e-09d-texto-seleccionado")
        NSPasteboard.general.clearContents()
        press(kVK_ANSI_C, .maskCommand)
        wait(0.6)
        let selected = NSPasteboard.general.string(forType: .string) ?? ""
        print("texto seleccionado con el ratón: [\(selected.replacingOccurrences(of: "\n", with: " | "))]")
    }
    press(kVK_Escape)
    wait(0.4)
    press(kVK_Escape)
    wait(0.8)
    check(zasWindowCount(minimumWidth: 700) == 0, "el editor de texto se cierra con Esc")
}

// 8. Video con los atajos reales.
let video = newFile("mp4", timeout: 10) {
    hotKey(kVK_ANSI_6)
    wait(0.7)
    drag(from: CGPoint(x: 120, y: 120), to: CGPoint(x: 620, y: 420))
    wait(1.5)
    click(at: CGPoint(x: 300, y: 260))
    wait(0.15)
    shot("e2e-10-grabando")
    hotKey(kVK_ANSI_2)
    wait(0.5)
    shot("e2e-10b-aviso-grabando")
    // El panel de clics ocupa la pantalla: la selección sería una segunda ventana.
    check(zasWindowCount(minimumWidth: screen.frame.width - 1) <= 1, "capturar mientras graba avisa y no abre la selección")
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

import AppKit
import Carbon
import SwiftUI

/// Las acciones que se disparan con un atajo global.
enum HotKeyAction: String, CaseIterable, Codable {
    case region, fullScreen, timed, scroll, text, record, again

    var title: String {
        switch self {
        case .region: return "Capturar área o ventana"
        case .fullScreen: return "Capturar pantalla"
        case .timed: return "Capturar en 3 segundos"
        case .scroll: return "Capturar con desplazamiento"
        case .text: return "Copiar texto de la pantalla"
        case .record: return "Grabar video"
        case .again: return "Repetir captura"
        }
    }

    var symbol: String {
        switch self {
        case .region: return "viewfinder"
        case .fullScreen: return "display"
        case .timed: return "timer"
        case .scroll: return "arrow.up.and.down"
        case .text: return "text.viewfinder"
        case .record: return "record.circle"
        case .again: return "arrow.clockwise"
        }
    }

    var defaultShortcut: Shortcut {
        let modifiers = UInt32(cmdKey | shiftKey)
        switch self {
        case .region: return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: modifiers)
        case .fullScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers)
        case .timed: return Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: modifiers)
        case .scroll: return Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: modifiers)
        case .text: return Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: modifiers)
        case .record: return Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: modifiers)
        case .again: return Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: modifiers)
        }
    }
}

/// Combinación de teclas en el formato de Carbon, que es el que usan los atajos globales.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
        kVK_ANSI_9: "9", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
        kVK_F12: "F12", kVK_Space: "Espacio", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
    ]

    static func isSupported(keyCode: UInt16) -> Bool {
        keyNames[Int(keyCode)] != nil
    }

    var keyName: String {
        Shortcut.keyNames[Int(keyCode)] ?? "?"
    }

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    var menuKeyEquivalent: String {
        keyName.count == 1 ? keyName.lowercased() : ""
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}

/// Preferencias guardadas en UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Key {
        static let playSound = "playSound"
        static let thumbnailSeconds = "thumbnailSeconds"
        static let thumbnailsOnLeft = "thumbnailsOnLeft"
        static let recordMicrophone = "recordMicrophone"
        static let shortcuts = "shortcuts"
        static let saveFolder = "saveFolder"
        static let welcomed = "welcomed"
        static let saveCaptures = "saveCaptures"
        static let videoCopiesSummary = "videoCopiesSummary"
        static let videoEvery = "videoEvery"
        static let videoLimit = "videoLimit"
        static let systemAudio = "systemAudio"
        static let videoFPS = "videoFPS"
        static let videoCursor = "videoCursor"
        static let videoClicks = "videoClicks"
        static let videoKeys = "videoKeys"
        static let videoCamera = "videoCamera"
        static let loginItemConfigured = "loginItemConfigured"
    }

    private let defaults: UserDefaults

    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Key.playSound) }
    }

    @Published var thumbnailSeconds: Double {
        didSet { defaults.set(thumbnailSeconds, forKey: Key.thumbnailSeconds) }
    }

    /// Lado de la pantalla donde se apilan las tarjetas.
    @Published var thumbnailsOnLeft: Bool {
        didSet { defaults.set(thumbnailsOnLeft, forKey: Key.thumbnailsOnLeft) }
    }

    @Published var recordMicrophone: Bool {
        didSet { defaults.set(recordMicrophone, forKey: Key.recordMicrophone) }
    }

    /// Si es falso, las imágenes solo pasan por el portapapeles y un archivo temporal.
    @Published var saveCaptures: Bool {
        didSet { defaults.set(saveCaptures, forKey: Key.saveCaptures) }
    }

    /// Al terminar un video se copia una imagen con sus momentos clave, que Claude sí puede leer.
    @Published var videoCopiesSummary: Bool {
        didSet { defaults.set(videoCopiesSummary, forKey: Key.videoCopiesSummary) }
    }

    /// Cada cuántos segundos entra una imagen al resumen del video.
    @Published var videoEvery: Double {
        didSet { defaults.set(videoEvery, forKey: Key.videoEvery) }
    }

    /// Detiene la grabación sola a los segundos indicados. 0 es sin límite.
    @Published var videoLimit: Double {
        didSet { defaults.set(videoLimit, forKey: Key.videoLimit) }
    }

    @Published var systemAudio: Bool {
        didSet { defaults.set(systemAudio, forKey: Key.systemAudio) }
    }

    @Published var videoFPS: Int {
        didSet { defaults.set(videoFPS, forKey: Key.videoFPS) }
    }

    @Published var videoCursor: Bool {
        didSet { defaults.set(videoCursor, forKey: Key.videoCursor) }
    }

    @Published var videoClicks: Bool {
        didSet { defaults.set(videoClicks, forKey: Key.videoClicks) }
    }

    @Published var videoKeys: Bool {
        didSet { defaults.set(videoKeys, forKey: Key.videoKeys) }
    }

    @Published var videoCamera: Bool {
        didSet { defaults.set(videoCamera, forKey: Key.videoCamera) }
    }

    @Published var saveFolder: URL {
        didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) }
    }

    @Published var shortcuts: [HotKeyAction: Shortcut] {
        didSet {
            if let data = try? JSONEncoder().encode(shortcuts) {
                defaults.set(data, forKey: Key.shortcuts)
            }
        }
    }

    /// Sin guardar a propósito: se apaga al salir, y Zas siempre abre con los iconos visibles.
    @Published var hidesDesktopIcons = false

    /// Atajos que macOS no aceptó, porque otra app o acción ya los usa.
    @Published var conflicts: Set<HotKeyAction> = []

    var welcomed: Bool {
        get { defaults.bool(forKey: Key.welcomed) }
        set { defaults.set(newValue, forKey: Key.welcomed) }
    }

    /// El inicio de sesión se activa una sola vez: si luego se apaga, Zas no insiste.
    var loginItemConfigured: Bool {
        get { defaults.bool(forKey: Key.loginItemConfigured) }
        set { defaults.set(newValue, forKey: Key.loginItemConfigured) }
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zas", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.playSound: true, Key.thumbnailSeconds: 6.0, Key.thumbnailsOnLeft: true, Key.saveCaptures: true, Key.videoCopiesSummary: true, Key.videoEvery: 2.0, Key.videoFPS: 30, Key.videoCursor: true])

        playSound = defaults.bool(forKey: Key.playSound)
        thumbnailSeconds = defaults.double(forKey: Key.thumbnailSeconds)
        thumbnailsOnLeft = defaults.bool(forKey: Key.thumbnailsOnLeft)
        recordMicrophone = defaults.bool(forKey: Key.recordMicrophone)
        saveCaptures = defaults.bool(forKey: Key.saveCaptures)
        videoCopiesSummary = defaults.bool(forKey: Key.videoCopiesSummary)
        videoEvery = defaults.double(forKey: Key.videoEvery)
        videoLimit = defaults.double(forKey: Key.videoLimit)
        systemAudio = defaults.bool(forKey: Key.systemAudio)
        videoFPS = defaults.integer(forKey: Key.videoFPS)
        videoCursor = defaults.bool(forKey: Key.videoCursor)
        videoClicks = defaults.bool(forKey: Key.videoClicks)
        videoKeys = defaults.bool(forKey: Key.videoKeys)
        videoCamera = defaults.bool(forKey: Key.videoCamera)

        if let path = defaults.string(forKey: Key.saveFolder) {
            saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveFolder = Settings.defaultFolder
        }

        if let data = defaults.data(forKey: Key.shortcuts),
           let saved = try? JSONDecoder().decode([HotKeyAction: Shortcut].self, from: data) {
            shortcuts = saved
        } else {
            shortcuts = [:]
        }
    }

    func shortcut(for action: HotKeyAction) -> Shortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    func resetShortcuts() {
        shortcuts = [:]
    }
}

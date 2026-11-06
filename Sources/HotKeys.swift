import Carbon

/// Atajos globales con la API de Carbon. No necesita el permiso de Accesibilidad.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
    }

    /// Devuelve el identificador del atajo, o `nil` si otra app ya lo tiene ocupado.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x5A41_5321), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return nil
        }
        refs[id] = ref
        actions[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: id)
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }
}

private func hotKeyCallback(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    Task { @MainActor in
        HotKeys.shared.fire(id)
    }
    return noErr
}

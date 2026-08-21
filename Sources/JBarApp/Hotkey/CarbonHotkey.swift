import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut registered through Carbon's `RegisterEventHotKey`.
///
/// Why Carbon: it is the only system API that delivers a global hotkey to a background app
/// without Accessibility / Input Monitoring permission (DESIGN.md §5 row 1). One application-wide
/// Carbon event handler is installed lazily (once per process) and dispatches by hotkey id to the
/// owning `CarbonHotkey` instance, so several instances can coexist.
///
/// Must be used from the main thread (the Carbon handler runs on the main run loop).
@MainActor
final class CarbonHotkey {
    typealias Handler = @MainActor () -> Void

    /// Called on the main thread whenever the registered combination is pressed.
    var handler: Handler?
    /// Carbon modifier bits of the current registration (0 when unregistered).
    private(set) var modifiers: UInt32 = 0
    /// Virtual key code of the current registration.
    private(set) var keyCode: UInt32 = 0
    /// True while a registration is active.
    var isRegistered: Bool { ref != nil }

    /// The fallback used by the app when the configured combination cannot be registered: ⌃⌥Space.
    static let fallbackModifiers = UInt32(controlKey | optionKey)
    static let fallbackKeyCode = UInt32(kVK_Space)

    private var ref: EventHotKeyRef?
    private var id: UInt32 = 0

    init(handler: Handler? = nil) { self.handler = handler }

    deinit {
        // Instances are main-actor owned for their entire lifetime. Swift 6.1 does not yet enable
        // isolated deinitializers by default, so make that runtime invariant explicit here.
        MainActor.assumeIsolated { unregister() }
    }

    /// Register `modifiers` (Carbon bits: `cmdKey|optionKey|controlKey|shiftKey`) + `keyCode` (`kVK_*`).
    /// Any previous registration of this instance is released first. Returns the Carbon status;
    /// `noErr` on success. Typical failures: `eventHotKeyExistsErr` (-9878, another app owns it) or
    /// `eventHotKeyInvalidErr` (-9868, combination rejected by the system).
    @discardableResult
    func register(modifiers: UInt32, keyCode: UInt32) -> OSStatus {
        unregister()
        let installStatus = Self.installHandlerIfNeeded()
        guard installStatus == noErr else {
            Log.hotkey.error("InstallEventHandler failed: \(installStatus)")
            return installStatus
        }
        if id == 0 { id = Self.allocateId() }
        let hotKeyId = EventHotKeyID(signature: Self.signature, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyId, GetApplicationEventTarget(), 0, &newRef)
        if status == noErr, let r = newRef {
            ref = r
            self.modifiers = modifiers
            self.keyCode = keyCode
            Self.handlers[id] = { [weak self] in self?.handler?() }
            Log.hotkey.notice("registered hotkey mods=\(modifiers) key=\(keyCode) id=\(self.id)")
        } else {
            Log.hotkey.error("RegisterEventHotKey failed: status=\(status) mods=\(modifiers) key=\(keyCode)")
        }
        return status
    }

    /// Release the registration (no-op when not registered).
    func unregister() {
        guard let r = ref else { return }
        let status = UnregisterEventHotKey(r)
        if status != noErr { Log.hotkey.error("UnregisterEventHotKey failed: \(status)") }
        ref = nil
        modifiers = 0
        keyCode = 0
        Self.handlers[id] = nil
    }

    // MARK: - Process-wide handler

    private static let signature: OSType = 0x4A42_4152 // 'JBAR'
    private static var handlerInstalled = false
    private static var handlers: [UInt32: Handler] = [:]
    private static var nextId: UInt32 = 1

    private static func allocateId() -> UInt32 {
        defer { nextId &+= 1 }
        return nextId
    }

    private static func dispatch(id: UInt32) {
        guard let h = handlers[id] else {
            Log.hotkey.debug("hotkey event for unknown id \(id)")
            return
        }
        h()
    }

    private static func installHandlerIfNeeded() -> OSStatus {
        guard !handlerInstalled else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hotKeyId = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyId)
            guard err == noErr, hotKeyId.signature == CarbonHotkey.signature else { return OSStatus(eventNotHandledErr) }
            // Application-target Carbon events are delivered by the main event loop. Keep dispatch
            // synchronous so one key press cannot be reordered behind a later registration change.
            MainActor.assumeIsolated { CarbonHotkey.dispatch(id: hotKeyId.id) }
            return noErr
        }, 1, &spec, nil, nil)
        if status == noErr { handlerInstalled = true }
        return status
    }
}

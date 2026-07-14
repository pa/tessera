import AppKit
import Carbon.HIToolbox

/// Registers system-wide keyboard shortcuts via the Carbon Hot Key API
/// (`RegisterEventHotKey`), so Tessera's commands fire regardless of which app
/// is focused. This API needs no extra permission (unlike a `CGEventTap`) and
/// only surfaces the specific chords we register — it never sees other typing.
///
/// Tessera uses ⌃⌥⌘ (control-option-command) as its prefix rather than bare
/// ⌘D/⌘T: a global ⌘T would shadow "new tab" in every app. A dedicated
/// modifier is the standard approach for window managers.
@MainActor
final class HotKeyManager {
    /// Carbon modifier masks (from `Events.h`).
    struct Modifiers: OptionSet {
        let rawValue: UInt32
        static let command = Modifiers(rawValue: UInt32(cmdKey))
        static let shift = Modifiers(rawValue: UInt32(shiftKey))
        static let option = Modifiers(rawValue: UInt32(optionKey))
        static let control = Modifiers(rawValue: UInt32(controlKey))
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// A four-char signature identifying Tessera's hot keys ('TSSR').
    private let signature: OSType = 0x54535352

    /// Remove every registered hot key (keeps the installed event handler).
    /// Call before re-applying a changed binding set.
    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
        nextID = 1
    }

    /// Register `keyCode` + `modifiers` to run `action`. Key codes are Carbon
    /// virtual codes (`kVK_ANSI_*`).
    func register(keyCode: Int, modifiers: Modifiers, action: @escaping () -> Void) {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        actions[id] = action

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers.rawValue,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            NSLog("Tessera: failed to register hot key \(keyCode) (status \(status))")
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The handler must be a non-capturing C function; `self` is threaded
        // through the userData pointer.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard err == noErr else { return noErr }
            let id = hotKeyID.id
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Hot key events arrive on the main run loop already, but hop
            // explicitly to satisfy main-actor isolation.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { manager.dispatch(id: id) }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func dispatch(id: UInt32) {
        actions[id]?()
    }
}

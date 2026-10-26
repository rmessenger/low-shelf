import AppKit
import Carbon
import HotKeySupport

struct CheckFailure: Error { let message: String }

@main
struct HotKeyChecks {
    @MainActor
    static func sendHotKeyEvent(_ kind: UInt32) throws {
        var event: EventRef?
        let createStatus = CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event)
        guard createStatus == noErr, let event else { throw CheckFailure(message: "Could not create test event") }
        defer { ReleaseEvent(event) }
        var identifier = EventHotKeyID(signature: 0x4C534846, id: 1)
        let parameterStatus = SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier)
        guard parameterStatus == noErr else { throw CheckFailure(message: "Could not set test event identifier") }
        let status = SendEventToEventTarget(event, GetEventDispatcherTarget())
        guard status == noErr else { throw CheckFailure(message: "Hotkey event was not handled: \(status)") }
    }

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let modifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        let code = UInt32(kVK_F19)
        var first: GlobalHotKey? = try GlobalHotKey(keyCode: code, modifiers: modifiers) {}
        guard first != nil else { throw CheckFailure(message: "Registration failed") }
        do {
            _ = try GlobalHotKey(keyCode: code, modifiers: modifiers) {}
            throw CheckFailure(message: "Duplicate registration should fail")
        } catch is HotKeyFailure {
            print("PASS  Exclusive registration detects conflicts")
        }
        first = nil
        var presses = 0
        let second = try GlobalHotKey(keyCode: code, modifiers: modifiers) { presses += 1 }
        try withExtendedLifetime(second) {
            print("PASS  Shortcut is released and can be registered again")
            try sendHotKeyEvent(UInt32(kEventHotKeyPressed))
            try sendHotKeyEvent(UInt32(kEventHotKeyPressed))
            guard presses == 1 else { throw CheckFailure(message: "Held key must toggle only once") }
            try sendHotKeyEvent(UInt32(kEventHotKeyReleased))
            try sendHotKeyEvent(UInt32(kEventHotKeyPressed))
            guard presses == 2 else { throw CheckFailure(message: "Next key press must toggle again") }
            try sendHotKeyEvent(UInt32(kEventHotKeyReleased))
            print("PASS  Hotkey events toggle once per press")
        }
        for (name, flags) in [("Control–Option–B", UInt32(controlKey | optionKey)),
                              ("Control–Option–Command–B", UInt32(controlKey | optionKey | cmdKey))] {
            let reserved = try GlobalHotKey.isSystemShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: flags)
            print("\(name): configured system shortcut = \(reserved)")
        }
    }
}

import Carbon
import Foundation

public struct HotKeyFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

@MainActor
public final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var keyIsDown = false
    private let action: () -> Void
    private static let identifier = EventHotKeyID(signature: 0x4C534846, id: 1)

    public static func isSystemShortcut(keyCode: UInt32, modifiers: UInt32) throws(HotKeyFailure) -> Bool {
        var shortcuts: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&shortcuts)
        guard status == noErr, let shortcuts else {
            throw HotKeyFailure(message: "Could not check macOS keyboard shortcuts (\(status)).")
        }
        let entries = shortcuts.takeRetainedValue() as NSArray
        return entries.compactMap { $0 as? NSDictionary }.contains { entry in
            (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true
                && (entry[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value == keyCode
                && (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value == modifiers
        }
    }

    public init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) throws(HotKeyFailure) {
        self.action = action
        guard try !Self.isSystemShortcut(keyCode: keyCode, modifiers: modifiers) else {
            throw HotKeyFailure(message: "This shortcut is assigned in macOS Keyboard settings. The on-screen EQ control still works.")
        }
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let installStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                return shortcut.handle(event)
            }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installStatus == noErr else {
            throw HotKeyFailure(message: "Could not install the keyboard shortcut (\(installStatus)).")
        }
        let status = RegisterEventHotKey(keyCode, modifiers, Self.identifier, GetEventDispatcherTarget(),
                                        OptionBits(kEventHotKeyExclusive), &hotKey)
        guard status == noErr else {
            throw HotKeyFailure(message: "The global shortcut is unavailable (\(status)); another app may already use it. The on-screen EQ control still works.")
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr,
              identifier.signature == Self.identifier.signature,
              identifier.id == Self.identifier.id else { return OSStatus(eventNotHandledErr) }
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            guard !keyIsDown else { return noErr }
            keyIsDown = true
            action()
        case UInt32(kEventHotKeyReleased):
            keyIsDown = false
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

import CoreAudio
import IOKit.audio

public struct OutputRoute: Equatable {
    public let id: AudioObjectID
    public let sampleRate: Double
    public let isHeadphones: Bool

    public init(id: AudioObjectID, sampleRate: Double, isHeadphones: Bool) {
        self.id = id
        self.sampleRate = sampleRate
        self.isHeadphones = isHeadphones
    }
}

public enum HeadphoneAction: Equatable {
    case none, start, stop, restart
}

public enum HeadphoneAutomation {
    public static func action(enabled: Bool, previous: OutputRoute?, current: OutputRoute,
                              running: Bool) -> HeadphoneAction {
        guard previous != current else { return .none }
        guard enabled else { return running ? .restart : .none }
        guard current.isHeadphones else { return running ? .stop : .none }
        return running ? .restart : .start
    }

    public static func isHeadphoneTerminal(_ terminal: UInt32) -> Bool {
        // Drivers may expose Core Audio, IOKit, or USB Audio terminal identifiers.
        terminal == kAudioStreamTerminalTypeHeadphones ||
            terminal == kIOAudioOutputPortSubTypeHeadphones || terminal == 0x0302 || terminal == 0x0402
    }
}

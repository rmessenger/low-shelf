import AutomationSupport
import CoreAudio
import IOKit.audio

struct CheckFailure: Error { let message: String }

func expect(_ actual: HeadphoneAction, _ expected: HeadphoneAction, _ message: String) throws {
    guard actual == expected else { throw CheckFailure(message: message) }
    print("PASS  \(message)")
}

let speakers = OutputRoute(id: 1, sampleRate: 48000, isHeadphones: false)
let headphones = OutputRoute(id: 2, sampleRate: 48000, isHeadphones: true)
let otherHeadphones = OutputRoute(id: 3, sampleRate: 48000, isHeadphones: true)
let changedRate = OutputRoute(id: 2, sampleRate: 44100, isHeadphones: true)
let sharedJack = OutputRoute(id: 1, sampleRate: 48000, isHeadphones: true)

try expect(HeadphoneAutomation.action(enabled: false, previous: speakers, current: headphones, running: false),
           .none, "Disabled preference never starts processing")
try expect(HeadphoneAutomation.action(enabled: false, previous: headphones, current: speakers, running: true),
           .restart, "Unplugging headphones preserves manually enabled processing")
try expect(HeadphoneAutomation.action(enabled: false, previous: speakers, current: headphones, running: true),
           .restart, "Plugging in headphones preserves manually enabled processing")
try expect(HeadphoneAutomation.action(enabled: false, previous: headphones, current: speakers, running: false),
           .none, "Unplugging headphones preserves manually disabled processing")
try expect(HeadphoneAutomation.action(enabled: false, previous: headphones, current: headphones, running: true),
           .none, "Manual mode does not restart an unchanged output")
try expect(HeadphoneAutomation.action(enabled: false, previous: headphones, current: changedRate, running: true),
           .restart, "Manual mode reconnects after sample-rate changes")
try expect(HeadphoneAutomation.action(enabled: false, previous: sharedJack, current: speakers, running: true),
           .restart, "Manual mode preserves processing when a shared jack changes")
try expect(HeadphoneAutomation.action(enabled: true, previous: nil, current: speakers, running: false),
           .none, "Launch on speakers stays disabled")
try expect(HeadphoneAutomation.action(enabled: true, previous: nil, current: headphones, running: false),
           .start, "Launch or opt-in with headphones enables processing")
try expect(HeadphoneAutomation.action(enabled: true, previous: speakers, current: headphones, running: false),
           .start, "Connecting headphones starts processing")
try expect(HeadphoneAutomation.action(enabled: true, previous: headphones, current: headphones, running: false),
           .none, "Manual disable remains off until the output changes")
try expect(HeadphoneAutomation.action(enabled: true, previous: headphones, current: headphones, running: true),
           .none, "An unchanged headphone route is not restarted")
try expect(HeadphoneAutomation.action(enabled: true, previous: headphones, current: speakers, running: true),
           .stop, "Unplugging headphones stops processing on speakers")
try expect(HeadphoneAutomation.action(enabled: true, previous: headphones, current: speakers, running: false),
           .none, "Unplugging after a fault never starts speaker processing")
try expect(HeadphoneAutomation.action(enabled: true, previous: headphones, current: otherHeadphones, running: true),
           .restart, "Switching headphones rebuilds the audio route")
try expect(HeadphoneAutomation.action(enabled: true, previous: headphones, current: changedRate, running: true),
           .restart, "A sample-rate change rebuilds the audio route")
try expect(HeadphoneAutomation.action(enabled: true, previous: speakers, current: sharedJack, running: false),
           .start, "A shared device ID still detects headphone insertion")
try expect(HeadphoneAutomation.action(enabled: true, previous: sharedJack, current: speakers, running: true),
           .stop, "A shared device ID still detects headphone removal")
try expect(HeadphoneAutomation.action(enabled: true, previous: headphones, current: headphones, running: false),
           .none, "A failed start is not retried on every poll")

let rejectedTerminals: [UInt32] = [kAudioStreamTerminalTypeSpeaker, kAudioStreamTerminalTypeUnknown,
                         kAudioStreamTerminalTypeHDMI, kAudioStreamTerminalTypeLine,
                         kAudioStreamTerminalTypeDisplayPort, kAudioStreamTerminalTypeHeadsetMicrophone,
                         UInt32(kIOAudioOutputPortSubTypeInternalSpeaker), UInt32(kIOAudioOutputPortSubTypeExternalSpeaker),
                         0x0301, 0x0304, 0x0403]
let headphoneTerminals: [UInt32] = [kAudioStreamTerminalTypeHeadphones, UInt32(kIOAudioOutputPortSubTypeHeadphones), 0x0302, 0x0402]
guard headphoneTerminals.allSatisfy(HeadphoneAutomation.isHeadphoneTerminal),
      rejectedTerminals.allSatisfy({ !HeadphoneAutomation.isHeadphoneTerminal($0) }) else {
    throw CheckFailure(message: "Only headphone output terminals should trigger automation")
}
print("PASS  Speakers, displays, unknown devices, and microphones are not classified as headphones")

import BassDSP
import CoreAudio
import Foundation
import TuningCore

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw AudioFailure(message: "\(operation) failed (Core Audio \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording.")
    }
}

struct OutputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let rate: Double
}

@available(macOS 14.2, *)
final class AudioEngine {
    private(set) var output: OutputDevice?
    private(set) var dsp: OpaquePointer?
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private(set) var running = false

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var property = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try checkAudio(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "Read audio device")
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString>.size)
        try checkAudio(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "Read device name")
        guard let value else { throw AudioFailure(message: "Missing audio device name.") }
        return value.takeRetainedValue() as String
    }

    static func defaultOutput() throws -> OutputDevice {
        let id = try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                            initial: AudioObjectID(0))
        guard id != 0 else { throw AudioFailure(message: "No audio output is available.") }
        return try OutputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID),
                                name: string(id, kAudioObjectPropertyName),
                                rate: scalar(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)))
    }

    static func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        var property = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Read audio streams")
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !result.isEmpty else { return [] }
        try result.withUnsafeMutableBytes { bytes in
            try checkAudio(AudioObjectGetPropertyData(device, &property, 0, nil, &size, bytes.baseAddress!), "Read audio streams")
        }
        return result
    }

    static func format(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription {
        try scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
    }

    static func validate(_ format: AudioStreamBasicDescription, rate: Double) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0,
              format.mBytesPerFrame == 4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame),
              abs(format.mSampleRate - rate) < 1 else {
            throw AudioFailure(message: "This output format is unsupported. Select a stereo output in Audio MIDI Setup.")
        }
    }

    func start(boost: Double, frequency: Double, steepness: Double, trim: Double, curve: StereoEQCurve? = nil, gain: StereoGain? = nil) throws {
        guard !running else { return }
        do {
            let device = try Self.defaultOutput()
            let outputStreams = try Self.streams(device.id, scope: kAudioObjectPropertyScopeOutput)
            let formats = try outputStreams.map { try Self.format($0) }
            guard formats.reduce(0, { $0 + $1.mChannelsPerFrame }) == 2 else {
                throw AudioFailure(message: "LowShelf currently supports stereo outputs. Choose a stereo device in Sound settings.")
            }
            for format in formats { try Self.validate(format, rate: device.rate) }
            var pid = getpid()
            var process: AudioObjectID = 0
            var property = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try checkAudio(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "Identify LowShelf audio")
            guard process != 0 else { throw AudioFailure(message: "Could not exclude LowShelf from capture.") }
            let description = CATapDescription(excludingProcesses: [process], deviceUID: device.uid, stream: 0)
            description.name = "LowShelf System Audio"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try checkAudio(AudioHardwareCreateProcessTap(description, &tap), "Create system audio tap")
            let tapFormat = try Self.scalar(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard tapFormat.mChannelsPerFrame == 2 else {
                throw AudioFailure(message: "The selected output does not expose a stereo audio stream.")
            }
            try Self.validate(tapFormat, rate: device.rate)
            let tapUID = try Self.string(tap, kAudioTapPropertyUID)
            let specification = NSMutableDictionary()
            specification[kAudioAggregateDeviceNameKey] = "LowShelf Playback"
            specification[kAudioAggregateDeviceUIDKey] = "app.lowshelf.playback.\(UUID().uuidString)"
            specification[kAudioAggregateDeviceIsPrivateKey] = true
            specification[kAudioAggregateDeviceMainSubDeviceKey] = device.uid
            specification[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: device.uid]]
            let subTap = NSMutableDictionary()
            subTap[kAudioSubTapUIDKey] = tapUID
            subTap[kAudioSubTapDriftCompensationKey] = true
            subTap[kAudioSubTapDriftCompensationQualityKey] = kAudioAggregateDriftCompensationMaxQuality
            specification[kAudioAggregateDeviceTapListKey] = [subTap]
            specification[kAudioAggregateDeviceTapAutoStartKey] = false
            try checkAudio(AudioHardwareCreateAggregateDevice(specification, &aggregate), "Create playback route")
            let inputStreams = try Self.streams(aggregate, scope: kAudioObjectPropertyScopeInput)
            guard let lastInput = inputStreams.last else { throw AudioFailure(message: "The audio tap has no input stream.") }
            let finalInputFormat = try Self.format(lastInput)
            try Self.validate(finalInputFormat, rate: device.rate)
            guard finalInputFormat.mChannelsPerFrame == 2 else { throw AudioFailure(message: "Unexpected tap channel layout.") }
            for stream in try Self.streams(aggregate, scope: kAudioObjectPropertyScopeOutput) {
                try Self.validate(Self.format(stream), rate: device.rate)
            }
            guard let processor = bass_create(device.rate, boost, frequency, steepness, trim) else {
                throw AudioFailure(message: "Could not initialize the audio filter.")
            }
            dsp = processor
            bass_configure(processor, boost, frequency, steepness, trim)
            apply(curve: curve, gain: gain, rate: device.rate)
            try checkAudio(bass_attach(aggregate, processor, &ioProc), "Create audio callback")
            try checkAudio(bass_select_tap_input(aggregate, ioProc, UInt32(inputStreams.count)), "Select system audio input")
            try checkAudio(AudioDeviceStart(aggregate, ioProc), "Start audio")
            output = device
            running = true
        } catch {
            let cleanup = stop()
            if let cleanup { throw AudioFailure(message: "\(error.localizedDescription) Cleanup: \(cleanup)") }
            throw error
        }
    }

    func apply(curve: StereoEQCurve?, gain: StereoGain? = nil, rate: Double? = nil) {
        guard let dsp else { return }
        guard let curve else { bass_equalizer(dsp, nil, 0, false); return }
        let sampleRate = rate ?? output?.rate ?? 48000
        let left = curve.left.gains.indices.flatMap { curve.left.coefficients(index: $0, gain: curve.left.gains[$0], rate: sampleRate) }
        let right = curve.right.gains.indices.flatMap { curve.right.coefficients(index: $0, gain: curve.right.gains[$0], rate: sampleRate) }
        let attenuation = gain ?? curve.playbackGain(rate: sampleRate)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                bass_equalizer_stereo(dsp, l.baseAddress, r.baseAddress, attenuation.left, attenuation.right, true)
            }
        }
    }

    @discardableResult
    func stop() -> String? {
        var errors: [String] = []
        if let ioProc {
            let stopped = AudioDeviceStop(aggregate, ioProc)
            if stopped != noErr { errors.append("Stop: \(stopped)") }
            let destroyed = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            if destroyed != noErr { errors.append("Callback: \(destroyed)") }
            // Keep callback storage alive if Core Audio could still invoke it.
            if destroyed == noErr {
                if let dsp { bass_destroy(dsp) }
                dsp = nil
            }
            self.ioProc = nil
        } else if let dsp {
            bass_destroy(dsp)
            self.dsp = nil
        }
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            if status != noErr { errors.append("Route: \(status)") }
            aggregate = 0
        }
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap)
            if status != noErr { errors.append("Tap: \(status)") }
            tap = 0
        }
        running = false
        output = nil
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }
}

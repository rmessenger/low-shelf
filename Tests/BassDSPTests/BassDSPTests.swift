import BassDSP
import CoreAudio
import Foundation

final class BassDSPTests {
    private func processor(rate: Double = 48000, boost: Double = 6, frequency: Double = 100, steepness: Double = 1, trim: Double = 0) throws -> OpaquePointer {
        try unwrap(bass_create(rate, boost, frequency, steepness, trim))
    }

    private func process(_ dsp: OpaquePointer, _ input: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                bass_process(dsp, source.baseAddress, destination.baseAddress, UInt32(input.count / 2))
            }
        }
        return output
    }

    private func tone(rate: Int = 48000, hz: Double, amplitude: Double = 0.5) -> [Float] {
        (0..<rate).flatMap { i -> [Float] in
            let sample = Float(amplitude * sin(2 * .pi * hz * Double(i) / Double(rate)))
            return [sample, sample]
        }
    }

    private func rms(_ values: [Float]) -> Double {
        sqrt(values.reduce(0) { $0 + Double($1) * Double($1) } / Double(values.count))
    }

    func testShelfEndpointsAndMidpointAcrossSampleRates() {
        for rate in [44100.0, 48000, 96000, 192000] {
            for boost in [0.0, 3, 6, 12, 24] {
                for steepness in [0.1, 0.5, 1.0] {
                    expectEqual(bass_response(rate, boost, 100, steepness, 0), boost, accuracy: 1e-6)
                    expectEqual(bass_response(rate, boost, 100, steepness, 100), boost / 2, accuracy: 1e-6)
                    expectEqual(bass_response(rate, boost, 100, steepness, rate / 2), 0, accuracy: 1e-6)
                }
            }
        }
    }

    func testShelfIsMonotonicWithoutResonantOvershoot() {
        for frequency in [20.0, 40, 100, 250, 500] {
            for steepness in [0.1, 0.5, 1.0] {
                var previous = 24.00001
                for step in 0...500 {
                    let hz = 20 * pow(1000, Double(step) / 500)
                    let db = bass_response(48000, 24, frequency, steepness, hz)
                    expectLessOrEqual(db, previous + 1e-7)
                    expectGreaterOrEqual(db, -1e-7)
                    previous = db
                }
            }
        }
    }

    func testSteepnessChangesTransitionWidth() {
        let gentleBelow = bass_response(48000, 12, 200, 0.1, 100)
        let steepBelow = bass_response(48000, 12, 200, 1, 100)
        let gentleAbove = bass_response(48000, 12, 200, 0.1, 400)
        let steepAbove = bass_response(48000, 12, 200, 1, 400)
        expectGreater(steepBelow - gentleBelow, 2)
        expectGreater(gentleAbove - steepAbove, 2)
    }

    func testSteepnessUpdatesChangeActualAudio() throws {
        for hz in [100.0, 200, 400] {
            let dsp = try processor(boost: 12, frequency: 200, steepness: 0.1)
            defer { bass_destroy(dsp) }
            let input = tone(hz: hz)
            for steepness in [0.1, 0.5, 1.0, 0.1] {
                bass_configure(dsp, 12, 200, steepness, 0, false)
                let output = process(dsp, input)
                let measured = 20 * log10(rms(Array(output.suffix(48000))) / rms(Array(input.suffix(48000))))
                expectEqual(measured, bass_response(48000, 12, 200, steepness, hz) - 13, accuracy: 0.001)
                expectTrue(output.allSatisfy { $0.isFinite && abs($0) < 1 })
            }
            expectEqual(bass_take_faults(dsp), 0)
        }
    }

    func testActualAudioHasExpectedBassAndTrebleGain() throws {
        for (boost, midpoint) in [(6.0, 100.0), (24, 20), (24, 500)] {
            for hz in [20.0, 100, 500, 1000, 10000] {
                let dsp = try processor(boost: boost, frequency: midpoint)
                defer { bass_destroy(dsp) }
                let input = tone(hz: hz)
                let output = process(dsp, input)
                let measured = 20 * log10(rms(Array(output.suffix(48000))) / rms(Array(input.suffix(48000))))
                expectEqual(measured, bass_response(48000, boost, midpoint, 1, hz) - boost - 1, accuracy: 0.001)
            }
        }
    }

    func testZeroBoostIsOnlyDocumentedHeadroomAttenuation() throws {
        let dsp = try processor(boost: 0)
        defer { bass_destroy(dsp) }
        let input = tone(hz: 1234)
        let output = process(dsp, input)
        let gain = Float(pow(10, -1.0 / 20))
        for (source, destination) in zip(input, output) {
            expectEqual(destination, source * gain, accuracy: 1e-7)
        }
    }

    func testBypassBecomesBitExactAfterRamp() throws {
        let dsp = try processor(boost: 12)
        defer { bass_destroy(dsp) }
        bass_configure(dsp, 12, 100, 1, -10, true)
        let input = tone(hz: 731)
        let output = process(dsp, input)
        expectEqual(Array(input.suffix(48000)), Array(output.suffix(48000)))
    }

    func testNoStereoCrosstalk() throws {
        let dsp = try processor()
        defer { bass_destroy(dsp) }
        var impulse = [Float](repeating: 0, count: 9600)
        impulse[0] = 0.5
        let output = process(dsp, impulse)
        expectGreater(abs(output[0]), 0)
        expectTrue(stride(from: 1, to: output.count, by: 2).allSatisfy { output[$0] == 0 })
    }

    func testTrimAndFullScaleBassHeadroom() throws {
        let dsp = try processor(boost: 12, trim: -3)
        defer { bass_destroy(dsp) }
        let input = tone(hz: 20, amplitude: 1)
        let output = process(dsp, input)
        expectLess(output.map(abs).max()!, 0.66)
        let measured = 20 * log10(rms(Array(output.suffix(48000))) / rms(Array(input.suffix(48000))))
        expectEqual(measured, bass_response(48000, 12, 100, 1, 20) - 16, accuracy: 0.001)
    }

    func testSilenceStaysSilentAndMeterResets() throws {
        let dsp = try processor()
        defer { bass_destroy(dsp) }
        expectTrue(process(dsp, [Float](repeating: 0, count: 2048)).allSatisfy { $0 == 0 })
        _ = process(dsp, tone(hz: 100))
        expectGreater(bass_take_peak(dsp), 0.1)
        expectEqual(bass_take_peak(dsp), 0)
    }

    func testRapidControlChangesStayFiniteAndBounded() throws {
        let dsp = try processor()
        defer { bass_destroy(dsp) }
        let input = Array(tone(hz: 100).prefix(512))
        for i in 0..<500 {
            bass_configure(dsp, Double(i % 25), Double(20 + i % 481), 0.1 + Double(i % 91) / 100, -Double(i % 19), i % 3 == 0)
            let output = process(dsp, input)
            expectTrue(output.allSatisfy { $0.isFinite && abs($0) < 1 })
        }
        expectEqual(bass_take_faults(dsp), 0)
    }

    func testInvalidSampleRatesAreRejected() {
        expectNil(bass_create(0, 6, 100, 1, 0))
        expectNil(bass_create(.nan, 6, 100, 1, 0))
    }

    func testRoutingWithHardwareInputAndPlanarStereoOutput() throws {
        let dsp = try processor(boost: 0)
        defer { bass_destroy(dsp) }
        let inputs = AudioBufferList.allocate(maximumBuffers: 2)
        let outputs = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(inputs.unsafeMutablePointer); free(outputs.unsafeMutablePointer) }
        var microphone: [Float] = [0.9, 0.9, 0.9, 0.9]
        var tap: [Float] = [0.1, -0.2, 0.2, -0.3, 0.3, -0.4, 0.4, -0.5]
        var left = [Float](repeating: 9, count: 4)
        var right = [Float](repeating: 9, count: 4)
        microphone.withUnsafeMutableBytes { micBytes in
            tap.withUnsafeMutableBytes { tapBytes in
                left.withUnsafeMutableBytes { leftBytes in
                    right.withUnsafeMutableBytes { rightBytes in
                        inputs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(micBytes.count), mData: micBytes.baseAddress)
                        inputs[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBytes.count), mData: tapBytes.baseAddress)
                        outputs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(leftBytes.count), mData: leftBytes.baseAddress)
                        outputs[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rightBytes.count), mData: rightBytes.baseAddress)
                        expectEqual(bass_io(0, nil, inputs.unsafePointer, nil, outputs.unsafeMutablePointer, nil, UnsafeMutableRawPointer(dsp)), 0)
                    }
                }
            }
        }
        let gain = Float(pow(10, -1.0 / 20))
        expectEqual(left[0], 0.1 * gain, accuracy: 1e-7)
        expectEqual(right[3], -0.5 * gain, accuracy: 1e-7)
        expectEqual(bass_callbacks(dsp), 1)
        expectEqual(bass_take_faults(dsp), 0)
    }
}

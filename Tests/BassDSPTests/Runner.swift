import Foundation

// A dependency-free test runner also works with Apple's Command Line Tools, without XCTest.
nonisolated(unsafe) private var failures: [String] = []
private func record(_ passed: Bool, _ message: String, file: StaticString, line: UInt) {
    guard !passed else { return }
    failures.append("\(file):\(line): \(message)")
}
func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    record(value, "Expected true", file: file, line: line)
}
func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    record(lhs == rhs, "Values differ", file: file, line: line)
}
func expectEqual<T: BinaryFloatingPoint>(_ lhs: T, _ rhs: T, accuracy: T, file: StaticString = #filePath, line: UInt = #line) {
    record(abs(lhs - rhs) <= accuracy, "\(lhs) != \(rhs) ± \(accuracy)", file: file, line: line)
}
func expectLess<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    record(lhs < rhs, "Expected \(lhs) < \(rhs)", file: file, line: line)
}
func expectGreater<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    record(lhs > rhs, "Expected \(lhs) > \(rhs)", file: file, line: line)
}
func expectLessOrEqual<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    record(lhs <= rhs, "Expected \(lhs) <= \(rhs)", file: file, line: line)
}
func expectGreaterOrEqual<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    record(lhs >= rhs, "Expected \(lhs) >= \(rhs)", file: file, line: line)
}
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    record(value == nil, "Expected nil", file: file, line: line)
}
struct CheckFailure: Error { let description: String }
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckFailure(description: "Unexpected nil") }
    return value
}

@main
struct Runner {
    static func main() throws {
        let suite = BassDSPTests()
        let tests: [(String, () throws -> Void)] = [
            ("Shelf endpoints and midpoint", suite.testShelfEndpointsAndMidpointAcrossSampleRates),
            ("Monotonic response", suite.testShelfIsMonotonicWithoutResonantOvershoot),
            ("Steepness transition width", suite.testSteepnessChangesTransitionWidth),
            ("Live steepness updates", suite.testSteepnessUpdatesChangeActualAudio),
            ("Measured audio gain", suite.testActualAudioHasExpectedBassAndTrebleGain),
            ("Zero boost transparency", suite.testZeroBoostIsOnlyDocumentedHeadroomAttenuation),
            ("Stereo separation", suite.testNoStereoCrosstalk),
            ("Trim and headroom", suite.testTrimAndFullScaleBassHeadroom),
            ("Silence and meter", suite.testSilenceStaysSilentAndMeterResets),
            ("Rapid control changes", suite.testRapidControlChangesStayFiniteAndBounded),
            ("Invalid sample rates", suite.testInvalidSampleRatesAreRejected),
            ("Hardware input exclusion and planar routing", suite.testRoutingWithHardwareInputAndPlanarStereoOutput)
        ]
        for (name, test) in tests {
            let before = failures.count
            do { try test() } catch { failures.append("\(name): \(error)") }
            print("\(failures.count == before ? "PASS" : "FAIL")  \(name)")
        }
        guard failures.isEmpty else {
            failures.prefix(30).forEach { print($0) }
            throw CheckFailure(description: "\(failures.count) assertions failed")
        }
        print("\(tests.count) tests passed.")
    }
}

import BassDSP
import Foundation
import TuningCore

struct Failure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }
}
func required<T>(_ value: T?) throws -> T {
    guard let value else { throw Failure(message: "Unexpected nil") }; return value
}
struct Listener {
    let noise: Double
    let lapse: Double
    let threshold: Double
    let strong: Double
    var random: SeededRandom
    mutating func vote(_ pair: StereoComparison, target: StereoEQCurve) -> PreferenceRating {
        let a = pow(pair.a.error(to: target), 2) + noise * random.normal()
        let b = pow(pair.b.error(to: target), 2) + noise * random.normal()
        let reversed = random.uniform() < lapse ? -1.0 : 1.0
        switch (b-a) * reversed {
        case let x where x > strong: return .strongA
        case let x where x > threshold: return .slightA
        case let x where x < -strong: return .strongB
        case let x where x < -threshold: return .slightB
        default: return .indistinguishable
        }
    }
}
struct Trial {
    let name: String
    let target: StereoEQCurve
}
let flat = EQCurve()
let warm = EQCurve([5,3,1,0,0,0,-1,-2,-2])
let dark = EQCurve([2,1,0,0,0,-1,-3,-5,-6])
let presence = EQCurve([-2,-1,0,0,1,3,4,0,-2])
let notch = EQCurve([0,0,0,0,0,0,-5,0,0])
let bass = EQCurve([10,6,2,0,0,-1,-2,-2,-3])
let alternating = EQCurve([3,-2,2,-3,2,-2,3,-2,1])
let trials = [
    Trial(name: "shared flat", target: StereoEQCurve()),
    Trial(name: "shared bass", target: StereoEQCurve(shared: bass)),
    Trial(name: "left warmth", target: StereoEQCurve(left: warm, right: flat)),
    Trial(name: "right notch", target: StereoEQCurve(left: flat, right: notch)),
    Trial(name: "opposite tilt", target: StereoEQCurve(left: dark, right: presence)),
    Trial(name: "different bass", target: StereoEQCurve(left: bass, right: warm)),
    Trial(name: "fine asymmetry", target: StereoEQCurve(left: alternating, right: notch)),
    Trial(name: "swapped tilt", target: StereoEQCurve(left: presence, right: dark))
]
let output = CommandLine.arguments.dropFirst().first ?? "/tmp/lowshelf-stereo-validation"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
var rows = ["scenario,target,seed,iteration,left_error_db,right_error_db,uncertainty_db"]
var report = ["Stereo EQ / five-choice validation", "Independent noisy squared-response-distance oracle; each ear checked separately."]
var summaries = [String: [Double]]()
let started = Date()
for (scenario, noise, lapse, threshold, strong, budget, limit) in [
    ("ordinary", 0.9, 0.04, 1.0, 4.0, 400, 0.65),
    ("unreliable", 1.8, 0.10, 1.6, 6.0, 600, 1.0)
] {
    for trial in trials {
        var errors = [Double]()
        for seed in 1...6 {
            var search = StereoPreferenceSearch(seed: UInt64(seed))
            var listener = Listener(noise: noise, lapse: lapse, threshold: threshold, strong: strong,
                                    random: SeededRandom(seed: UInt64(seed+1000)))
            for iteration in 1...budget {
                let pair = search.next()
                search.answer(listener.vote(pair, target: trial.target))
                rows.append("\(scenario),\(trial.name),\(seed),\(iteration),\(search.recommendation.left.error(to: trial.target.left)),\(search.recommendation.right.error(to: trial.target.right)),\(search.uncertainty)")
            }
            let left = search.recommendation.left.error(to: trial.target.left)
            let right = search.recommendation.right.error(to: trial.target.right)
            let error = max(left, right)
            try check(error < limit, "\(scenario)/\(trial.name)/\(seed): L \(left), R \(right) exceeds \(limit) dB")
            try check(search.uncertainty.isFinite, "Nonfinite uncertainty")
            errors.append(error)
            var library = ProfileLibrary(); library.add(name: "Validation")
            library.profiles[0].session = search
            try library.validate()
        }
        summaries[scenario, default: []].append(contentsOf: errors)
        let line = String(format: "%@ / %@: mean %.3f, worst %.3f dB per ear at %d votes", scenario, trial.name, errors.reduce(0,+)/Double(errors.count), errors.max()!, budget)
        print(line); report.append(line)
    }
}
for seed in 101...112 {
    var rng = SeededRandom(seed: UInt64(seed))
    let target = StereoEQCurve((0..<StereoEQCurve.count).map { _ in 8*rng.uniform()-4 })
    var search = StereoPreferenceSearch(seed: UInt64(seed))
    var listener = Listener(noise: 0.9, lapse: 0.04, threshold: 0.5, strong: 3,
                            random: SeededRandom(seed: UInt64(seed+1000)))
    for _ in 0..<400 { let pair = search.next(); search.answer(listener.vote(pair, target: target)) }
    try check(search.recommendation.left.error(to: target.left) < 0.65, "Holdout left \(seed)")
    try check(search.recommendation.right.error(to: target.right) < 0.65, "Holdout right \(seed)")
}
print("PASS  Twelve unseen stereo targets, with different rating thresholds")
var early = [Double](), late = [Double]()
for trial in [trials[3], trials[4], trials[6]] {
    for seed in 21...22 {
        var search = StereoPreferenceSearch(seed: UInt64(seed))
        var listener = Listener(noise: 0.9, lapse: 0.04, threshold: 1, strong: 4,
                                random: SeededRandom(seed: UInt64(seed+1000)))
        for _ in 0..<400 { let pair = search.next(); search.answer(listener.vote(pair, target: trial.target)) }
        early.append(search.recommendation.error(to: trial.target))
        for iteration in 401...2000 {
            let pair = search.next(); search.answer(listener.vote(pair, target: trial.target))
            rows.append("long,\(trial.name),\(seed),\(iteration),\(search.recommendation.left.error(to: trial.target.left)),\(search.recommendation.right.error(to: trial.target.right)),\(search.uncertainty)")
        }
        late.append(search.recommendation.error(to: trial.target))
        try check(search.recommendation.left.error(to: trial.target.left) < 0.2, "Long run left \(trial.name)/\(seed): \(search.recommendation.left.error(to: trial.target.left))")
        try check(search.recommendation.right.error(to: trial.target.right) < 0.2, "Long run right \(trial.name)/\(seed): \(search.recommendation.right.error(to: trial.target.right))")
    }
}
try check(late.reduce(0,+) < early.reduce(0,+)/2, "Long runs failed to improve")
report.append(String(format: "Long runs: mean %.3f dB at 400 → %.3f dB at 2000", early.reduce(0,+)/Double(early.count), late.reduce(0,+)/Double(late.count)))
print(report.last!)

var fresh = StereoPreferenceSearch(seed: 71)
let pair = fresh.next()
var strongA = fresh, slightA = fresh, strongB = fresh, slightB = fresh, tie = fresh
strongA.answer(.strongA); slightA.answer(.slightA); strongB.answer(.strongB); slightB.answer(.slightB); tie.answer(.indistinguishable)
try check(strongA.recommendation.error(to: pair.a) < slightA.recommendation.error(to: pair.a), "Strong A should move further toward A")
try check(strongB.recommendation.error(to: pair.b) < slightB.recommendation.error(to: pair.b), "Strong B should move further toward B")
try check(tie.uncertainty < fresh.uncertainty && tie.uncertainty > 0, "Indistinguishable must provide soft, nonzero-uncertainty evidence")
var history = StereoPreferenceSearch(seed: 914)
var listener = Listener(noise: 0.9, lapse: 0.04, threshold: 1, strong: 4, random: SeededRandom(seed: 701))
for _ in 0..<39 { let pair = history.next(); history.answer(listener.vote(pair, target: trials[4].target)) }
let before = history
let pending = history.next()
history.answer(.slightA); history.undo()
try check(history.mean == before.mean && history.covariance == before.covariance && history.current == pending, "Undo across refit must restore exact state")
let decoder = JSONDecoder(), encoder = JSONEncoder()
var resumed = try decoder.decode(StereoPreferenceSearch.self, from: encoder.encode(history))
try check(resumed.next() == history.next(), "Stereo resume must be deterministic")

struct LegacyProfile: Codable { let id: UUID; let name: String; let saved: EQCurve; let session: PreferenceSearch? }
struct LegacyLibrary: Codable { let version: Int; let profiles: [LegacyProfile]; let selected: UUID }
var old = PreferenceSearch(seed: 801)
for _ in 0..<30 { _ = old.next(); old.answer(.a, confidence: .tentative) }
let oldPair = old.next()
let id = UUID()
let fixture = LegacyLibrary(version: 1, profiles: [LegacyProfile(id: id, name: "Original IEM", saved: warm, session: old)], selected: id)
let originalData = try encoder.encode(fixture)
let directory = URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appendingPathComponent("profiles.json")
try originalData.write(to: url)
var library = try ProfileStorage.load(from: url)
try check(try Data(contentsOf: url) == originalData, "Loading must never rewrite the existing file")
try check(library.version == 2 && library.selected == id, "Profile identity and version migration")
let migrated = try required(library.profile?.session)
try check(library.profile?.saved == StereoEQCurve(shared: warm), "Saved legacy curve must remain identical in each ear")
try check(migrated.recommendation == StereoEQCurve(shared: old.recommendation), "Migration must preserve the learned recommendation")
try check(migrated.current?.a == StereoEQCurve(shared: oldPair.a) && migrated.current?.b == StereoEQCurve(shared: oldPair.b), "Migration must preserve pending A/B")
try check(migrated.completedComparisons == 30 && migrated.legacyHistory?.answers.count == 30, "Legacy history must be preserved")
try ProfileStorage.save(library, to: url)
let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("profiles-v1-") }
try check(backups.count == 1, "Migration must make one original-file backup")
try check(try Data(contentsOf: required(backups.first)) == originalData, "Migration backup must be byte-identical")
library = try ProfileStorage.load(from: url)
library.profiles[0].session?.answer(.slightB)
try ProfileStorage.save(library, to: url)
let reloaded = try ProfileStorage.load(from: url)
try check(reloaded.profile?.session?.answers.count == 1 && reloaded.profile?.session?.legacyHistory?.answers.count == 30, "Both old and new votes must persist")
try check(reloaded.profile?.saved == StereoEQCurve(shared: warm), "Voting must not overwrite saved EQ")
print("PASS  Five response categories, soft indifference, undo, resume, migration and original-file backup")

for seed in 81...84 {
    let offset = [0.0, 0, 0, 1, -2, 3, -2, 1, 0]
    let target = StereoEQCurve(left: EQCurve(zip(warm.gains, offset).map(+)), right: EQCurve(zip(warm.gains, offset).map(-)))
    var legacy = PreferenceSearch(seed: UInt64(seed))
    var rng = SeededRandom(seed: UInt64(seed+1000))
    for _ in 0..<200 {
        let pair = legacy.next()
        let a = pow(pair.a.error(to: warm), 2) + 0.9*rng.normal()
        let b = pow(pair.b.error(to: warm), 2) + 0.9*rng.normal()
        legacy.answer((a < b) != (rng.uniform() < 0.04) ? .a : .b)
    }
    var continued = StereoPreferenceSearch(migrating: legacy)
    var listener = Listener(noise: 0.9, lapse: 0.04, threshold: 1, strong: 4, random: rng)
    for _ in 0..<400 { let pair = continued.next(); continued.answer(listener.vote(pair, target: target)) }
    try check(continued.recommendation.left.error(to: target.left) < 0.65, "Migrated session must learn left differences")
    try check(continued.recommendation.right.error(to: target.right) < 0.65, "Migrated session must learn right differences")
}
print("PASS  Existing learned sessions continue refining independent ears")


func process(_ dsp: OpaquePointer, _ input: [Float]) -> [Float] {
    var output = [Float](repeating: 0, count: input.count)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { target in bass_process(dsp, source.baseAddress, target.baseAddress, UInt32(input.count/2)) }
    }
    return output
}
func apply(_ curve: StereoEQCurve, to dsp: OpaquePointer, rate: Double) {
    let left = curve.left.gains.indices.flatMap { curve.left.coefficients(index: $0, gain: curve.left.gains[$0], rate: rate) }
    let right = curve.right.gains.indices.flatMap { curve.right.coefficients(index: $0, gain: curve.right.gains[$0], rate: rate) }
    let gain = curve.playbackGain(rate: rate)
    left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in
        bass_equalizer_stereo(dsp, l.baseAddress, r.baseAddress, gain.left, gain.right, true)
    } }
}
func rms(_ samples: [Float]) -> Double { sqrt(samples.reduce(0) { $0+Double($1)*Double($1) } / Double(samples.count)) }
for rate in [44100.0, 48000, 96000, 192000] {
    let curve = trials[4].target
    let gain = curve.playbackGain(rate: rate)
    let dsp = try required(bass_create(rate, 0, 100, 1, 0)); defer { bass_destroy(dsp) }
    apply(curve, to: dsp, rate: rate)
    for hz in [25.0, 80, 315, 2500, 10000, 18000] {
        let count = Int(rate*2)
        let input = (0..<count).flatMap { i -> [Float] in
            let sample = Float(0.25*sin(2 * .pi*hz*Double(i)/rate)); return [sample, sample]
        }
        let output = process(dsp, input)
        for (channel, eq, attenuation) in [(0, curve.left, gain.left), (1, curve.right, gain.right)] {
            let actual = stride(from: count+channel, to: output.count, by: 2).map { output[$0] }
            let reference = stride(from: count+channel, to: input.count, by: 2).map { input[$0] }
            let measured = 20*log10(rms(actual)/rms(reference))
            let expected = eq.response(at: hz, rate: rate)+attenuation
            try check(abs(measured-expected) < 0.02, "Stereo DSP mismatch: channel \(channel) / \(rate) / \(hz)")
            try check(expected <= -5.99 && attenuation <= 0, "Stereo gain must preserve headroom without makeup gain")
        }
    }
    for silent in [0, 1] {
        let isolated = try required(bass_create(rate, 0, 100, 1, 0)); defer { bass_destroy(isolated) }
        apply(curve, to: isolated, rate: rate)
        let input = (0..<Int(rate)).flatMap { i -> [Float] in
            let sample = Float(0.25*sin(2 * .pi*80*Double(i)/rate))
            return silent == 0 ? [0, sample] : [sample, 0]
        }
        let output = process(isolated, input)
        try check(stride(from: silent, to: output.count, by: 2).allSatisfy { output[$0] == 0 }, "Ear filters must not leak into the other channel")
    }
    try check(bass_take_faults(dsp) == 0, "Stereo DSP fault")
}
let dsp = try required(bass_create(48000,0,100,1,0)); defer { bass_destroy(dsp) }
let signal = (0..<256).flatMap { i -> [Float] in
    [Float(0.25*sin(2 * .pi*80*Double(i)/48000)), Float(0.25*sin(2 * .pi*5000*Double(i)/48000))]
}
for index in 0..<500 {
    apply(trials[index % trials.count].target, to: dsp, rate: 48000)
    try check(process(dsp, signal).allSatisfy { $0.isFinite && abs($0) < 1 }, "Unstable stereo switching")
}
try check(bass_take_faults(dsp) == 0, "Stereo switching fault")
let candidates = trials.map(\.target)
let gains = candidates.map { $0.playbackGain(rate: 48000, alongside: candidates) }
var levels = [Double]()
for (curve, gain) in zip(candidates, gains) {
    for (eq, attenuation) in [(curve.left, gain.left), (curve.right, gain.right)] {
        let response: [Double] = EQCurve.grid.map { eq.response(at: $0) }
        levels.append(response.reduce(0,+)/Double(EQCurve.grid.count) + attenuation)
    }
}
try check(levels.max()! - levels.min()! < 1e-9, "Every candidate and ear must share a centered playback level")
print("PASS  Independent L/R filter responses at four rates, no crosstalk, headroom, level balancing, rapid switching")
for (scenario, errors) in summaries.sorted(by: { $0.key < $1.key }) {
    report.append(String(format: "%@: mean %.3f; worst %.3f dB per ear", scenario, errors.reduce(0,+)/Double(errors.count), errors.max()!))
}
report.append(String(format: "Completed in %.1f seconds", Date().timeIntervalSince(started)))
try rows.joined(separator: "\n").write(toFile: output+"/convergence.csv", atomically: true, encoding: .utf8)
try report.joined(separator: "\n").write(toFile: output+"/report.txt", atomically: true, encoding: .utf8)
print("PASS  All stereo checks. Results: \(output)")

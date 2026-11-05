import Foundation
import TuningCore

struct Failure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }
}
func loss(_ curve: StereoEQCurve, _ target: [Double]) -> Double {
    let values = curve.shape()
    return zip(values, target).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(values.count)
}
func optimum(_ pair: SliderComparison, target: [Double]) -> Double {
    // Search both halves independently because clipping can bend the line at Current.
    func half(_ start: Double, _ end: Double) -> Double {
        var lo = start, hi = end
        for _ in 0..<18 {
            let a = lo + (hi - lo) / 3, b = hi - (hi - lo) / 3
            let preferA = loss(pair.curve(at: a), target) < loss(pair.curve(at: b), target)
            hi = preferA ? b : hi; lo = preferA ? lo : a
        }
        return (lo + hi) / 2
    }
    let positions = [-1, half(-1, 0), 0, half(0, 1), 1]
    return positions.min { loss(pair.curve(at: $0), target) < loss(pair.curve(at: $1), target) }!
}
let targets = [
    StereoEQCurve(),
    StereoEQCurve(shared: EQCurve([5,3,1,0,0,0,-1,-2,-2])),
    StereoEQCurve(left: EQCurve([2,1,0,0,0,-1,-3,-5,-6]), right: EQCurve([-2,-1,0,0,1,3,4,0,-2])),
    StereoEQCurve(left: EQCurve([10,6,2,0,0,-1,-2,-2,-3]), right: EQCurve([0,0,0,0,0,0,-5,0,0])),
    StereoEQCurve(left: EQCurve([3,-2,2,-3,2,-2,3,-2,1]), right: EQCurve([-1,3,-2,2,-3,2,-2,3,-1]))
]
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/finetune-slider-validation")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var rows = ["scenario,target,seed,iteration,left_error_db,right_error_db,slider_position"]
var report = ["FineTune online slider validation", "Noisy line-preference oracle using actual nonlinear EQ response shapes."]
var results = [String: [Double]]()
@MainActor
func run(_ search: inout SliderSearch, target: StereoEQCurve, noise: Double, slips: Bool, count: Int,
         scenario: String, targetName: String, seed: Int) throws -> [Double] {
    var rng = SeededRandom(seed: UInt64(seed + 1000))
    let shape = target.shape()
    var errors = [Double]()
    for step in 1...count {
        let pair = search.comparison
        try check(min(pair.a.error(to: search.curve), pair.b.error(to: search.curve)) >= 0.7499, "Endpoint collapsed in \(scenario)/\(targetName)")
        let extra = slips && rng.uniform() < 0.05 ? 0.2 * rng.normal() : 0
        let position = min(1, max(-1, optimum(pair, target: shape) + noise * rng.normal() + extra))
        let chosen = pair.curve(at: position)
        search.accept(position)
        try check(search.curve == chosen && search.comparison.center == chosen, "Adopt the exact auditioned curve without averaging history")
        let left = search.curve.left.error(to: target.left), right = search.curve.right.error(to: target.right)
        errors.append(max(left, right))
        rows.append("\(scenario),\(targetName),\(seed),\(step),\(left),\(right),\(position)")
    }
    return errors
}
func tailMean(_ values: [Double]) -> Double { values.suffix(68).reduce(0, +) / Double(min(68, values.count)) }
for (scenario, noise, slips, limit) in [("ordinary", 0.025, false, 0.65), ("unreliable", 0.06, true, 1.5)] {
    for (index, target) in targets.enumerated() {
        for seed in 1...6 {
            let initial = index == 0 ? targets[1] : StereoEQCurve()
            var search = SliderSearch(initial: initial, seed: UInt64(seed))
            let errors = try run(&search, target: target, noise: noise, slips: slips, count: 408,
                                 scenario: scenario, targetName: String(index), seed: seed)
            let average = tailMean(errors)
            try check(average < limit, "\(scenario)/\(index)/\(seed): late mean worse-ear error \(average) exceeds \(limit)")
            results[scenario, default: []].append(average)
        }
        print("PASS \(scenario) target \(index)")
    }
}
for seed in 101...112 {
    var rng = SeededRandom(seed: UInt64(seed))
    let target = StereoEQCurve((0..<StereoEQCurve.count).map { _ in 10 * rng.uniform() - 5 })
    let initial = StereoEQCurve((0..<StereoEQCurve.count).map { _ in 10 * rng.uniform() - 5 })
    var search = SliderSearch(initial: initial, seed: UInt64(seed))
    let errors = try run(&search, target: target, noise: 0.025, slips: false, count: 408,
                         scenario: "holdout", targetName: String(seed), seed: seed)
    try check(tailMean(errors) < 0.65, "Unseen target \(seed): \(tailMean(errors))")
    results["holdout", default: []].append(tailMean(errors))
}
print("PASS Twelve unseen targets from unrelated starting curves")
for index in 1..<targets.count {
    var search = SliderSearch(seed: UInt64(index))
    let errors = try run(&search, target: targets[index], noise: 0, slips: false, count: 2040,
                         scenario: "noiseless", targetName: String(index), seed: index)
    try check(errors.last! < 0.15, "Noiseless long run \(index): \(errors.last!)")
    try check(errors.last! < errors[67], "Continued noiseless refinement must improve")
    results["noiseless", default: []].append(errors.last!)
}
print("PASS Long noiseless refinement")
for seed in 1...6 {
    let a = targets[seed % targets.count]
    let b = targets[(seed + 2) % targets.count]
    var search = SliderSearch(seed: UInt64(seed + 700))
    _ = try run(&search, target: a, noise: 0.025, slips: false, count: 1020,
                scenario: "before-shift", targetName: String(seed), seed: seed + 700)
    let initialError = search.curve.error(to: b)
    let errors = try run(&search, target: b, noise: 0.025, slips: false, count: 408,
                         scenario: "after-shift", targetName: String(seed), seed: seed + 900)
    try check(tailMean(errors) < 0.65, "Changed target \(seed): \(tailMean(errors))")
    try check(search.curve.error(to: b) < initialError / 2, "Changed target must substantially reduce its initial error")
    results["after-shift", default: []].append(tailMean(errors))
}
print("PASS Six target changes after 1,020 prior choices")

let encoder = JSONEncoder(), decoder = JSONDecoder()
encoder.outputFormatting = [.sortedKeys]
var search = SliderSearch(initial: targets[2], seed: 123)
let first = search.comparison
try check(first.curve(at: 0) == search.curve && first.curve(at: -1) == first.a && first.curve(at: 1) == first.b, "Slider endpoints and exact center")
try check(first.curve(at: -2) == first.a && first.curve(at: 2) == first.b, "Clamp slider range")
try check(first.curve(at: .nan) == search.curve, "Reject nonfinite preview positions")
search.accept(0)
try check(search.curve == first.center && search.comparison != first, "Keeping Current tries a fresh direction")
let beforeInvalid = try encoder.encode(search)
search.accept(.infinity)
try check(try encoder.encode(search) == beforeInvalid, "Ignore invalid commitments")
var resumed = try decoder.decode(SliderSearch.self, from: encoder.encode(search))
for position in [-1.0, -0.3, 0, 0.7, 1] {
    search.accept(position); resumed.accept(position)
    try check(try encoder.encode(search) == encoder.encode(resumed), "Deterministic resume")
}
for _ in 0..<2040 { search.accept(0) }
try check(try encoder.encode(search).count < 10000, "State size must stay bounded without vote history")
for extreme in [StereoEQCurve(Array(repeating: 12, count: 18)), StereoEQCurve(Array(repeating: -12, count: 18))] {
    var boundary = SliderSearch(initial: extreme, seed: 10)
    for _ in 0..<68 {
        try check(boundary.comparison.a.error(to: boundary.curve) >= 0.7499 && boundary.comparison.b.error(to: boundary.curve) >= 0.7499, "Keep meaningful endpoints at filter boundaries")
        boundary.accept(0)
    }
}
print("PASS Center/endpoints, finite inputs, serialization, fixed state size, and boundary exploration")

var original = ProfileLibrary()
original.add(name: "First headphones"); original.add(name: "Second headphones")
for i in original.profiles.indices {
    original.profiles[i].session = StereoPreferenceSearch(initial: targets[i + 1], seed: UInt64(i + 1))
    for _ in 0..<5 { _ = original.profiles[i].session?.next(); original.profiles[i].session?.answer(.slightA) }
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slider-storage-\(UUID())")
let originalURL = folder.appendingPathComponent("profiles.json")
try ProfileStorage.save(original, to: originalURL)
let originalBytes = try Data(contentsOf: originalURL)
var experiment = try SliderProfileStorage.open(in: folder)
try check(experiment.selected == original.selected && experiment.profiles.map(\.id) == original.profiles.map(\.id), "Preserve both identities and selection")
try check(experiment.profiles.map(\.currentCurve) == original.profiles.map(\.currentCurve), "Seed both profiles from their latest learned curves")
try check(experiment.profiles.allSatisfy { $0.session == nil && $0.slider != nil }, "No old evidence enters the new optimizer")
let backupFolders = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
try check(backupFolders.count == 1, "Create one original-history backup")
try check(try Data(contentsOf: backupFolders[0].appendingPathComponent("profiles.json")) == originalBytes, "Byte-identical history backup")
experiment.profiles[0].acceptSlider(0.6)
try ProfileStorage.save(experiment, to: folder.appendingPathComponent(SliderProfileStorage.filename))
let reloaded = try SliderProfileStorage.open(in: folder)
try check(reloaded.profiles.map(\.currentCurve) == experiment.profiles.map(\.currentCurve), "Resume the experiment without reseeding")
try check(try Data(contentsOf: originalURL) == originalBytes, "Original profiles must stay untouched")
try check(try ProfileStorage.load(from: originalURL).profiles.map(\.currentCurve) == original.profiles.map(\.currentCurve), "Original mode remains usable")
try Data("{invalid".utf8).write(to: folder.appendingPathComponent(SliderProfileStorage.filename))
var rejectedCorruption = false
 do { _ = try SliderProfileStorage.open(in: folder) }
 catch let error { rejectedCorruption = error.errorDescription != nil }
try check(rejectedCorruption, "Do not reseed over a corrupt experiment")
try check(try Data(contentsOf: originalURL) == originalBytes, "Corrupt experiment must not affect original history")
try FileManager.default.removeItem(at: folder)
print("PASS Both-profile seeding, exact backups, independent persistence, original-mode recovery, corrupt-file preservation")

var maximumGainMilliseconds = 0.0
for rate in [44100.0, 48000, 96000, 192000] {
    let comparison = SliderSearch(initial: targets[2], seed: 42).comparison
    let plan = SliderGainPlan(comparison: comparison, rate: rate)
    var centeredLevels = [Double]()
    for i in 0...32 {
        let curve = comparison.curve(at: Double(i) / 16 - 1)
        let start = Date()
        let gain = plan.gain(for: curve)
        maximumGainMilliseconds = max(maximumGainMilliseconds, Date().timeIntervalSince(start) * 1000)
        for (channel, trim) in [(curve.left, gain.left), (curve.right, gain.right)] {
            try check(trim <= 0 && trim + -channel.normalizedGain(rate: rate, margin: 0) <= -5.999, "Keep six dB headroom throughout the slider")
            let mean = EQCurve.grid.map { channel.response(at: $0, rate: rate) }.reduce(0, +) / Double(EQCurve.grid.count)
            centeredLevels.append(mean + trim)
        }
    }
    try check(centeredLevels.max()! - centeredLevels.min()! < 1e-8, "Keep a common centered playback level across slider positions and ears")
}
report.append(String(format: "Maximum measured slider gain calculation: %.2f ms", maximumGainMilliseconds))
print("PASS Continuous slider level matching and headroom at four sample rates")
for scenario in results.keys.sorted() {
    let values = results[scenario]!
    let line = String(format: "%@: %d trials; mean %.3f dB; worst %.3f dB", scenario, values.count, values.reduce(0,+)/Double(values.count), values.max()!)
    report.append(line); print(line)
}
try rows.joined(separator: "\n").write(to: output.appendingPathComponent("convergence.csv"), atomically: true, encoding: .utf8)
try report.joined(separator: "\n").write(to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
print("PASS All online slider checks. Results: \(output.path)")

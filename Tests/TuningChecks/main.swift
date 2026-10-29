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
    let tentative: Bool
    var random: SeededRandom
    mutating func vote(_ pair: Comparison, target: EQCurve) -> Vote {
        let a = pow(pair.a.error(to:target),2) + noise*random.normal()
        let b = pow(pair.b.error(to:target),2) + noise*random.normal()
        return (a < b) != (random.uniform() < lapse) ? .a : .b
    }
}
struct Trial {
    let name: String
    let target: EQCurve
}
let trials = [
    Trial(name:"flat", target:EQCurve()),
    Trial(name:"warm", target:EQCurve([5,3,1,0,0,0,-1,-2,-2])),
    Trial(name:"v-shaped", target:EQCurve([5,3,0,-2,-3,-1,1,3,4])),
    Trial(name:"presence", target:EQCurve([-2,-1,0,0,1,3,4,0,-2])),
    Trial(name:"dark", target:EQCurve([2,1,0,0,0,-1,-3,-5,-6])),
    Trial(name:"local notch", target:EQCurve([0,0,0,0,0,0,-5,0,0])),
    Trial(name:"alternating", target:EQCurve([3,-2,2,-3,2,-2,3,-2,1])),
    Trial(name:"strong bass", target:EQCurve([10,6,2,0,0,-1,-2,-2,-3]))
]
let output = CommandLine.arguments.dropFirst().first ?? "/tmp/lowshelf-validation"
try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
var rows = ["scenario,target,seed,iteration,error_db,uncertainty_db"]
var curveRows = ["scenario,target,seed,hz,target_db,matched_db"]
var report = ["LowShelf simulated-listener validation", "Metric: RMS dB error over 96 logarithmic frequencies, 20 Hz–20 kHz; overall level removed.", "Oracle: actual nine-filter responses, independent Gaussian utility noise, independent random vote reversals."]
let started = Date()
for (scenario,noise,lapse,tentative,budget,limit) in [
    ("ordinary", 0.9, 0.04, false, 240, 0.65),
    ("unreliable", 1.8, 0.10, true, 400, 1.0)
] {
    var checkpoints = [Int:[Double]]()
    for trial in trials {
        var errors = [Double]()
        for seed in 1...12 {
            var search = PreferenceSearch(seed: UInt64(seed))
            var listener = Listener(noise:noise, lapse:lapse, tentative:tentative, random:SeededRandom(seed:UInt64(seed+1000)))
            for iteration in 1...budget {
                let pair = search.next()
                let vote = listener.vote(pair,target:trial.target)
                search.answer(vote, confidence:tentative ? .tentative : .confident)
                let error = search.recommendation.error(to:trial.target)
                checkpoints[iteration,default:[]].append(error)
                rows.append("\(scenario),\(trial.name),\(seed),\(iteration),\(error),\(search.uncertainty)")
            }
            let error = search.recommendation.error(to:trial.target)
            try check(error < limit, "\(scenario)/\(trial.name)/\(seed): \(error) dB exceeds \(limit) dB at \(budget) votes")
            try check(search.uncertainty.isFinite, "Nonfinite uncertainty")
            errors.append(error)
            let expected = trial.target.shape(), matched = search.recommendation.shape()
            for i in EQCurve.grid.indices {
                curveRows.append("\(scenario),\(trial.name),\(seed),\(EQCurve.grid[i]),\(expected[i]),\(matched[i])")
            }
        }
        let line = String(format:"%@ / %@: mean %.3f, worst %.3f dB after %d votes",scenario,trial.name,errors.reduce(0,+)/Double(errors.count),errors.max()!,budget)
        print(line); report.append(line)
    }
    for step in [25,50,100,budget] {
        let values = try required(checkpoints[step])
        report.append(String(format:"%@ at %d: mean %.3f, worst %.3f dB",scenario,step,values.reduce(0,+)/Double(values.count),values.max()!))
    }
}
// Independent holdout curves and seeds are not the fixtures used during development.
for seed in 101...112 {
    var rng = SeededRandom(seed:UInt64(seed))
    let gains = (0..<EQCurve.count).map { _ in 8*rng.uniform()-4 }
    let target = EQCurve(gains)
    var search = PreferenceSearch(seed:UInt64(seed))
    var listener = Listener(noise:0.9,lapse:0.04,tentative:false,random:SeededRandom(seed:UInt64(seed+1000)))
    for _ in 0..<240 { let pair = search.next(); search.answer(listener.vote(pair,target:target)) }
    try check(search.recommendation.error(to:target) < 0.65, "Holdout seed \(seed) did not converge")
}
print("PASS  Twelve unseen random target curves")
var longEarly = [Double](), longLate = [Double]()
for trial in [trials[1],trials[5],trials[6]] {
    for seed in 21...24 {
        var search = PreferenceSearch(seed:UInt64(seed))
        var listener = Listener(noise:0.9,lapse:0.04,tentative:false,random:SeededRandom(seed:UInt64(seed+1000)))
        for _ in 0..<240 { let pair = search.next(); search.answer(listener.vote(pair,target:trial.target)) }
        longEarly.append(search.recommendation.error(to:trial.target))
        for iteration in 241...3000 {
            let pair = search.next(); search.answer(listener.vote(pair,target:trial.target))
            rows.append("long,\(trial.name),\(seed),\(iteration),\(search.recommendation.error(to:trial.target)),\(search.uncertainty)")
        }
        longLate.append(search.recommendation.error(to:trial.target))
        try check(search.recommendation.error(to:trial.target) < 0.15, "Long-run accuracy floor: \(trial.name)/\(seed)")
    }
}
let early = longEarly.reduce(0,+)/Double(longEarly.count), late = longLate.reduce(0,+)/Double(longLate.count)
try check(late < early/2, "Long-run error did not continue to decrease")
report.append(String(format:"Long runs: mean %.3f dB at 240 → %.3f dB at 3000; worst final %.3f dB",early,late,longLate.max()!))
print(report.last!)

var search = PreferenceSearch(seed:71)
let initial = search.recommendation
let pair = search.next()
let originalCovariance = search.covariance
search.answer(.unsure)
try check(search.recommendation == initial && search.covariance == originalCovariance, "Unsure must not train the model")
search.undo()
try check(search.current == pair && search.answers.isEmpty, "Undo must restore the unanswered pair")
var confident = search, tentative = search
confident.answer(.a,confidence:.confident); tentative.answer(.a,confidence:.tentative)
try check(confident.uncertainty < tentative.uncertainty, "Tentative answer must convey less information")
search.answer(.equal)
try check(search.uncertainty < tentative.uncertainty, "A tie should provide information")
search.undo()
try check(search.covariance == originalCovariance, "Undo must restore uncertainty")

var skipBoundary = PreferenceSearch(seed:123)
for _ in 0..<19 { _ = skipBoundary.next(); skipBoundary.answer(.a) }
_ = skipBoundary.next()
let beforeSkip = skipBoundary.mean, covarianceBeforeSkip = skipBoundary.covariance
skipBoundary.answer(.unsure)
try check(skipBoundary.mean == beforeSkip && skipBoundary.covariance == covarianceBeforeSkip, "Skipping at a refit boundary must not change the model")

var library = ProfileLibrary(); library.add(name:"Test IEM")
var stereoConfident = StereoPreferenceSearch(migrating: confident)
library.profiles[0].session = stereoConfident
let saved = library.profiles[0].saved
let url = URL(fileURLWithPath:output).appendingPathComponent("profiles-test.json")
try ProfileStorage.save(library,to:url)
let restored = try ProfileStorage.load(from:url)
try check(restored.profiles[0].saved == saved, "Tuning must not overwrite saved EQ")
var resumed = try required(restored.profiles[0].session)
try check(resumed.next() == stereoConfident.next(), "Resuming must preserve the exact next comparison")
try "invalid json".write(to:url,atomically:true,encoding:.utf8)
do {
    _ = try ProfileStorage.load(from:url)
    throw Failure(message:"Corrupt file should fail")
} catch is ProfileFailure {}
try check(try String(contentsOf:url,encoding:.utf8) == "invalid json", "Corrupt file must remain untouched")
try FileManager.default.removeItem(at:url)
print("PASS  Uncertainty, ties, skip, undo, exact resume, profile isolation, and corrupt-file preservation")

func process(_ dsp: OpaquePointer, _ input: [Float]) -> [Float] {
    var output = [Float](repeating:0,count:input.count)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { target in bass_process(dsp,source.baseAddress,target.baseAddress,UInt32(input.count/2)) }
    }
    return output
}
func apply(_ curve: EQCurve, to dsp: OpaquePointer, rate: Double) {
    let coefficients = curve.gains.indices.flatMap { curve.coefficients(index:$0,gain:curve.gains[$0],rate:rate) }
    coefficients.withUnsafeBufferPointer { bass_equalizer(dsp,$0.baseAddress,curve.normalizedGain(rate:rate),true) }
}
func rms(_ samples: [Float]) -> Double { sqrt(samples.reduce(0) { $0+Double($1)*Double($1) } / Double(samples.count)) }
for rate in [44100.0,48000,96000,192000] {
    let curve = trials[2].target
    let dsp = try required(bass_create(rate,0,100,1,0)); defer { bass_destroy(dsp) }
    apply(curve,to:dsp,rate:rate)
    for hz in [25.0,80,315,2500,10000,18000] {
        let count = Int(rate*2)
        let input = (0..<count).flatMap { i -> [Float] in
            let sample = Float(0.25*sin(2 * .pi*hz*Double(i)/rate)); return [sample,0]
        }
        let output = process(dsp,input)
        let left = stride(from:count,to:output.count,by:2).map { output[$0] }
        let reference = stride(from:count,to:input.count,by:2).map { input[$0] }
        let measured = 20*log10(rms(left)/rms(reference))
        let expected = curve.response(at:hz,rate:rate)+curve.normalizedGain(rate:rate)
        try check(abs(measured-expected) < 0.02,"DSP response mismatch at \(rate)/\(hz): \(measured) vs \(expected)")
        try check(stride(from:1,to:output.count,by:2).allSatisfy { output[$0] == 0 },"Stereo crosstalk")
    }
    try check(bass_take_faults(dsp) == 0,"DSP reported a fault")
}
let dsp = try required(bass_create(48000,0,100,1,0)); defer { bass_destroy(dsp) }
let input = (0..<256).flatMap { i -> [Float] in let v = Float(0.25*sin(2 * .pi*80*Double(i)/48000)); return [v,v] }
for i in 0..<500 {
    apply(trials[i % trials.count].target,to:dsp,rate:48000)
    let output = process(dsp,input)
    try check(output.allSatisfy { $0.isFinite && abs($0) < 1 },"Rapid A/B switching became unstable")
}
try check(bass_take_faults(dsp) == 0,"Rapid switching fault")
print("PASS  Actual audio matches curves at four sample rates; stereo isolation and rapid switching")
report.append(String(format:"Completed in %.1f seconds",Date().timeIntervalSince(started)))
try rows.joined(separator:"\n").write(toFile:output+"/convergence.csv",atomically:true,encoding:.utf8)
try curveRows.joined(separator:"\n").write(toFile:output+"/curves.csv",atomically:true,encoding:.utf8)
try report.joined(separator:"\n").write(toFile:output+"/report.txt",atomically:true,encoding:.utf8)
print("PASS  All tuning checks. Results: \(output)")

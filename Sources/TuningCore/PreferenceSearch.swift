import Foundation

public enum Vote: String, Codable, Sendable { case a, b, equal, unsure }
public enum Confidence: String, Codable, CaseIterable, Sendable { case tentative, confident }
public struct Comparison: Codable, Equatable, Sendable {
    public let a: EQCurve
    public let b: EQCurve
}
public struct Answer: Codable, Sendable {
    public let comparison: Comparison
    public let vote: Vote
    public let confidence: Confidence
    let direction: [Double]
    let offset: Double
}

public struct PreferenceSearch: Codable, Sendable {
    public private(set) var mean: [Double]
    public private(set) var covariance: [[Double]]
    public private(set) var answers: [Answer] = []
    public private(set) var current: Comparison?
    private var random: SeededRandom
    private let initial: EQCurve
    private static let n = EQCurve.count
    private static let basis: [[Double]] = (0..<n).map { i in
        var gains = [Double](repeating: 0, count: n); gains[i] = 1
        return EQCurve(gains).shape()
    }
    private static let metric: [[Double]] = (0..<n).map { i in
        (0..<n).map { j in dot(basis[i], basis[j]) / Double(EQCurve.grid.count) }
    }
    public init(initial: EQCurve = EQCurve(), seed: UInt64 = 1) {
        self.initial = initial
        mean = initial.gains
        covariance = Array(repeating: Array(repeating: 0.0, count: Self.n), count: Self.n)
        for i in 0..<Self.n {
            for j in 0..<Self.n {
                let distance = Double(i - j)
                covariance[i][j] = 16.0 * exp(-distance * distance / 5.0)
                if i == j { covariance[i][j] += 4.0 }
            }
        }
        random = SeededRandom(seed: seed)
    }
    var continuationRandom: SeededRandom { random }
    public var recommendation: EQCurve { EQCurve(mean) }
    private var informativeCount: Int { answers.reduce(0) { $0 + ($1.vote == .unsure ? 0 : 1) } }
    public var uncertainty: Double {
        var sum = 0.0
        for i in 0..<Self.n {
            for j in 0..<Self.n { sum += covariance[i][j] * Self.metric[i][j] }
        }
        return sqrt(max(0, sum))
    }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).reduce(0) { $0 + $1.0*$1.1 } }
    private func multiply(_ v: [Double]) -> [Double] { covariance.map { Self.dot($0,v) } }
    private struct LocalModel {
        let mean: [Double]
        let shape: [Double]
        let jacobian: [[Double]]
    }
    private func localModel() -> LocalModel {
        let jacobian = (0..<Self.n).map { i in
            var lo = mean, hi = mean
            lo[i] = max(-12, mean[i]-0.05); hi[i] = min(12, mean[i]+0.05)
            let width = hi[i]-lo[i]
            return zip(EQCurve(hi).shape(), EQCurve(lo).shape()).map { ($0-$1)/width }
        }
        return LocalModel(mean:mean, shape:recommendation.shape(), jacobian:jacobian)
    }
    private static func observation(_ comparison: Comparison) -> (direction: [Double], offset: Double) {
        let a = comparison.a.shape(), b = comparison.b.shape()
        return (zip(a,b).map { 2*($0-$1)/Double(a.count) }, (dot(b,b)-dot(a,a))/Double(a.count))
    }
    private static func evidence(_ direction: [Double], _ offset: Double, at model: LocalModel) -> (h: [Double], bias: Double) {
        let h = model.jacobian.map { dot(direction,$0) }
        return (h, offset + dot(direction,model.shape) - dot(h,model.mean))
    }
    public mutating func next() -> Comparison {
        let n = Self.n
        let model = localModel()
        var directions = [[Double]]()
        for k in 0..<n {
            var direction = [Double]()
            for i in 0..<n {
                let phase = Double.pi * (Double(i) + 0.5) * Double(k) / Double(n)
                direction.append(cos(phase))
            }
            directions.append(direction)
        }
        for _ in 0..<8 { directions.append((0..<n).map { _ in random.normal() }) }
        var best: Comparison?
        var bestScore = -Double.infinity
        for direction in directions {
            let shape = (0..<EQCurve.grid.count).map { f in
                (0..<n).reduce(0) { $0 + direction[$1] * Self.basis[$1][f] }
            }
            let rms = sqrt(Self.dot(shape,shape) / Double(shape.count))
            guard rms > 0.01 else { continue }
            let radius = min(3, max(1.5, uncertainty)) / rms
            let a = EQCurve(zip(mean,direction).map { $0 + radius*$1 })
            let b = EQCurve(zip(mean,direction).map { $0 - radius*$1 })
            let pair = Comparison(a:a, b:b)
            let observation = Self.observation(pair)
            let e = Self.evidence(observation.direction, observation.offset, at:model), ch = multiply(e.h)
            let variance = Self.dot(e.h,ch) + 2.25
            let z = (Self.dot(e.h,mean) + e.bias) / sqrt(variance)
            var reduction = 0.0
            for i in 0..<n { reduction += ch[i] * Self.dot(Self.metric[i],ch) }
            reduction *= exp(-z*z/2) / variance
            if reduction > bestScore { best = pair; bestScore = reduction }
        }
        let pair = best ?? Comparison(a: recommendation, b: recommendation)
        let result = random.uniform() < 0.5 ? pair : Comparison(a:pair.b, b:pair.a)
        current = result
        return result
    }
    public mutating func answer(_ vote: Vote, confidence: Confidence = .confident) {
        guard let current else { return }
        let observation = Self.observation(current)
        let answer = Answer(comparison: current, vote: vote, confidence: confidence,
                            direction: observation.direction, offset: observation.offset)
        answers.append(answer)
        update(answer)
        if answer.vote != .unsure && informativeCount % 20 == 0 { refit() }
        self.current = nil
    }
    private mutating func update(_ answer: Answer, at model: LocalModel? = nil) {
        guard answer.vote != .unsure else { return }
        let e = Self.evidence(answer.direction, answer.offset, at: model ?? localModel())
        let ch = multiply(e.h)
        let noise = answer.confidence == .tentative ? 3.5 : 1.5
        let variance = Self.dot(e.h,ch) + noise*noise
        let expectation = Self.dot(e.h,mean) + e.bias
        let delta: Double, contraction: Double
        if answer.vote == .equal {
            // A tie is a noisy equality observation, never an exact constraint.
            delta = -expectation / variance
            contraction = 1 / variance
        } else {
            let sign = answer.vote == .a ? 1.0 : -1.0
            let z = sign * expectation / sqrt(variance)
            let phi = exp(-z*z/2) / sqrt(2 * .pi)
            let cdf = 0.5 * erfc(-z / sqrt(2))
            let lapse = 0.08
            let ratio = (1-lapse) * phi / max(1e-12, lapse/2 + (1-lapse)*cdf)
            delta = sign * ratio / sqrt(variance)
            contraction = ratio * (ratio + z) / variance
        }
        for i in 0..<Self.n {
            mean[i] = min(12, max(-12, mean[i] + ch[i]*delta))
            for j in 0..<Self.n { covariance[i][j] -= ch[i]*ch[j]*contraction }
        }
    }
    private mutating func refit() {
        // Revisit all evidence once from the prior, avoiding permanent early-vote bias.
        let model = localModel()
        let prior = PreferenceSearch(initial: initial)
        mean = prior.mean; covariance = prior.covariance
        var order = answers.indices.filter { answers[$0].vote != .unsure }
        var shuffle = SeededRandom(seed: UInt64(order.count) &* 7919)
        for i in stride(from: order.count-1, through: 1, by: -1) {
            order.swapAt(i, Int(shuffle.uniform()*Double(i+1)))
        }
        for i in order { update(answers[i], at:model) }
    }
    public mutating func undo() {
        rollback(to: answers.count - 1)
    }
    public mutating func rollback(to retainedCount: Int) {
        guard retainedCount >= 0, retainedCount < answers.count else { return }
        let removed = answers[retainedCount]
        let retained = Array(answers.prefix(retainedCount))
        let rng = random
        self = PreferenceSearch(initial: initial)
        for answer in retained {
            answers.append(answer); update(answer)
            if answer.vote != .unsure && informativeCount % 20 == 0 { refit() }
        }
        random = rng
        current = removed.comparison
    }
}

extension PreferenceSearch {
    var valid: Bool {
        guard initial.valid, mean.count == Self.n, mean.allSatisfy({ $0.isFinite && abs($0) <= 12 }),
              covariance.count == Self.n,
              covariance.allSatisfy({ $0.count == Self.n && $0.allSatisfy(\.isFinite) }),
              answers.allSatisfy({ $0.comparison.a.valid && $0.comparison.b.valid && $0.direction.count == EQCurve.grid.count && $0.direction.allSatisfy(\.isFinite) && $0.offset.isFinite }),
              current.map({ $0.a.valid && $0.b.valid }) ?? true else { return false }
        // Reject invalid covariance before it can affect query selection.
        var lower = Array(repeating: Array(repeating: 0.0, count: Self.n), count: Self.n)
        for i in 0..<Self.n {
            for j in 0...i {
                guard abs(covariance[i][j]-covariance[j][i]) < 1e-7 else { return false }
                var value = covariance[i][j]
                for k in 0..<j { value -= lower[i][k]*lower[j][k] }
                if i == j {
                    guard value > 0 else { return false }
                    lower[i][j] = sqrt(value)
                } else { lower[i][j] = value/lower[j][j] }
            }
        }
        return true
    }
}

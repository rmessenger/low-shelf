import Foundation

public enum PreferenceRating: String, Codable, CaseIterable, Sendable {
    case strongA, slightA, indistinguishable, slightB, strongB
    public var label: String {
        switch self {
        case .strongA: return "Strongly prefer A"
        case .slightA: return "Slightly prefer A"
        case .indistinguishable: return "Can’t tell the difference"
        case .slightB: return "Slightly prefer B"
        case .strongB: return "Strongly prefer B"
        }
    }
    var bounds: (lower: Double, upper: Double) {
        switch self {
        case .strongA: return (4, .infinity)
        case .slightA: return (1, 4)
        case .indistinguishable: return (-1, 1)
        case .slightB: return (-4, -1)
        case .strongB: return (-.infinity, -4)
        }
    }
}
public struct StereoComparison: Codable, Equatable, Sendable {
    public let a: StereoEQCurve
    public let b: StereoEQCurve
}
public struct RatedAnswer: Codable, Sendable {
    public let comparison: StereoComparison
    public let rating: PreferenceRating
    let direction: [Double]
    let offset: Double
}

public struct StereoPreferenceSearch: Codable, Sendable {
    public private(set) var mean: [Double]
    public private(set) var covariance: [[Double]]
    public private(set) var answers: [RatedAnswer] = []
    public private(set) var current: StereoComparison?
    private var random: SeededRandom
    private let priorMean: [Double]
    private let priorCovariance: [[Double]]
    public private(set) var legacyHistory: PreferenceSearch?
    private static let n = StereoEQCurve.count
    private static let basis: [[Double]] = (0..<n).map { i in
        var gains = [Double](repeating: 0, count: n); gains[i] = 1
        return StereoEQCurve(gains).shape()
    }
    private static let metric: [[Double]] = (0..<n).map { i in
        (0..<n).map { j in dot(basis[i], basis[j]) / Double((EQCurve.grid.count * 2)) }
    }
    public init(initial: StereoEQCurve = StereoEQCurve(), seed: UInt64 = 1) {
        mean = initial.gains
        let shared = PreferenceSearch()
        covariance = Self.stereoCovariance(shared.covariance)
        priorMean = mean; priorCovariance = covariance
        random = SeededRandom(seed: seed)
    }
    public init(migrating legacy: PreferenceSearch) {
        mean = legacy.mean + legacy.mean
        covariance = Self.stereoCovariance(legacy.covariance)
        priorMean = mean; priorCovariance = covariance
        random = legacy.continuationRandom
        legacyHistory = legacy
        current = legacy.current.map { StereoComparison(a: StereoEQCurve(shared: $0.a), b: StereoEQCurve(shared: $0.b)) }
    }
    private static func stereoCovariance(_ shared: [[Double]]) -> [[Double]] {
        (0..<n).map { i in
            (0..<n).map { j in
                let a = i % EQCurve.count, b = j % EQCurve.count
                let distance = Double(a-b)
                let difference = 1.5 * exp(-distance*distance/5) + (a == b ? 1.5 : 0)
                return shared[a][b] + (i / EQCurve.count == j / EQCurve.count ? difference : -difference)
            }
        }
    }
    public var completedComparisons: Int { (legacyHistory?.answers.count ?? 0) + answers.count }
    public var recommendation: StereoEQCurve { StereoEQCurve(mean) }
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
            return zip(StereoEQCurve(hi).shape(), StereoEQCurve(lo).shape()).map { ($0-$1)/width }
        }
        return LocalModel(mean:mean, shape:recommendation.shape(), jacobian:jacobian)
    }
    private static func observation(_ comparison: StereoComparison) -> (direction: [Double], offset: Double) {
        let a = comparison.a.shape(), b = comparison.b.shape()
        return (zip(a,b).map { 2*($0-$1)/Double(a.count) }, (dot(b,b)-dot(a,a))/Double(a.count))
    }
    private static func evidence(_ direction: [Double], _ offset: Double, at model: LocalModel) -> (h: [Double], bias: Double) {
        let h = model.jacobian.map { dot(direction,$0) }
        return (h, offset + dot(direction,model.shape) - dot(h,model.mean))
    }
    public mutating func next() -> StereoComparison {
        let n = Self.n
        let model = localModel()
        var directions = [[Double]]()
        for k in 0..<EQCurve.count {
            let common = (0..<EQCurve.count).map { i in
                cos(Double.pi * (Double(i) + 0.5) * Double(k) / Double(EQCurve.count))
            }
            directions.append(common + common)
            directions.append(common + common.map { -$0 })
        }
        for _ in 0..<8 { directions.append((0..<n).map { _ in random.normal() }) }
        var best: StereoComparison?
        var bestScore = -Double.infinity
        for direction in directions {
            let shape = (0..<(EQCurve.grid.count * 2)).map { f in
                (0..<n).reduce(0) { $0 + direction[$1] * Self.basis[$1][f] }
            }
            let rms = sqrt(Self.dot(shape,shape) / Double(shape.count))
            guard rms > 0.01 else { continue }
            let radius = min(3, max(2, uncertainty)) / rms
            let a = StereoEQCurve(zip(mean,direction).map { $0 + radius*$1 })
            let b = StereoEQCurve(zip(mean,direction).map { $0 - radius*$1 })
            let pair = StereoComparison(a:a, b:b)
            let observation = Self.observation(pair)
            let e = Self.evidence(observation.direction, observation.offset, at:model), ch = multiply(e.h)
            let variance = Self.dot(e.h,ch) + 2.25
            let z = (Self.dot(e.h,mean) + e.bias) / sqrt(variance)
            var reduction = 0.0
            for i in 0..<n { reduction += ch[i] * Self.dot(Self.metric[i],ch) }
            reduction *= exp(-z*z/2) / variance
            if reduction > bestScore { best = pair; bestScore = reduction }
        }
        let pair = best ?? StereoComparison(a: recommendation, b: recommendation)
        let result = random.uniform() < 0.5 ? pair : StereoComparison(a:pair.b, b:pair.a)
        current = result
        return result
    }
    public mutating func answer(_ rating: PreferenceRating) {
        guard let current else { return }
        let observation = Self.observation(current)
        let answer = RatedAnswer(comparison: current, rating: rating,
                                 direction: observation.direction, offset: observation.offset)
        answers.append(answer)
        update(answer)
        if answers.count % 20 == 0 { refit() }
        self.current = nil
    }
    private mutating func update(_ answer: RatedAnswer, at model: LocalModel? = nil) {
        let e = Self.evidence(answer.direction, answer.offset, at: model ?? localModel())
        let ch = multiply(e.h)
        let variance = Self.dot(e.h,ch) + 2.25
        let expectation = Self.dot(e.h,mean) + e.bias
        let bounds = answer.rating.bounds
        let sigma = sqrt(variance)
        let low = (bounds.lower - expectation) / sigma
        let high = (bounds.upper - expectation) / sigma
        func density(_ z: Double) -> Double { exp(-z*z/2) / sqrt(2 * .pi) }
        func weightedDensity(_ z: Double) -> Double { z.isFinite ? z*density(z) : 0 }
        let probability: Double
        if low > 0 {
            probability = 0.5 * (erfc(low / sqrt(2)) - erfc(high / sqrt(2)))
        } else {
            probability = 0.5 * (erfc(-high / sqrt(2)) - erfc(-low / sqrt(2)))
        }
        // An ordinal interval with a lapse mixture: strong means larger, not infallible.
        let likelihood = max(1e-15, 0.08 / 5 + 0.92 * probability)
        let first = 0.92 * (density(low) - density(high)) / likelihood
        let second = 0.92 * (weightedDensity(low) - weightedDensity(high)) / likelihood
        let delta = first / sigma
        let contraction = (first*first - second) / variance
        for i in 0..<Self.n {
            mean[i] = min(12, max(-12, mean[i] + ch[i]*delta))
            for j in 0..<Self.n { covariance[i][j] -= ch[i]*ch[j]*contraction }
        }
    }
    private mutating func refit() {
        // Revisit all evidence once from the prior, avoiding permanent early-vote bias.
        let model = localModel()
        mean = priorMean; covariance = priorCovariance
        var order = Array(answers.indices)
        var shuffle = SeededRandom(seed: UInt64(order.count) &* 7919)
        for i in stride(from: order.count-1, through: 1, by: -1) {
            order.swapAt(i, Int(shuffle.uniform()*Double(i+1)))
        }
        for i in order { update(answers[i], at:model) }
    }
    public mutating func undo() {
        guard !answers.isEmpty else { return }
        let removed = answers.removeLast()
        let retained = answers
        let rng = random
        mean = priorMean; covariance = priorCovariance; answers = []
        for answer in retained {
            answers.append(answer); update(answer)
            if answers.count % 20 == 0 { refit() }
        }
        random = rng
        current = removed.comparison
    }
}

extension StereoPreferenceSearch {
    var valid: Bool {
        guard priorMean.count == Self.n, priorMean.allSatisfy({ $0.isFinite && abs($0) <= 12 }),
              priorCovariance.count == Self.n, priorCovariance.allSatisfy({ $0.count == Self.n && $0.allSatisfy(\.isFinite) }),
              legacyHistory?.valid != false, mean.count == Self.n, mean.allSatisfy({ $0.isFinite && abs($0) <= 12 }),
              covariance.count == Self.n,
              covariance.allSatisfy({ $0.count == Self.n && $0.allSatisfy(\.isFinite) }),
              answers.allSatisfy({ $0.comparison.a.valid && $0.comparison.b.valid && $0.direction.count == EQCurve.grid.count * 2 && $0.direction.allSatisfy(\.isFinite) && $0.offset.isFinite }),
              current.map({ $0.a.valid && $0.b.valid }) ?? true else { return false }
        return Self.positiveDefinite(covariance) && Self.positiveDefinite(priorCovariance)
    }
    private static func positiveDefinite(_ matrix: [[Double]]) -> Bool {
        var lower = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                guard abs(matrix[i][j]-matrix[j][i]) < 1e-7 else { return false }
                var value = matrix[i][j]
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

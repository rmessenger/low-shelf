import Foundation

public struct SliderComparison: Codable, Equatable, Sendable {
    public let center: StereoEQCurve
    public let a: StereoEQCurve
    public let b: StereoEQCurve
    public func curve(at position: Double) -> StereoEQCurve {
        guard position.isFinite else { return center }
        let t = min(1, max(-1, position))
        let end = t < 0 ? a : b
        return StereoEQCurve(zip(center.gains, end.gains).map { $0 + abs(t) * ($1 - $0) })
    }
}

public struct SliderSearch: Codable, Sendable {
    public private(set) var curve: StereoEQCurve
    public private(set) var comparison: SliderComparison
    public private(set) var adjustments = 0
    private var random: SeededRandom
    private var order: [Int] = []
    private var cursor = 0
    public init(initial: StereoEQCurve = StereoEQCurve(), seed: UInt64 = 1) {
        curve = initial
        comparison = SliderComparison(center: initial, a: initial, b: initial)
        random = SeededRandom(seed: seed)
        advance()
    }
    public mutating func accept(_ position: Double) {
        guard position.isFinite else { return }
        curve = comparison.curve(at: position)
        adjustments += 1
        advance()
    }
    private mutating func advance() {
        var best: SliderComparison?
        var bestDistance = -Double.infinity
        for _ in Self.directions.indices {
            if cursor >= order.count {
                order = Array(Self.directions.indices)
                for i in stride(from: order.count - 1, through: 1, by: -1) {
                    order.swapAt(i, Int(random.uniform() * Double(i + 1)))
                }
                cursor = 0
            }
            let direction = Self.directions[order[cursor]]
            cursor += 1
            let sign = random.uniform() < 0.5 ? -1.0 : 1.0
            let a = StereoEQCurve(zip(curve.gains, direction).map { $0 - sign * 2.5 * $1 })
            let b = StereoEQCurve(zip(curve.gains, direction).map { $0 + sign * 2.5 * $1 })
            let pair = SliderComparison(center: curve, a: a, b: b)
            let distance = min(a.error(to: curve), b.error(to: curve))
            if distance > bestDistance { best = pair; bestDistance = distance }
            if distance >= 0.75 { comparison = pair; return }
        }
        comparison = best!
    }
    // Orthogonal response directions avoid repeatedly undoing adjacent bands' changes.
    private static let directions: [[Double]] = {
        let n = StereoEQCurve.count
        let basis = (0..<n).map { i -> [Double] in
            var gains = [Double](repeating: 0, count: n); gains[i] = 0.01
            return StereoEQCurve(gains).shape().map { $0 / 0.01 }
        }
        var gainsBasis = [[Double]](), shapes = [[Double]]()
        for k in Array(1..<EQCurve.count) + [0] {
            let cosine = (0..<EQCurve.count).map { cos(.pi * (Double($0) + 0.5) * Double(k) / Double(EQCurve.count)) }
            for sign in [1.0, -1.0] {
                var gains = cosine + cosine.map { sign * $0 }
                var shape = (0..<basis[0].count).map { f in (0..<n).reduce(0) { $0 + gains[$1] * basis[$1][f] } }
                for j in shapes.indices {
                    let projection = dot(shape, shapes[j])
                    gains = zip(gains, gainsBasis[j]).map { $0 - projection * $1 }
                    shape = zip(shape, shapes[j]).map { $0 - projection * $1 }
                }
                let norm = sqrt(dot(shape, shape))
                gainsBasis.append(gains.map { $0 / norm }); shapes.append(shape.map { $0 / norm })
            }
        }
        // Near-flat directions need huge gains; individual bands cover those degrees of freedom.
        gainsBasis.removeLast(2)
        for i in 0..<n {
            let norm = sqrt(dot(basis[i], basis[i]))
            var axis = [Double](repeating: 0, count: n); axis[i] = 1 / norm
            gainsBasis.append(axis)
        }
        return gainsBasis
    }()
    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / Double(a.count)
    }
    var valid: Bool {
        curve.valid && comparison.center == curve && comparison.a.valid && comparison.b.valid && adjustments >= 0 &&
        order.count == Self.directions.count && Set(order) == Set(Self.directions.indices) && (1...order.count).contains(cursor)
    }
}

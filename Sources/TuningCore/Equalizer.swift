import Foundation

public struct EQCurve: Codable, Equatable, Sendable {
    public static let frequencies = [40.0, 80, 160, 315, 630, 1250, 2500, 5000, 10000]
    public static let count = frequencies.count
    public var gains: [Double]
    public init(_ gains: [Double] = Array(repeating: 0, count: count)) {
        precondition(gains.count == Self.count && gains.allSatisfy(\.isFinite))
        self.gains = gains.map { min(12, max(-12, $0)) }
    }
    public func response(at hz: Double, rate: Double = 48000) -> Double {
        zip(Self.frequencies.indices, gains).reduce(0) { result, pair in
            let c = coefficients(index: pair.0, gain: pair.1, rate: rate)
            let w = 2 * Double.pi * min(hz, rate * 0.499) / rate
            let nr = c[0] + c[1] * cos(w) + c[2] * cos(2*w)
            let ni = -c[1] * sin(w) - c[2] * sin(2*w)
            let dr = 1 + c[3] * cos(w) + c[4] * cos(2*w)
            let di = -c[3] * sin(w) - c[4] * sin(2*w)
            return result + 20 * log10(hypot(nr, ni) / hypot(dr, di))
        }
    }
    public func coefficients(index: Int, gain: Double, rate: Double) -> [Double] {
        let a = pow(10, gain / 40)
        let w = 2 * Double.pi * min(Self.frequencies[index], rate * 0.4) / rate
        let c = cos(w), s = sin(w)
        let alpha = s / (2 * 0.85)
        if index == 0 || index == Self.count - 1 {
            let beta = sqrt(2 * a) * s
            let plus = a + 1.0, minus = a - 1.0
            if index == 0 {
                let d = plus + minus*c + beta
                let b0 = a * (plus - minus*c + beta) / d
                let b1 = 2*a * (minus - plus*c) / d
                let b2 = a * (plus - minus*c - beta) / d
                let a1 = -2 * (minus + plus*c) / d
                let a2 = (plus + minus*c - beta) / d
                return [b0, b1, b2, a1, a2]
            }
            let d = plus - minus*c + beta
            let b0 = a * (plus + minus*c + beta) / d
            let b1 = -2*a * (minus + plus*c) / d
            let b2 = a * (plus + minus*c - beta) / d
            let a1 = 2 * (minus - plus*c) / d
            let a2 = (plus - minus*c - beta) / d
            return [b0, b1, b2, a1, a2]
        }
        let d = 1 + alpha/a
        return [(1+alpha*a)/d, -2*c/d, (1-alpha*a)/d, -2*c/d, (1-alpha/a)/d]
    }
    public static let grid = (0..<96).map { 20 * pow(1000, Double($0)/95) }
    private static let trig: [[Double]] = grid.map {
        let w = 2 * Double.pi * $0 / 48000
        return [cos(w), cos(2*w), sin(w), sin(2*w)]
    }
    public func shape() -> [Double] {
        let filters = gains.indices.map { coefficients(index: $0, gain: gains[$0], rate: 48000) }
        let values = Self.trig.map { t in
            filters.reduce(0.0) { sum, c in
                let nr = c[0] + c[1]*t[0] + c[2]*t[1]
                let ni = c[1]*t[2] + c[2]*t[3]
                let dr = 1 + c[3]*t[0] + c[4]*t[1]
                let di = c[3]*t[2] + c[4]*t[3]
                return sum + 10 * log10((nr*nr+ni*ni)/(dr*dr+di*di))
            }
        }
        return Self.centered(values)
    }
    public static func centered(_ values: [Double]) -> [Double] {
        let mean = values.reduce(0,+) / Double(values.count)
        return values.map { $0 - mean }
    }
    public func error(to other: EQCurve) -> Double {
        sqrt(zip(shape(), other.shape()).reduce(0) { $0 + pow($1.0-$1.1, 2) } / Double(Self.grid.count))
    }
    public func normalizedGain(rate: Double, margin: Double = 6) -> Double {
        let peak = (0...2048).map { response(at: Double($0) * rate / 4096, rate: rate) }.max() ?? 0
        return -max(0, peak) - margin
    }
}

public struct SeededRandom: Codable, Sendable {
    public var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func uniform() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return Double((z ^ (z >> 31)) >> 11) / 9007199254740992
    }
    public mutating func normal() -> Double {
        sqrt(-2 * log(max(1e-15, uniform()))) * cos(2 * .pi * uniform())
    }
}

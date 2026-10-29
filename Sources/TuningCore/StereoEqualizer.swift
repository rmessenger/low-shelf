import Foundation

public struct StereoEQCurve: Codable, Equatable, Sendable {
    public let left: EQCurve
    public let right: EQCurve
    public static let count = EQCurve.count * 2
    public init(left: EQCurve = EQCurve(), right: EQCurve = EQCurve()) {
        self.left = left; self.right = right
    }
    public init(shared: EQCurve) { self.init(left: shared, right: shared) }
    public init(_ gains: [Double]) {
        precondition(gains.count == Self.count)
        self.init(left: EQCurve(Array(gains.prefix(EQCurve.count))), right: EQCurve(Array(gains.suffix(EQCurve.count))))
    }
    public var gains: [Double] { left.gains + right.gains }
    public func shape() -> [Double] { left.shape() + right.shape() }
    public func error(to other: StereoEQCurve) -> Double {
        sqrt((pow(left.error(to: other.left), 2) + pow(right.error(to: other.right), 2)) / 2)
    }
    var valid: Bool { left.valid && right.valid }
    private enum CodingKeys: String, CodingKey { case left, right, gains }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.gains) {
            let shared = try EQCurve(from: decoder)
            left = shared; right = shared
        } else {
            left = try container.decode(EQCurve.self, forKey: .left)
            right = try container.decode(EQCurve.self, forKey: .right)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(left, forKey: .left); try container.encode(right, forKey: .right)
    }
}

public struct StereoGain: Equatable, Sendable {
    public let left: Double
    public let right: Double
}

public extension StereoEQCurve {
    func playbackGain(rate: Double, alongside comparisons: [StereoEQCurve] = [], margin: Double = 6) -> StereoGain {
        let channels = ([self] + comparisons).flatMap { [$0.left, $0.right] }
        let means = channels.map { curve in
            EQCurve.grid.map { curve.response(at: $0, rate: rate) }.reduce(0,+) / Double(EQCurve.grid.count)
        }
        let ceiling = zip(channels, means).map { curve, mean in
            max(-mean, -curve.normalizedGain(rate: rate, margin: 0) - mean)
        }.max() ?? 0
        // One centered level for both ears and every candidate; neither preamp can boost.
        return StereoGain(left: -means[0] - ceiling - margin, right: -means[1] - ceiling - margin)
    }
}

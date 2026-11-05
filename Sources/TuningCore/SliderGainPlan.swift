import Foundation

public struct SliderGainPlan {
    private let ceiling: Double
    private let rate: Double
    public init(comparison: SliderComparison, rate: Double) {
        self.rate = rate
        ceiling = (0...8).map { i in
            Self.levels(comparison.curve(at: Double(i) / 4 - 1), rate: rate).ceiling
        }.max()! + 0.5
    }
    public func gain(for curve: StereoEQCurve) -> StereoGain {
        let levels = Self.levels(curve, rate: rate)
        // Recheck the selected curve; interpolation can peak between sampled positions.
        let safeCeiling = max(ceiling, levels.ceiling)
        return StereoGain(left: -levels.left - safeCeiling - 6, right: -levels.right - safeCeiling - 6)
    }
    private static func levels(_ curve: StereoEQCurve, rate: Double) -> (left: Double, right: Double, ceiling: Double) {
        let channels = [curve.left, curve.right]
        let means = channels.map { channel in
            EQCurve.grid.map { channel.response(at: $0, rate: rate) }.reduce(0, +) / Double(EQCurve.grid.count)
        }
        let ceiling = zip(channels, means).map { channel, mean in
            max(-mean, -channel.normalizedGain(rate: rate, margin: 0) - mean)
        }.max()!
        return (means[0], means[1], ceiling)
    }
}

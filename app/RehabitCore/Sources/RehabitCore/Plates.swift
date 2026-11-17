import Foundation

/// Which plates go on each end of a bar to make a weight.
public struct PlateLoad: Equatable, Sendable {
    /// The plates on one end, heaviest first.
    public let perSide: [Double]
    /// The weight this makes with the bar, which is the weight asked for
    /// whenever the plates can make it.
    public let total: Double
    /// What could not be made with the plates there are: asked for minus `total`.
    public let short: Double
}

public enum Plates {
    public static func standard(_ unit: WeightUnit) -> [Double] {
        unit == .lb ? [45, 35, 25, 10, 5, 2.5] : [25, 20, 15, 10, 5, 2.5, 1.25]
    }

    public static func bar(_ unit: WeightUnit) -> Double { unit == .lb ? 45 : 20 }

    /// The fewest plates per end for a total weight on a bar: the heaviest
    /// plate that fits, again and again. A total below the bar needs none.
    public static func load(total: Double, bar: Double, plates: [Double]) -> PlateLoad {
        guard total.isFinite, bar.isFinite, total > bar else {
            return PlateLoad(perSide: [], total: max(0, bar.isFinite ? bar : 0), short: total.isFinite && bar.isFinite ? min(0, total - bar) : 0)
        }
        var left = (total - bar) / 2
        var out: [Double] = []
        for plate in plates.filter({ $0 > 0 && $0.isFinite }).sorted(by: >) {
            while left >= plate - 1e-9 && out.count < 40 {
                out.append(plate)
                left -= plate
            }
        }
        let made = bar + 2 * out.reduce(0, +)
        return PlateLoad(perSide: out, total: made, short: ((total - made) * 1000).rounded() / 1000)
    }

    public static func load(total: Double, unit: WeightUnit) -> PlateLoad {
        load(total: total, bar: bar(unit), plates: standard(unit))
    }
}

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

    /// The plates per end for a total weight on a bar: the heaviest plate
    /// that fits, again and again, as a bar is usually loaded. Where that
    /// falls short and another choice of plates is exact (15 + 15 where a 20
    /// leaves 10 unmade), the exact one with the fewest plates is given. A
    /// total below the bar needs none.
    public static func load(total: Double, bar: Double, plates: [Double]) -> PlateLoad {
        guard total.isFinite, bar.isFinite, total > bar else {
            return PlateLoad(perSide: [], total: max(0, bar.isFinite ? bar : 0), short: total.isFinite && bar.isFinite ? min(0, total - bar) : 0)
        }
        let sizes = plates.filter { $0 > 0 && $0.isFinite }.sorted(by: >)
        let perEnd = (total - bar) / 2
        var left = perEnd
        var out: [Double] = []
        for plate in sizes {
            while left >= plate - 1e-9 && out.count < 40 {
                out.append(plate)
                left -= plate
            }
        }
        // In hundredths, so the sums are exact.
        let target = Int((perEnd * 100).rounded()), units = sizes.map { Int(($0 * 100).rounded()) }
        if left > 0.005, target <= 200_000, !units.contains(0) {
            // Fewest plates for each amount up to the target.
            var count = [Int](repeating: Int.max, count: target + 1), last = [Int](repeating: -1, count: target + 1)
            count[0] = 0
            for amount in 1...max(1, target) where amount <= target {
                for (i, unit) in units.enumerated() where unit <= amount && count[amount - unit] != Int.max
                    && count[amount - unit] + 1 < count[amount] {
                    count[amount] = count[amount - unit] + 1
                    last[amount] = i
                }
            }
            if count[target] != Int.max, count[target] <= 40 {
                var exact: [Double] = [], amount = target
                while amount > 0, last[amount] >= 0 {
                    exact.append(sizes[last[amount]])
                    amount -= units[last[amount]]
                }
                out = exact.sorted(by: >)
            }
        }
        let made = bar + 2 * out.reduce(0, +)
        return PlateLoad(perSide: out, total: made, short: ((total - made) * 1000).rounded() / 1000)
    }

    public static func load(total: Double, unit: WeightUnit) -> PlateLoad {
        load(total: total, bar: bar(unit), plates: standard(unit))
    }
}

import Foundation

/// Which plates to load on each side of the bar for a target weight.
/// Greedy from the heaviest plate, which is optimal for standard plate sets.
public struct PlateCalculator: Sendable {
    /// Empty bar weight, in the plates' unit.
    public var bar: Double
    /// Plate weights available (any order), each assumed to come in pairs.
    public var plates: [Double]

    public init(bar: Double, plates: [Double]) {
        self.bar = bar
        self.plates = plates.sorted(by: >)
    }

    public static let kilograms = PlateCalculator(bar: 20, plates: [25, 20, 15, 10, 5, 2.5, 1.25])
    public static let pounds = PlateCalculator(bar: 45, plates: [45, 35, 25, 10, 5, 2.5])

    public struct Load: Equatable, Sendable {
        /// Plates for one side, heaviest first.
        public var perSide: [Double]
        /// The weight these plates actually make (bar included).
        public var total: Double
        /// True when the target can't be made exactly with these plates.
        public var isApproximate: Bool
    }

    /// The load for `target` (same unit as the bar). Below the bar: just the bar.
    public func load(for target: Double) -> Load {
        var remaining = max(0, (target - bar) / 2)
        var perSide: [Double] = []
        for plate in plates where plate > 0 {
            while remaining + 1e-9 >= plate {
                perSide.append(plate)
                remaining -= plate
            }
        }
        let total = bar + 2 * perSide.reduce(0, +)
        return Load(perSide: perSide, total: total, isApproximate: abs(total - max(target, bar)) > 1e-6)
    }
}

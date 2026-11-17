import Foundation

/// One tissue and side over a week, in detail: for the body map's sheet.
public struct TissueDetail: Equatable, Sendable {
    public struct Contribution: Equatable, Sendable {
        public let exercise: String
        /// Effective reps this exercise put on the tissue in the week.
        public let dose: Double
    }
    public let tissue: String
    public let side: Side
    public let weekEnding: Day
    /// Dose in each of the five weeks up to `weekEnding`, oldest first. The
    /// last is the week itself; the four before it make the usual week.
    public let weekly: [Double]
    public let contributions: [Contribution]
    /// How many of the 28 days before the week have any history behind them.
    public var priorDays = 28

    public var week: Double { weekly.last ?? 0 }
    /// The four weeks before as a weekly rate over the days there is history for.
    public var usualWeek: Double { priorDays >= 7 ? weekly.dropLast().reduce(0, +) * 7 / Double(priorDays) : 0 }
    public var ratio: Double? { usualWeek > 0 ? week / usualWeek : nil }
}

/// The two ways the body map can be coloured.
public enum HeatReading: String, CaseIterable, Sendable {
    /// This week's dose, from faint to strong, against the most-loaded tissue.
    case thisWeek
    /// This week against the usual week, on a scale centred on 1×.
    case versusUsual
}

/// What colour a region gets. No load is never shown as the lowest colour,
/// and a tissue with nothing to compare against is never an extreme one.
public enum HeatLevel: Equatable, Sendable {
    /// No load this week: an empty outline.
    case empty
    /// Loaded this week with nothing in the four weeks before: no ratio.
    case new
    /// This week: 0 (just above nothing) to 1 (the most-loaded tissue).
    /// Versus usual: -1 (half a usual week or less) through 0 (usual) to 1 (double or more).
    case value(Double)

    public init(_ week: TissueWeek?, reading: HeatReading, maxWeek: Double) {
        guard let week, week.week > 0 else { self = .empty; return }
        switch reading {
        case .thisWeek:
            self = .value(maxWeek > 0 ? min(1, week.week / maxWeek) : 1)
        case .versusUsual:
            guard let ratio = week.ratio else { self = .new; return }
            self = .value(HeatLevel.position(ofRatio: ratio))
        }
    }

    /// Where a ratio sits on the versus-usual scale: the base-2 logarithm,
    /// clamped, so 0.5× is -1, 1× is 0 and 2× or more is 1.
    public static func position(ofRatio ratio: Double) -> Double {
        guard ratio > 0, ratio.isFinite else { return ratio > 0 ? 1 : -1 }
        return min(1, max(-1, log2(ratio)))
    }
}

/// Which way a figure faces.
public enum BodyView: String, CaseIterable, Sendable {
    /// Facing the viewer: the person's left is on the viewer's right.
    case front
    /// Seen from behind: the person's left is on the viewer's left.
    case back

    /// The side of the body drawn on the viewer's left (`true`) or right half.
    public func side(onViewerLeft: Bool) -> Side {
        switch self {
        case .front: return onViewerLeft ? .right : .left
        case .back: return onViewerLeft ? .left : .right
        }
    }

    /// Which half of the figure a side of the body is drawn on.
    public func isOnViewerLeft(_ side: Side) -> Bool { self.side(onViewerLeft: true) == side }
}

/// An ellipse in figure units (the figure is `BodyMap.size`), drawn on the
/// viewer's left half and mirrored across the centre line for the other half.
public struct BodyShape: Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    /// Degrees clockwise, for the viewer's left half; mirrored for the right.
    public let rotation: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double, rotation: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.rotation = rotation
    }
    /// The same shape on the other half of the figure.
    public var mirrored: BodyShape {
        BodyShape(BodyMap.size.width - x, y, width, height, rotation: -rotation)
    }
}

public struct BodyRegion: Equatable, Sendable {
    public let tissue: String
    public let view: BodyView
    public let shape: BodyShape
    /// Tendons are drawn smaller and with a distinct outline.
    public let isTendon: Bool
}

/// The stylised figures: a neutral silhouette and a shape per tissue, defined
/// once for the viewer's left half and mirrored, so the sides are exact.
public enum BodyMap {
    public static let size = (width: 200.0, height: 460.0)

    /// The silhouette, shared by both views (left half; mirror for the right).
    /// Head and neck sit on the centre line and are drawn once.
    public static let centre: [BodyShape] = [
        BodyShape(100, 32, 38, 46),            // head
        BodyShape(100, 62, 22, 22),            // neck
        BodyShape(100, 128, 82, 132),          // chest and belly
        BodyShape(100, 214, 78, 62),           // pelvis
    ]
    public static let half: [BodyShape] = [
        BodyShape(66, 84, 34, 30, rotation: -25),   // shoulder
        BodyShape(52, 128, 24, 76, rotation: 10),   // upper arm
        BodyShape(41, 198, 20, 74, rotation: 8),    // forearm
        BodyShape(35, 246, 16, 26, rotation: 8),    // hand
        BodyShape(81, 292, 38, 120, rotation: 3),   // thigh
        BodyShape(79, 386, 26, 92, rotation: 1),    // shin and calf
        BodyShape(78, 440, 22, 18),                 // foot
    ]

    private static func r(_ tissue: String, _ view: BodyView, _ shape: BodyShape, tendon: Bool = false) -> BodyRegion {
        BodyRegion(tissue: tissue, view: view, shape: shape, isTendon: tendon)
    }

    /// Every tissue's shapes, for the viewer's left half.
    public static let regions: [BodyRegion] = [
        // Front
        r("pec_major", .front, BodyShape(82, 102, 34, 26, rotation: -6)),
        r("front_delt", .front, BodyShape(63, 88, 14, 24, rotation: 18)),
        r("side_delt", .front, BodyShape(50, 93, 8, 22, rotation: 14)),
        r("biceps", .front, BodyShape(51, 128, 15, 46, rotation: 10)),
        r("forearm", .front, BodyShape(42, 194, 14, 52, rotation: 8)),
        r("abs", .front, BodyShape(92.5, 154, 13, 66)),
        r("obliques", .front, BodyShape(74, 160, 11, 48, rotation: -6)),
        r("hip_flexors", .front, BodyShape(84, 222, 12, 24, rotation: 28)),
        r("adductors", .front, BodyShape(95, 272, 8, 44, rotation: -6)),
        r("quads", .front, BodyShape(78, 292, 22, 92, rotation: 3)),
        r("patellar_tendon", .front, BodyShape(80, 349, 7, 13), tendon: true),
        // Back
        r("upper_traps", .back, BodyShape(84, 76, 26, 15, rotation: 22)),
        r("rear_delt", .back, BodyShape(63, 88, 14, 24, rotation: 18)),
        r("side_delt", .back, BodyShape(50, 93, 8, 22, rotation: 14)),
        r("rotator_cuff", .back, BodyShape(76, 104, 15, 17, rotation: -10)),
        r("mid_back", .back, BodyShape(91, 104, 11, 30)),
        r("lats", .back, BodyShape(77, 142, 20, 52, rotation: -12)),
        r("erectors", .back, BodyShape(93, 172, 9, 54)),
        r("triceps", .back, BodyShape(51, 128, 15, 46, rotation: 10)),
        r("forearm", .back, BodyShape(42, 194, 14, 52, rotation: 8)),
        r("glute_med", .back, BodyShape(72, 206, 16, 16, rotation: -20)),
        r("glute_max", .back, BodyShape(84, 228, 28, 30)),
        r("hamstrings", .back, BodyShape(80, 298, 22, 84, rotation: 3)),
        r("calf", .back, BodyShape(79, 372, 20, 56, rotation: 1)),
        r("achilles", .back, BodyShape(79, 417, 6, 22), tendon: true),
    ]

    public static func regions(_ view: BodyView) -> [BodyRegion] { regions.filter { $0.view == view } }
}

extension AppModel {
    /// False until there are two weeks of sets or steps: before that there is
    /// no usual week to compare with, and "new" on every tissue would say nothing.
    public var hasUsualWeek: Bool {
        _ = tick
        let today = Day(clock, in: localZone)
        guard let first = firstRecordedDay else { return false }
        return today.days(since: first) >= 14
    }

    /// The week for one tissue on one side. The ledger files a set done with
    /// both sides under each side, so a "both" entry only appears in data from
    /// elsewhere; when it does, it counts for either side.
    public func tissueWeek(_ tissue: String, side: Side, in weeks: [TissueWeek]) -> TissueWeek? {
        weeks.first { $0.tissue.id == tissue && $0.side == side }
            ?? weeks.first { $0.tissue.id == tissue && $0.side == .both }
    }
}

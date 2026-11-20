import Foundation

public struct Tissue: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let region: String
}

/// A movement pattern and the share of it that each tissue carries.
public struct Pattern: Codable, Identifiable, Hashable, Sendable {
    public struct Link: Codable, Hashable, Sendable {
        public let tissue: String
        /// 1.0 for a prime mover, less for a tissue that assists or stabilises.
        public let share: Double
        public let role: String
    }
    public let id: String
    public let name: String
    /// Fraction of body weight moved per rep when no load is added.
    public let bodyweightShare: Double
    public let links: [Link]
}

/// A named exercise in the picker.
public struct CatalogueExercise: Codable, Hashable, Sendable {
    public let name: String
    public let pattern: String
    public let convention: LoadConvention
    public let unilateral: Bool
    /// Counted in reps, or held for time (an isometric).
    public let kind: SetKind

    public init(name: String, pattern: String, convention: LoadConvention, unilateral: Bool, kind: SetKind = .reps) {
        self.name = name; self.pattern = pattern; self.convention = convention; self.unilateral = unilateral
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case name, pattern, convention, unilateral, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        pattern = try c.decode(String.self, forKey: .pattern)
        convention = try c.decode(LoadConvention.self, forKey: .convention)
        unilateral = try c.decode(Bool.self, forKey: .unilateral)
        kind = (try? c.decodeIfPresent(SetKind.self, forKey: .kind)) ?? .reps
    }
}

/// The tissue and exercise library. It is written by the service
/// (`rehabit export-shared`) so the phone and the service use the same shares.
public struct Library: Codable, Sendable {
    public let tissues: [Tissue]
    public let patterns: [Pattern]
    public let catalogue: [CatalogueExercise]
    /// Rules that map another app's exercise name to a pattern: a regular
    /// expression and a pattern id each, first match wins.
    public let matchers: [[String]]
    /// Recorded activities (a ride, a row, a run): effective reps a minute at a
    /// moderate effort for each activity pattern (`library.ACTIVITIES` in the service).
    public let activityRates: [String: Double]
    /// For activities on foot: how many walking steps one step counts as on the
    /// pattern's prime tissues, used when a recording gives its steps.
    public let activityPerStep: [String: Double]
    /// Rules that name a recorded activity's pattern from its type, then its name:
    /// a regular expression and a pattern id each, first match wins, an empty id
    /// meaning "adds nothing".
    public let activityMatchers: [[String]]
    private let patternIndex: [String: Pattern]
    private let tissueIndex: [String: Tissue]

    /// The movement patterns a logged exercise can have: all but walking, which
    /// is worked out from daily steps, and the recorded activities, which come
    /// from a watch. Neither is ever logged as a set.
    public var exercisePatterns: [Pattern] {
        patterns.filter { $0.id != Ledger.walkingPattern && !isActivity($0.id) }
    }

    /// True for the pattern of a recorded activity such as cycling or rowing.
    public func isActivity(_ pattern: String?) -> Bool { pattern.map { activityRates[$0] != nil } ?? false }

    private struct ActivityRate: Codable { let pattern: String; let perMinute: Double; let perStep: Double? }

    private enum CodingKeys: String, CodingKey { case tissues, patterns, catalogue, matchers, activities, activityMatchers }

    public init(tissues: [Tissue], patterns: [Pattern], catalogue: [CatalogueExercise], matchers: [[String]] = [],
                activityRates: [String: Double] = [:], activityMatchers: [[String]] = [],
                activityPerStep: [String: Double] = [:]) {
        self.tissues = tissues; self.patterns = patterns; self.catalogue = catalogue; self.matchers = matchers
        self.activityRates = activityRates; self.activityMatchers = activityMatchers
        self.activityPerStep = activityPerStep
        patternIndex = Dictionary(patterns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tissueIndex = Dictionary(tissues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rates = ((try? c.decodeIfPresent([ActivityRate].self, forKey: .activities)) ?? [])
            .filter { $0.perMinute.isFinite && $0.perMinute > 0 }
        self.init(tissues: try c.decode([Tissue].self, forKey: .tissues),
                  patterns: try c.decode([Pattern].self, forKey: .patterns),
                  catalogue: try c.decode([CatalogueExercise].self, forKey: .catalogue),
                  matchers: (try? c.decodeIfPresent([[String]].self, forKey: .matchers)) ?? [],
                  activityRates: Dictionary(rates.map { ($0.pattern, $0.perMinute) }, uniquingKeysWith: { first, _ in first }),
                  activityMatchers: (try? c.decodeIfPresent([[String]].self, forKey: .activityMatchers)) ?? [],
                  activityPerStep: Dictionary(rates.compactMap { r in r.perStep.flatMap { $0.isFinite && $0 >= 1 ? (r.pattern, $0) : nil } },
                                              uniquingKeysWith: { first, _ in first }))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tissues, forKey: .tissues)
        try c.encode(patterns, forKey: .patterns)
        try c.encode(catalogue, forKey: .catalogue)
        try c.encode(matchers, forKey: .matchers)
        try c.encode(activityRates.sorted { $0.key < $1.key }
                        .map { ActivityRate(pattern: $0.key, perMinute: $0.value, perStep: activityPerStep[$0.key]) },
                     forKey: .activities)
        try c.encode(activityMatchers, forKey: .activityMatchers)
    }

    public static let standard: Library = {
        guard let url = Bundle.module.url(forResource: "library", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(Library.self, from: data)
        else { fatalError("library.json is missing or unreadable") }
        return library
    }()

    public func pattern(_ id: String?) -> Pattern? {
        guard let id else { return nil }
        return patternIndex[id]
    }

    public func tissue(_ id: String) -> Tissue? { tissueIndex[id] }

    public func search(_ text: String) -> [CatalogueExercise] {
        let words = text.lowercased().split(separator: " ")
        guard !words.isEmpty else { return catalogue }
        return catalogue.filter { entry in
            let name = entry.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }
}

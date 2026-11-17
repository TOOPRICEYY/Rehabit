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
    private let patternIndex: [String: Pattern]
    private let tissueIndex: [String: Tissue]

    /// The movement patterns a logged exercise can have: all but walking,
    /// which is worked out from daily steps and never logged as a set.
    public var exercisePatterns: [Pattern] { patterns.filter { $0.id != Ledger.walkingPattern } }

    private enum CodingKeys: String, CodingKey { case tissues, patterns, catalogue, matchers }

    public init(tissues: [Tissue], patterns: [Pattern], catalogue: [CatalogueExercise], matchers: [[String]] = []) {
        self.tissues = tissues; self.patterns = patterns; self.catalogue = catalogue; self.matchers = matchers
        patternIndex = Dictionary(patterns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tissueIndex = Dictionary(tissues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tissues: try c.decode([Tissue].self, forKey: .tissues),
                  patterns: try c.decode([Pattern].self, forKey: .patterns),
                  catalogue: try c.decode([CatalogueExercise].self, forKey: .catalogue),
                  matchers: (try? c.decodeIfPresent([[String]].self, forKey: .matchers)) ?? [])
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

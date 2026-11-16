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

    public init(name: String, pattern: String, convention: LoadConvention, unilateral: Bool) {
        self.name = name; self.pattern = pattern; self.convention = convention; self.unilateral = unilateral
    }
}

/// The tissue and exercise library. It is written by the service
/// (`rehabit export-shared`) so the phone and the service use the same shares.
public struct Library: Codable, Sendable {
    public let tissues: [Tissue]
    public let patterns: [Pattern]
    public let catalogue: [CatalogueExercise]

    public static let standard: Library = {
        guard let url = Bundle.module.url(forResource: "library", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(Library.self, from: data)
        else { fatalError("library.json is missing or unreadable") }
        return library
    }()

    public func pattern(_ id: String?) -> Pattern? {
        guard let id else { return nil }
        return patterns.first { $0.id == id }
    }

    public func tissue(_ id: String) -> Tissue? { tissues.first { $0.id == id } }

    public func search(_ text: String) -> [CatalogueExercise] {
        let words = text.lowercased().split(separator: " ")
        guard !words.isEmpty else { return catalogue }
        return catalogue.filter { entry in
            let name = entry.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }
}

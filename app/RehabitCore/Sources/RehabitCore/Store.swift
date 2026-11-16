import Foundation

/// A copy of everything in the store, as one JSON document. This is the file
/// that goes to iCloud and to the private repository, and what the service on
/// the Mac reads. A deleted record is kept as a tombstone (id and time only) so
/// that a deletion reaches other devices and is not undone by an older copy.
public struct Snapshot: Codable, Sendable {
    public struct Tombstone: Codable, Sendable, Equatable {
        public let kind: String
        public let id: String
        public let deletedAt: Date
    }
    public static let currentSchemaVersion = 1
    public var schemaVersion = Snapshot.currentSchemaVersion
    public var exportedAt: Date
    public var profile: Profile
    public var workouts: [Workout]
    public var sets: [WorkoutSet]
    public var injuries: [Injury]
    public var painChecks: [PainCheck]
    public var dailyMetrics: [DailyMetric]
    public var tombstones: [Tombstone]
}

/// Local storage. Each record is kept as JSON beside the few columns needed to
/// find it (kind, parent, day) and to merge it (updated time, deleted flag).
/// A personal log is a few thousand small records, so this stays fast, and a
/// new field on a record needs no migration.
public final class Store {
    private let db: Database
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(path: String) throws {
        db = try Database(path: path)
        try db.run("""
            CREATE TABLE IF NOT EXISTS record (
              kind TEXT NOT NULL, id TEXT NOT NULL, parent_id TEXT, day TEXT,
              updated_at REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, body TEXT NOT NULL,
              PRIMARY KEY (kind, id))
            """)
        try db.run("CREATE INDEX IF NOT EXISTS record_parent ON record(kind, parent_id)")
        try db.run("""
            CREATE TABLE IF NOT EXISTS daily_metric (
              day TEXT NOT NULL, metric TEXT NOT NULL, value REAL NOT NULL, source TEXT NOT NULL,
              PRIMARY KEY (day, metric, source))
            """)
        try db.run("CREATE TABLE IF NOT EXISTS setting (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    // MARK: Records

    /// Inserts or replaces a record. It is the caller's job to set `updatedAt`.
    public func save<R: Record>(_ record: R) throws {
        let body = String(decoding: try Store.encoder.encode(record), as: UTF8.self)
        try db.run("""
            INSERT OR REPLACE INTO record(kind, id, parent_id, day, updated_at, deleted, body)
            VALUES (?,?,?,?,?,0,?)
            """, [.text(R.kind), .text(record.id), record.parentID.map(SQLValue.text) ?? .null,
                  record.day.map { .text($0.description) } ?? .null,
                  .real(record.updatedAt.timeIntervalSince1970), .text(body)])
    }

    public func all<R: Record>(_ type: R.Type, parent: String? = nil) throws -> [R] {
        var sql = "SELECT body FROM record WHERE kind = ? AND deleted = 0"
        var values: [SQLValue] = [.text(R.kind)]
        if let parent {
            sql += " AND parent_id = ?"
            values.append(.text(parent))
        }
        return try db.run(sql + " ORDER BY day, updated_at, id", values).compactMap { row in
            row["body"]?.string.flatMap { try? Store.decoder.decode(R.self, from: Data($0.utf8)) }
        }
    }

    public func find<R: Record>(_ type: R.Type, id: String) throws -> R? {
        try db.run("SELECT body FROM record WHERE kind = ? AND id = ? AND deleted = 0",
                   [.text(R.kind), .text(id)]).first?["body"]?.string
            .flatMap { try? Store.decoder.decode(R.self, from: Data($0.utf8)) }
    }

    /// Marks a record deleted. The row stays as a tombstone.
    public func delete<R: Record>(_ type: R.Type, id: String, at time: Date = Date()) throws {
        try db.run("UPDATE record SET deleted = 1, updated_at = ?, body = '{}' WHERE kind = ? AND id = ?",
                   [.real(time.timeIntervalSince1970), .text(R.kind), .text(id)])
    }

    /// Deletes a workout together with its sets.
    public func deleteWorkout(id: String, at time: Date = Date()) throws {
        try db.transaction {
            for set in try all(WorkoutSet.self, parent: id) {
                try delete(WorkoutSet.self, id: set.id, at: time)
            }
            try delete(Workout.self, id: id, at: time)
        }
    }

    // MARK: Profile and daily metrics

    public var profile: Profile {
        get {
            let text = (try? db.run("SELECT value FROM setting WHERE key = 'profile'"))?.first?["value"]?.string
            return text.flatMap { try? Store.decoder.decode(Profile.self, from: Data($0.utf8)) } ?? Profile()
        }
        set {
            guard let data = try? Store.encoder.encode(newValue) else { return }
            _ = try? db.run("INSERT OR REPLACE INTO setting(key, value) VALUES ('profile', ?)",
                            [.text(String(decoding: data, as: UTF8.self))])
        }
    }

    public func save(_ metrics: [DailyMetric]) throws {
        try db.transaction {
            for m in metrics {
                try db.run("INSERT OR REPLACE INTO daily_metric(day, metric, value, source) VALUES (?,?,?,?)",
                           [.text(m.day.description), .text(m.metric), .real(m.value), .text(m.source)])
            }
        }
    }

    public func dailyMetrics(_ metric: String? = nil) throws -> [DailyMetric] {
        let rows = try metric.map {
            try db.run("SELECT * FROM daily_metric WHERE metric = ? ORDER BY day", [.text($0)])
        } ?? db.run("SELECT * FROM daily_metric ORDER BY day, metric")
        return rows.compactMap { row in
            guard let day = row["day"]?.string.flatMap(Day.init), let name = row["metric"]?.string,
                  let value = row["value"]?.double, let source = row["source"]?.string else { return nil }
            return DailyMetric(day: day, metric: name, value: value, source: source)
        }
    }

    // MARK: Snapshot and merge

    public func snapshot(at time: Date = Date()) throws -> Snapshot {
        let tombstones = try db.run("SELECT kind, id, updated_at FROM record WHERE deleted = 1 ORDER BY kind, id")
            .compactMap { row -> Snapshot.Tombstone? in
                guard let kind = row["kind"]?.string, let id = row["id"]?.string,
                      let t = row["updated_at"]?.double else { return nil }
                return .init(kind: kind, id: id, deletedAt: Date(timeIntervalSince1970: t))
            }
        return Snapshot(exportedAt: time, profile: profile, workouts: try all(Workout.self),
                        sets: try all(WorkoutSet.self), injuries: try all(Injury.self),
                        painChecks: try all(PainCheck.self), dailyMetrics: try dailyMetrics(),
                        tombstones: tombstones)
    }

    public func snapshotJSON(at time: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(try snapshot(at: time))
    }

    public static func decodeSnapshot(_ data: Data) throws -> Snapshot {
        try decoder.decode(Snapshot.self, from: data)
    }

    private func updatedAt(kind: String, id: String) throws -> Double? {
        try db.run("SELECT updated_at FROM record WHERE kind = ? AND id = ?", [.text(kind), .text(id)])
            .first?["updated_at"]?.double
    }

    /// Brings in another device's snapshot. For each record the newer change
    /// wins, whether that change was an edit or a deletion. Returns how many
    /// records changed here.
    @discardableResult
    public func merge(_ other: Snapshot) throws -> Int {
        var changed = 0
        func take<R: Record>(_ records: [R]) throws {
            for record in records {
                let mine = try updatedAt(kind: R.kind, id: record.id)
                if mine == nil || mine! < record.updatedAt.timeIntervalSince1970 {
                    try save(record)
                    changed += 1
                }
            }
        }
        try db.transaction {
            try take(other.workouts)
            try take(other.sets)
            try take(other.injuries)
            try take(other.painChecks)
            for stone in other.tombstones {
                let theirs = stone.deletedAt.timeIntervalSince1970
                let mine = try updatedAt(kind: stone.kind, id: stone.id)
                if mine == nil || mine! < theirs {
                    try db.run("""
                        INSERT OR REPLACE INTO record(kind, id, parent_id, day, updated_at, deleted, body)
                        VALUES (?,?,NULL,NULL,?,1,'{}')
                        """, [.text(stone.kind), .text(stone.id), .real(theirs)])
                    changed += 1
                }
            }
        }
        try save(other.dailyMetrics)
        return changed
    }
}

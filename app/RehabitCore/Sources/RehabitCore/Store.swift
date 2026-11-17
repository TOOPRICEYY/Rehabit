import Foundation

/// A record this version of the app cannot read, carried as it was found. It is
/// most likely from a newer version. It stays in the database and in every
/// export, so an older phone never loses what a newer one wrote.
public struct RawRecord: Codable, Sendable, Equatable {
    public let kind: String
    public let id: String
    public let parentID: String?
    public let day: String?
    public let updatedAt: Date
    /// The record's JSON, untouched.
    public let body: String
}

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
    /// When the profile was last changed, so the newer one wins between devices.
    public var profileUpdatedAt: Date?
    public var workouts: [Workout]
    public var sets: [WorkoutSet]
    public var injuries: [Injury]
    public var painChecks: [PainCheck]
    public var dailyMetrics: [DailyMetric]
    public var tombstones: [Tombstone]
    public var unreadable: [RawRecord] = []

    public init(schemaVersion: Int = Snapshot.currentSchemaVersion, exportedAt: Date, profile: Profile,
                profileUpdatedAt: Date? = nil, workouts: [Workout], sets: [WorkoutSet], injuries: [Injury],
                painChecks: [PainCheck], dailyMetrics: [DailyMetric], tombstones: [Tombstone],
                unreadable: [RawRecord] = []) {
        self.schemaVersion = schemaVersion; self.exportedAt = exportedAt; self.profile = profile
        self.profileUpdatedAt = profileUpdatedAt; self.workouts = workouts; self.sets = sets
        self.injuries = injuries; self.painChecks = painChecks; self.dailyMetrics = dailyMetrics
        self.tombstones = tombstones; self.unreadable = unreadable
    }
}

/// Times are kept to the millisecond everywhere: in the database, in the JSON
/// and in every comparison. If the three disagreed, two devices could each
/// believe their own copy of a record was the newer one and never settle.
enum Stamp {
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    private static let fallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fallbackWhole = ISO8601DateFormatter()

    /// 2026-11-16T21:05:32.250Z. Written by hand because the system formatter
    /// is slow enough to dominate an export of a few thousand records.
    static func text(_ date: Date) -> String {
        let ms = millis(date)
        let dayNumber = Int((ms >= 0 ? ms : ms - 86_399_999) / 86_400_000)
        var rest = Int(ms - Int64(dayNumber) * 86_400_000)
        let fraction = rest % 1000; rest /= 1000
        let second = rest % 60; rest /= 60
        func pad(_ n: Int, _ width: Int) -> String {
            let s = String(n)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(Day(number: dayNumber))T\(pad(rest / 60, 2)):\(pad(rest % 60, 2)):\(pad(second, 2)).\(pad(fraction, 3))Z"
    }

    /// Reads a time with or without a fraction of a second.
    static func parse(_ text: String) -> Date? {
        // The common shape, in UTC, is read directly; anything else goes to the system parser.
        let bytes = Array(text.utf8)
        if bytes.count >= 20, bytes.last == UInt8(ascii: "Z"), bytes[10] == UInt8(ascii: "T"),
           let day = Day(String(decoding: bytes[0..<10], as: UTF8.self)) {
            func number(_ range: Range<Int>) -> Int? {
                var value = 0
                for b in bytes[range] {
                    guard b >= 48, b <= 57 else { return nil }
                    value = value * 10 + Int(b - 48)
                }
                return value
            }
            if bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
               let h = number(11..<13), let m = number(14..<16), let s = number(17..<19), h < 24, m < 60, s < 60 {
                var fraction = 0
                var ok = bytes.count == 20
                if bytes.count > 21, bytes[19] == UInt8(ascii: "."), let digits = number(20..<(bytes.count - 1)) {
                    let count = bytes.count - 21
                    fraction = count >= 3 ? digits / Int(pow(10, Double(count - 3))) : digits * Int(pow(10, Double(3 - count)))
                    ok = count <= 9
                }
                if ok {
                    return date(Int64(day.number) * 86_400_000 + Int64((h * 3600 + m * 60 + s) * 1000 + fraction))
                }
            }
        }
        return (fallback.date(from: text) ?? fallbackWhole.date(from: text)).map { date(millis($0)) }
    }

    static let encoding = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(text(date))
    }
    static let decoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let date = parse(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a time: \(value)")
        }
        return date
    }
}

/// Local storage. Each record is kept as JSON beside the few columns needed to
/// find it (kind, parent, day) and to merge it (updated time, deleted flag).
/// A personal log is a few thousand small records, so this stays fast, and a
/// new field on a record needs no migration.
public final class Store {
    private let db: Database
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = Stamp.encoding
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = Stamp.decoding
        return d
    }()
    /// Which record is the parent of which, for the rule that nothing outlives its parent.
    private static let parents = [(child: WorkoutSet.kind, parent: Workout.kind),
                                  (child: PainCheck.kind, parent: Injury.kind)]

    public init(path: String) throws {
        db = try Database(path: path)
        try db.run("""
            CREATE TABLE IF NOT EXISTS record (
              kind TEXT NOT NULL, id TEXT NOT NULL, parent_id TEXT, day TEXT,
              updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, body TEXT NOT NULL,
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

    private struct Row {
        let updated: Int64
        let deleted: Bool
        let body: String
    }

    private func row(kind: String, id: String) throws -> Row? {
        guard let r = try db.run("SELECT updated_at, deleted, body FROM record WHERE kind = ? AND id = ?",
                                 [.text(kind), .text(id)]).first,
              let updated = r["updated_at"]?.double else { return nil }
        return Row(updated: Int64(updated), deleted: r["deleted"]?.int == 1, body: r["body"]?.string ?? "{}")
    }

    private func write(kind: String, id: String, parent: String?, day: String?, updated: Int64,
                       deleted: Bool, body: String) throws {
        try db.run("""
            INSERT OR REPLACE INTO record(kind, id, parent_id, day, updated_at, deleted, body)
            VALUES (?,?,?,?,?,?,?)
            """, [.text(kind), .text(id), parent.map(SQLValue.text) ?? .null, day.map(SQLValue.text) ?? .null,
                  .integer(updated), .integer(deleted ? 1 : 0), .text(body)])
    }

    private func encode<R: Record>(_ record: R) throws -> String {
        String(decoding: try Store.encoder.encode(record), as: UTF8.self)
    }

    /// Inserts or replaces a record. A change made here is always later than
    /// the copy it replaces, even if this device's clock is behind the device
    /// that wrote that copy; otherwise the change would be undone at the next sync.
    public func save<R: Record>(_ record: R) throws {
        var record = record
        if let existing = try row(kind: R.kind, id: record.id), existing.updated >= Stamp.millis(record.updatedAt) {
            record.updatedAt = Stamp.date(existing.updated + 1)
        }
        try write(kind: R.kind, id: record.id, parent: record.parentID, day: record.day?.description,
                  updated: Stamp.millis(record.updatedAt), deleted: false, body: try encode(record))
    }

    /// Stores a workout from another app with its sets, unless a workout with
    /// this id is already here or was deleted here. Returns whether it was stored.
    public func addIfNew(_ workout: Workout, sets: [WorkoutSet]) throws -> Bool {
        if try row(kind: Workout.kind, id: workout.id) != nil { return false }
        try db.transaction {
            try save(workout)
            for set in sets { try save(set) }
        }
        return true
    }

    /// Saves many records as one change: all of them or none.
    public func saveAll<R: Record>(_ records: [R]) throws {
        try db.transaction { for record in records { try save(record) } }
    }

    private func decode<R: Record>(_ type: R.Type, _ body: String?) -> R? {
        body.flatMap { try? Store.decoder.decode(R.self, from: Data($0.utf8)) }
    }

    /// Live records of one type. A record this version cannot read is left out
    /// here but is not lost: see `unreadable()`.
    public func all<R: Record>(_ type: R.Type, parent: String? = nil) throws -> [R] {
        var sql = "SELECT body FROM record WHERE kind = ? AND deleted = 0"
        var values: [SQLValue] = [.text(R.kind)]
        if let parent {
            sql += " AND parent_id = ?"
            values.append(.text(parent))
        }
        return try db.run(sql + " ORDER BY day, updated_at, id", values).compactMap { decode(R.self, $0["body"]?.string) }
    }

    public func find<R: Record>(_ type: R.Type, id: String) throws -> R? {
        guard let row = try row(kind: R.kind, id: id), !row.deleted else { return nil }
        return decode(R.self, row.body)
    }

    /// Every live record of one type in one pass: those that can be read, and those that cannot.
    private func load<R: Record>(_ type: R.Type) throws -> (records: [R], unreadable: [RawRecord]) {
        var records: [R] = [], raws: [RawRecord] = []
        for r in try db.run("SELECT id, parent_id, day, updated_at, body FROM record WHERE kind = ? AND deleted = 0 ORDER BY day, updated_at, id",
                            [.text(R.kind)]) {
            guard let id = r["id"]?.string, let body = r["body"]?.string, let updated = r["updated_at"]?.double else { continue }
            if let record = decode(R.self, body) {
                records.append(record)
            } else {
                raws.append(RawRecord(kind: R.kind, id: id, parentID: r["parent_id"]?.string, day: r["day"]?.string,
                                      updatedAt: Stamp.date(Int64(updated)), body: body))
            }
        }
        return (records, raws)
    }

    /// Live records that could not be read, most likely written by a newer version.
    public func unreadable() throws -> [RawRecord] {
        try load(Workout.self).unreadable + load(WorkoutSet.self).unreadable
            + load(Injury.self).unreadable + load(PainCheck.self).unreadable
    }

    /// Marks a record deleted. The row stays as a tombstone. Deleting something
    /// this device has never held still leaves a tombstone, so an older copy
    /// arriving later is refused.
    public func delete<R: Record>(_ type: R.Type, id: String, at time: Date = Date()) throws {
        try db.transaction {
            let existing = try row(kind: R.kind, id: id)
            if existing?.deleted == true { return }
            let stamp = max(Stamp.millis(time), (existing?.updated ?? Int64.min + 1) + 1)
            try write(kind: R.kind, id: id, parent: nil, day: nil, updated: stamp, deleted: true, body: "{}")
            try removeOrphans()
        }
    }

    /// Deletes a workout together with its sets.
    public func deleteWorkout(id: String, at time: Date = Date()) throws {
        try delete(Workout.self, id: id, at: time)
    }

    /// Nothing outlives its parent: the sets of a deleted workout and the pain
    /// checks of a deleted injury are deleted with it. The time given to each is
    /// worked out from the two records alone, so every device arrives at the
    /// same tombstone whichever order the changes reached it in.
    private func removeOrphans() throws {
        for link in Store.parents {
            try db.run("""
                UPDATE record SET deleted = 1, body = '{}', updated_at = MAX(updated_at,
                    (SELECT p.updated_at FROM record p WHERE p.kind = ? AND p.id = record.parent_id)) + 1
                WHERE kind = ? AND deleted = 0
                  AND parent_id IN (SELECT id FROM record WHERE kind = ? AND deleted = 1)
                """, [.text(link.parent), .text(link.child), .text(link.parent)])
        }
    }

    // MARK: Profile and daily metrics

    private func setting(_ key: String) -> String? {
        (try? db.run("SELECT value FROM setting WHERE key = ?", [.text(key)]))?.first?["value"]?.string
    }

    public var profile: Profile {
        get {
            setting("profile").flatMap { try? Store.decoder.decode(Profile.self, from: Data($0.utf8)) } ?? Profile()
        }
        set { try? setProfile(newValue) }
    }

    public var profileUpdatedAt: Date? {
        setting("profile_updated_at").flatMap { Int64($0) }.map(Stamp.date)
    }

    public func setProfile(_ profile: Profile, at time: Date = Date()) throws {
        let body = String(decoding: try Store.encoder.encode(profile), as: UTF8.self)
        let stamp = max(Stamp.millis(time), (profileUpdatedAt.map(Stamp.millis) ?? Int64.min + 1) + 1)
        try writeProfile(body, stamp: stamp)
    }

    private func writeProfile(_ body: String, stamp: Int64) throws {
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO setting(key, value) VALUES ('profile', ?)", [.text(body)])
            try db.run("INSERT OR REPLACE INTO setting(key, value) VALUES ('profile_updated_at', ?)",
                       [.text(String(stamp))])
        }
    }

    /// Stores a fresh reading from a watch or phone. A value that is not a
    /// number is skipped: that day stays missing, and the rest of the batch is kept.
    public func save(_ metrics: [DailyMetric]) throws {
        try write(metrics, sql: "INSERT OR REPLACE INTO daily_metric(day, metric, value, source) VALUES (?,?,?,?)")
    }

    private func write(_ metrics: [DailyMetric], sql: String) throws {
        try db.transaction {
            for m in metrics where m.value.isFinite {
                try db.run(sql, [.text(m.day.description), .text(m.metric), .real(m.value), .text(m.source)])
            }
        }
    }

    public func dailyMetrics(_ metric: String? = nil) throws -> [DailyMetric] {
        let rows = try metric.map {
            try db.run("SELECT * FROM daily_metric WHERE metric = ? ORDER BY day, source", [.text($0)])
        } ?? db.run("SELECT * FROM daily_metric ORDER BY day, metric, source")
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
                return .init(kind: kind, id: id, deletedAt: Stamp.date(Int64(t)))
            }
        let workouts = try load(Workout.self), sets = try load(WorkoutSet.self)
        let injuries = try load(Injury.self), checks = try load(PainCheck.self)
        return Snapshot(exportedAt: time, profile: profile, profileUpdatedAt: profileUpdatedAt,
                        workouts: workouts.records, sets: sets.records, injuries: injuries.records,
                        painChecks: checks.records, dailyMetrics: try dailyMetrics(), tombstones: tombstones,
                        unreadable: workouts.unreadable + sets.unreadable + injuries.unreadable + checks.unreadable)
    }

    public func snapshotJSON(at time: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = Stamp.encoding
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(try snapshot(at: time))
    }

    /// Reads a snapshot, record by record. A record this version cannot read
    /// is kept as raw JSON; it does not stop the rest of the file from being
    /// read. A file from a newer format is refused outright, because its rules
    /// may differ in ways this version cannot know.
    public static func decodeSnapshot(_ data: Data) throws -> Snapshot {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DatabaseError(description: "the file is not a Rehabit export")
        }
        let version = top["schemaVersion"] as? Int ?? 1
        guard version <= Snapshot.currentSchemaVersion else {
            throw DatabaseError(description: "this export was written by a newer version of Rehabit (format \(version)); update the app to read it")
        }
        func part<T: Decodable>(_ key: String, _ type: T.Type) throws -> T? {
            guard let value = top[key], !(value is NSNull) else { return nil }
            return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        }
        var unreadable = try part("unreadable", [RawRecord].self) ?? []
        func records<R: Record>(_ key: String, _ type: R.Type, parentKey: String?, dayKey: String) -> [R] {
            // Usually every record reads, and the list can be taken in one go.
            if let all = try? part(key, [R].self) { return all }
            var out: [R] = []
            for item in top[key] as? [Any] ?? [] {
                guard let object = item as? [String: Any],
                      let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { continue }
                if let record = try? decoder.decode(R.self, from: body) {
                    out.append(record)
                } else if let id = object["id"] as? String,
                          let updated = (object["updatedAt"] as? String).flatMap(Stamp.parse) {
                    unreadable.append(RawRecord(kind: R.kind, id: id,
                                                parentID: parentKey.flatMap { object[$0] as? String },
                                                day: object[dayKey] as? String, updatedAt: updated,
                                                body: String(decoding: body, as: UTF8.self)))
                }
            }
            return out
        }
        let workouts = records("workouts", Workout.self, parentKey: nil, dayKey: "startDay")
        let sets = records("sets", WorkoutSet.self, parentKey: "workoutID", dayKey: "workoutDay")
        let injuries = records("injuries", Injury.self, parentKey: nil, dayKey: "onset")
        let checks = records("painChecks", PainCheck.self, parentKey: "injuryID", dayKey: "dueDay")
        return Snapshot(schemaVersion: version,
                        exportedAt: try part("exportedAt", Date.self) ?? Date(timeIntervalSince1970: 0),
                        profile: try part("profile", Profile.self) ?? Profile(),
                        profileUpdatedAt: try part("profileUpdatedAt", Date.self),
                        workouts: workouts, sets: sets, injuries: injuries, painChecks: checks,
                        dailyMetrics: try part("dailyMetrics", [DailyMetric].self) ?? [],
                        tombstones: try part("tombstones", [Snapshot.Tombstone].self) ?? [],
                        unreadable: unreadable)
    }

    /// Whether an arriving copy replaces the one held here. The later change
    /// wins. On an exact tie a deletion beats an edit, and between two edits the
    /// one whose text sorts later wins: an arbitrary rule, but one that every
    /// device applies the same way, so they end up agreeing.
    private func arrivingWins(kind: String, id: String, updated: Int64, deleted: Bool, body: String) throws -> Bool {
        guard let mine = try row(kind: kind, id: id) else { return true }
        if updated != mine.updated { return updated > mine.updated }
        if deleted != mine.deleted { return deleted }
        return !deleted && body > mine.body
    }

    /// The records in a list that would add to or replace what is held here.
    public func arriving<R: Record>(_ records: [R]) throws -> [R] {
        try records.filter {
            try arrivingWins(kind: R.kind, id: $0.id, updated: Stamp.millis($0.updatedAt), deleted: false,
                             body: try encode($0))
        }
    }

    /// Brings in another device's snapshot. Returns how many records changed here.
    @discardableResult
    public func merge(_ other: Snapshot) throws -> Int {
        guard other.schemaVersion <= Snapshot.currentSchemaVersion else {
            throw DatabaseError(description: "this export was written by a newer version of Rehabit")
        }
        var changed = 0
        func take<R: Record>(_ records: [R]) throws {
            for record in records {
                let body = try encode(record), updated = Stamp.millis(record.updatedAt)
                if try arrivingWins(kind: R.kind, id: record.id, updated: updated, deleted: false, body: body) {
                    try write(kind: R.kind, id: record.id, parent: record.parentID, day: record.day?.description,
                              updated: updated, deleted: false, body: body)
                    changed += 1
                }
            }
        }
        try db.transaction {
            try take(other.workouts)
            try take(other.sets)
            try take(other.injuries)
            try take(other.painChecks)
            for raw in other.unreadable {
                let updated = Stamp.millis(raw.updatedAt)
                if try arrivingWins(kind: raw.kind, id: raw.id, updated: updated, deleted: false, body: raw.body) {
                    try write(kind: raw.kind, id: raw.id, parent: raw.parentID, day: raw.day, updated: updated,
                              deleted: false, body: raw.body)
                    changed += 1
                }
            }
            for stone in other.tombstones {
                let updated = Stamp.millis(stone.deletedAt)
                if try arrivingWins(kind: stone.kind, id: stone.id, updated: updated, deleted: true, body: "{}") {
                    try write(kind: stone.kind, id: stone.id, parent: nil, day: nil, updated: updated,
                              deleted: true, body: "{}")
                    changed += 1
                }
            }
            try removeOrphans()
        }
        if let theirs = other.profileUpdatedAt.map(Stamp.millis),
           theirs > (profileUpdatedAt.map(Stamp.millis) ?? Int64.min) {
            try writeProfile(String(decoding: try Store.encoder.encode(other.profile), as: UTF8.self), stamp: theirs)
        }
        // Two devices can hold different readings for the same day (a step count
        // read at noon and again at night). The larger is kept on both, so they agree.
        try write(other.dailyMetrics, sql: """
            INSERT INTO daily_metric(day, metric, value, source) VALUES (?,?,?,?)
            ON CONFLICT(day, metric, source) DO UPDATE SET value = MAX(value, excluded.value)
            """)
        return changed
    }
}

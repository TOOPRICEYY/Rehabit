import Foundation

/// The network, reduced to what Garmin needs, so the client can be tested
/// without one. The app supplies an implementation built on URLSession.
public protocol HTTPTransport: Sendable {
    func get(_ url: String, headers: [String: String]) async throws -> HTTPReply
    func post(_ url: String, headers: [String: String]) async throws -> HTTPReply
}

public struct HTTPReply: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public struct GarminError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(description: String) { self.description = description }
}

/// Garmin's Personal API: each person makes a key in their own Garmin Connect
/// account, the key is exchanged for a token that lasts a day, and the token
/// reads that one account. There is no sign-in page and no shared secret, so
/// the key is typed in by the person and kept only on their device.
public actor GarminClient {
    public static let base = "https://personal.connectapi.garmin.com"
    private let key: String
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var token: (value: String, expires: Date)?

    public init(apiKey: String, transport: HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport; self.now = now
    }

    /// The time a token stops working, read from the token itself.
    static func expiry(ofToken token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var text = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        guard let data = Data(base64Encoded: text),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func explain(_ status: Int) -> GarminError {
        switch status {
        case 401, 403: return GarminError(description: "Garmin refused the key. Check that it was pasted whole and has not been deleted in Garmin Connect.")
        case 429: return GarminError(description: "Garmin is limiting requests for now. Try again in a few minutes.")
        default: return GarminError(description: "Garmin answered with error \(status).")
        }
    }

    private func bearer(fresh: Bool = false) async throws -> String {
        // Renewed with an hour to spare, so a long read does not run out part way.
        if !fresh, let token, token.expires.timeIntervalSince(now()) > 3600 { return token.value }
        guard !key.isEmpty else { throw GarminError(description: "No Garmin key has been saved.") }
        let reply = try await transport.post(
            GarminClient.base + "/personalapitoken-service/personal-api/personal-api-key/token",
            headers: ["Authorization": "ApiKey " + key, "Accept": "*/*"])
        guard reply.status == 200 else { throw GarminClient.explain(reply.status) }
        let value = String(decoding: reply.body, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r\t"))
        guard !value.isEmpty else { throw GarminError(description: "Garmin returned an empty token.") }
        token = (value, GarminClient.expiry(ofToken: value) ?? now().addingTimeInterval(2 * 3600))
        return value
    }

    private func json(_ path: String) async throws -> Any {
        var reply = try await transport.get(GarminClient.base + path,
                                            headers: ["Authorization": "Bearer " + (try await bearer()), "Accept": "application/json"])
        if reply.status == 401 {   // the token was revoked or expired early: get a new one once
            reply = try await transport.get(GarminClient.base + path,
                                            headers: ["Authorization": "Bearer " + (try await bearer(fresh: true)), "Accept": "application/json"])
        }
        if reply.status == 204 || (reply.status == 200 && reply.body.isEmpty) { return [Any]() }
        guard reply.status == 200 else { throw GarminClient.explain(reply.status) }
        guard let value = try? JSONSerialization.jsonObject(with: reply.body, options: [.fragmentsAllowed]) else {
            throw GarminError(description: "Garmin sent something that could not be read.")
        }
        return value
    }

    /// Checks that the key works, without reading any data.
    public func verify() async throws { _ = try await bearer(fresh: true) }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !(value is Bool) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func dict(_ value: Any?, _ keys: String...) -> Any? {
        var current = value
        for key in keys { current = (current as? [String: Any])?[key] }
        return current
    }

    /// Steps, resting heart rate, sleep and overnight HRV for a range of days.
    /// A zero from Garmin is a watch that was not worn, not a measurement, so
    /// it is left out and the day stays missing.
    public func dailyMetrics(from: Day, through: Day) async throws -> [DailyMetric] {
        var out: [DailyMetric] = []
        func add(_ entry: Any, _ metric: String, _ value: Double?, scale: Double = 1) {
            guard let text = GarminClient.dict(entry, "calendarDate") as? String, let day = Day(String(text.prefix(10))),
                  let value, value > 0 else { return }
            out.append(DailyMetric(day: day, metric: metric, value: value * scale, source: GarminSource.sourceName))
        }
        var start = from
        while start <= through {   // four weeks at a time keeps each answer small
            let end = min(start.adding(27), through)
            let range = "startDate=\(start)&endDate=\(end)"
            let summaries = try await json("/usersummary-service/v2/dailysummaries?" + range)
            for entry in (GarminClient.dict(summaries, "data") as? [Any]) ?? (summaries as? [Any]) ?? [] {
                add(entry, MetricName.steps, GarminClient.number(GarminClient.dict(entry, "movement", "steps", "value")))
                add(entry, MetricName.restingHeartRate, GarminClient.number(GarminClient.dict(entry, "heartRate", "restingValue")))
            }
            let sleep = try await json("/sleep-service/sleep/dailySleepSummariesByDate?" + range)
            for entry in (sleep as? [Any]) ?? [] {
                add(entry, MetricName.sleepMinutes, GarminClient.number(GarminClient.dict(entry, "sleepTimeSeconds")), scale: 1.0 / 60)
            }
            let hrv = try await json("/hrv-service/hrv/daily/\(start)/\(end)")
            for entry in (GarminClient.dict(hrv, "hrvSummaries") as? [Any]) ?? [] {
                add(entry, MetricName.hrv, GarminClient.number(GarminClient.dict(entry, "lastNightAvg")))
            }
            start = end.adding(1)
        }
        return out
    }

    /// "DUMBBELL_BENCH_PRESS" as "Dumbbell Bench Press".
    static func title(_ code: String) -> String {
        code.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// "2026-11-09 17:05:12", a clock time where the watch was.
    static func localTime(_ text: String, zone: TimeZone) -> Date? {
        let parts = text.split(whereSeparator: { "-: T.".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 5 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3],
                                                  minute: parts[4], second: parts.count > 5 ? parts[5] : 0))
    }

    /// A pull-up logged with more added weight than this is taken to be a
    /// pulldown stack, as the service does.
    static let maxAddedPullUpKg = 20.5

    /// Strength sessions in a range of days. Garmin's listing gives totals for
    /// each exercise (sets, reps, total weight moved), not each set, so the
    /// reps are spread evenly over the sets and every set carries the average
    /// weight per rep. Weights arrive in grams.
    public func strengthWorkouts(from: Day, through: Day, zone: TimeZone, unit: WeightUnit) async throws -> [ImportedWorkout] {
        var out: [ImportedWorkout] = [], offset = 0
        let page = 100
        while true {
            let path = "/activitylist-service/activities/search/activities?start=\(offset)&limit=\(page)&startDate=\(from)&endDate=\(through)"
            let list = (try await json(path) as? [Any]) ?? []
            for activity in list {
                guard (GarminClient.dict(activity, "activityType", "typeKey") as? String) == "strength_training",
                      let id = GarminClient.number(GarminClient.dict(activity, "activityId")),
                      let startText = GarminClient.dict(activity, "startTimeLocal") as? String,
                      let start = GarminClient.localTime(startText, zone: zone) else { continue }
                let seconds = GarminClient.number(GarminClient.dict(activity, "duration")) ?? 0
                var workout = ImportedWorkout(
                    sourceID: String(Int64(id)), title: (GarminClient.dict(activity, "activityName") as? String) ?? "Strength",
                    start: start, end: start.addingTimeInterval(max(0, seconds)))
                for exercise in (GarminClient.dict(activity, "summarizedExerciseSets") as? [Any]) ?? [] {
                    let reps = Int(GarminClient.number(GarminClient.dict(exercise, "reps")) ?? 0)
                    guard reps > 0 else { continue }
                    let sets = max(1, min(reps, Int(GarminClient.number(GarminClient.dict(exercise, "sets")) ?? 1)))
                    let code = (GarminClient.dict(exercise, "subCategory") as? String) ?? (GarminClient.dict(exercise, "category") as? String) ?? "UNKNOWN"
                    var name = GarminClient.title(code)
                    let volume = GarminClient.number(GarminClient.dict(exercise, "volume")) ?? 0
                    let averageKg = volume > 0 ? volume / Double(reps) / 1000 : nil
                    if let averageKg, averageKg > GarminClient.maxAddedPullUpKg, ExerciseMatcher.pattern(for: name) == "pull_up" {
                        name = "Lat Pulldown"
                    }
                    let load = averageKg.map { kg -> Double in
                        // Whole plates and dumbbells: the nearest half pound, or tenth of a kilogram.
                        unit == .lb ? (kg / WeightUnit.lb.kilograms * 2).rounded() / 2 : (kg * 10).rounded() / 10
                    }
                    for index in 0..<sets {
                        workout.sets.append(ImportedSet(
                            exercise: name, reps: Double(reps / sets + (index < reps % sets ? 1 : 0)),
                            loadValue: load, loadUnit: unit,
                            notes: "From Garmin totals: \(sets) sets, \(reps) reps, average weight."))
                    }
                }
                out.append(workout)
            }
            if list.count < page { break }
            offset += page
        }
        return out
    }
}

/// Garmin as a source of nightly and daily values.
public struct GarminSource: HealthSource {
    public static let sourceName = "garmin"
    public let name = GarminSource.sourceName
    private let client: GarminClient
    public init(client: GarminClient) { self.client = client }

    public func requestAccess() async throws -> Bool {
        try await client.verify()
        return true
    }

    public func dailyMetrics(from: Day, through: Day) async throws -> [DailyMetric] {
        try await client.dailyMetrics(from: from, through: through)
    }
}

extension AppModel {
    /// Brings in Garmin strength sessions from the last `days` days.
    /// Returns nil if the read failed; the reason is in `lastError`.
    @MainActor
    public func importGarminWorkouts(from client: GarminClient, days: Int = 90) async -> ImportSummary? {
        let today = Day(importNow, in: importZone)
        do {
            let found = try await client.strengthWorkouts(from: today.adding(-days), through: today,
                                                          zone: importZone, unit: profile.unit)
            // The watch does not record which side a set was done on, and a
            // one-sided injury says nothing about it: the watch may hold either side.
            return importWorkouts(found, source: GarminSource.sourceName, inferSide: false)
        } catch {
            noteError(String(describing: error))
            return nil
        }
    }
}

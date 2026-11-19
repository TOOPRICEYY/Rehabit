import XCTest
@testable import RehabitCore

/// Answers from saved text, and records what was asked.
final class FakeGarmin: HTTPTransport, @unchecked Sendable {
    var asked: [(url: String, headers: [String: String])] = []
    var tokens = 0
    var rejectFirstGet = false
    var status = 200
    var answers: [(String, String)] = []
    let token: String

    init(expires: Double) {
        let claims = Data("{\"exp\":\(Int(expires))}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        token = "aaa." + claims + ".sig"
    }
    func post(_ url: String, headers: [String: String]) async throws -> HTTPReply {
        asked.append((url, headers)); tokens += 1
        return HTTPReply(status: status, body: Data(token.utf8))
    }
    func get(_ url: String, headers: [String: String]) async throws -> HTTPReply {
        asked.append((url, headers))
        if rejectFirstGet { rejectFirstGet = false; return HTTPReply(status: 401, body: Data()) }
        let body = answers.first { url.contains($0.0) }?.1 ?? "[]"
        return HTTPReply(status: status, body: Data(body.utf8))
    }
}

final class GarminTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    let clock = Date(timeIntervalSince1970: 1_795_000_000)

    func client(_ fake: FakeGarmin) -> GarminClient {
        let time = clock
        return GarminClient(apiKey: " secret-key\n", transport: fake, now: { time })
    }

    func testTokenIsExchangedOnceAndSentAsBearer() async throws {
        let fake = FakeGarmin(expires: clock.timeIntervalSince1970 + 86_400)
        let c = client(fake)
        _ = try await c.dailyMetrics(from: Day("2026-11-01")!, through: Day("2026-11-02")!)
        _ = try await c.dailyMetrics(from: Day("2026-11-01")!, through: Day("2026-11-02")!)
        XCTAssertEqual(fake.tokens, 1)
        XCTAssertEqual(fake.asked[0].headers["Authorization"], "ApiKey secret-key")
        XCTAssertTrue(fake.asked[0].url.hasSuffix("/personal-api-key/token"))
        XCTAssertEqual(fake.asked[1].headers["Authorization"], "Bearer " + fake.token)
        XCTAssertEqual(GarminClient.expiry(ofToken: fake.token), clock.addingTimeInterval(86_400))
    }

    func testTokenNearItsEndIsRenewedAndA401IsRetriedOnce() async throws {
        let soon = FakeGarmin(expires: clock.timeIntervalSince1970 + 600)
        let c = client(soon)
        _ = try await c.dailyMetrics(from: Day("2026-11-01")!, through: Day("2026-11-01")!)
        XCTAssertEqual(soon.tokens, 3)   // one per request, since each finds under an hour left

        let fake = FakeGarmin(expires: clock.timeIntervalSince1970 + 86_400)
        fake.rejectFirstGet = true
        _ = try await client(fake).dailyMetrics(from: Day("2026-11-01")!, through: Day("2026-11-01")!)
        XCTAssertEqual(fake.tokens, 2)
    }

    func testRefusedKeyAndRateLimitAreExplained() async {
        let fake = FakeGarmin(expires: 0)
        fake.status = 401
        do { try await client(fake).verify(); XCTFail("should throw") } catch {
            XCTAssertTrue(String(describing: error).contains("refused the key"))
        }
        fake.status = 429
        do { try await client(fake).verify(); XCTFail("should throw") } catch {
            XCTAssertTrue(String(describing: error).contains("limiting"))
        }
        // The key never appears in an error.
        XCTAssertFalse(String(describing: GarminError(description: "x")).contains("secret"))
    }

    func testDailyValuesAreReadAndZerosStayMissing() async throws {
        let fake = FakeGarmin(expires: clock.timeIntervalSince1970 + 86_400)
        fake.answers = [
            ("dailysummaries", """
             {"data":[{"calendarDate":"2026-11-01","movement":{"steps":{"value":8123}},"heartRate":{"restingValue":52}},
                      {"calendarDate":"2026-11-02","movement":{"steps":{"value":0}},"heartRate":{"restingValue":null}}]}
             """),
            ("dailySleepSummariesByDate", "[{\"calendarDate\":\"2026-11-01\",\"sleepTimeSeconds\":27000},{\"calendarDate\":\"2026-11-02\",\"sleepTimeSeconds\":0}]"),
            ("hrv-service", "{\"hrvSummaries\":[{\"calendarDate\":\"2026-11-01\",\"lastNightAvg\":61}]}"),
        ]
        let found = try await client(fake).dailyMetrics(from: Day("2026-11-01")!, through: Day("2026-11-02")!)
        let byMetric = Dictionary(grouping: found, by: \.metric)
        XCTAssertEqual(found.count, 4)
        XCTAssertEqual(byMetric[MetricName.steps]?.first?.value, 8123)
        XCTAssertEqual(byMetric[MetricName.restingHeartRate]?.first?.value, 52)
        XCTAssertEqual(byMetric[MetricName.sleepMinutes]?.first?.value, 450)
        XCTAssertEqual(byMetric[MetricName.hrv]?.first?.value, 61)
        XCTAssertTrue(found.allSatisfy { $0.source == "garmin" && $0.day == Day("2026-11-01")! })
    }

    func testLongRangesAreAskedForInFourWeekPieces() async throws {
        let fake = FakeGarmin(expires: clock.timeIntervalSince1970 + 86_400)
        _ = try await client(fake).dailyMetrics(from: Day("2026-09-01")!, through: Day("2026-10-30")!)
        let summaries = fake.asked.filter { $0.url.contains("dailysummaries") }.map(\.url)
        XCTAssertEqual(summaries.count, 3)
        XCTAssertTrue(summaries[0].hasSuffix("startDate=2026-09-01&endDate=2026-09-28"))
        XCTAssertTrue(summaries[2].hasSuffix("startDate=2026-10-27&endDate=2026-10-30"))
    }

    func testStrengthTotalsBecomeSetsAndImportOnce() async throws {
        let fake = FakeGarmin(expires: clock.timeIntervalSince1970 + 86_400)
        fake.answers = [("activitylist-service", """
            [{"activityId":25025334109,"activityName":"Strength","activityType":{"typeKey":"strength_training"},
              "startTimeLocal":"2026-11-09 17:05:12","duration":2700.0,
              "summarizedExerciseSets":[
                {"category":"BENCH_PRESS","subCategory":"DUMBBELL_BENCH_PRESS","sets":3,"reps":26,"volume":294835},
                {"category":"PULL_UP","sets":2,"reps":20,"volume":900000},
                {"category":"PULL_UP","subCategory":"PULL_UP","sets":1,"reps":5,"volume":0},
                {"category":"UNKNOWN","sets":1,"reps":0,"volume":0}]},
             {"activityId":2,"activityType":{"typeKey":"running"},"startTimeLocal":"2026-11-10 08:00:00","duration":1800}]
            """)]
        let c = client(fake)
        let found = try await c.strengthWorkouts(from: Day("2026-11-01")!, through: Day("2026-11-16")!, zone: zone, unit: .lb)
        XCTAssertEqual(found.count, 1)
        let sets = found[0].sets
        XCTAssertEqual(sets.count, 6)
        XCTAssertEqual(sets.prefix(3).map(\.reps), [9, 9, 8])
        XCTAssertEqual(sets[0].exercise, "Dumbbell Bench Press")
        XCTAssertEqual(sets[0].loadValue, 25)            // 11.34 kg a rep is 25 lb
        XCTAssertEqual(sets[3].exercise, "Lat Pulldown") // 45 kg is a stack, not added weight
        XCTAssertEqual(sets[5].exercise, "Pull Up"); XCTAssertNil(sets[5].loadValue)
        XCTAssertEqual(Day(found[0].start, in: zone).description, "2026-11-09")

        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [clock] in clock })
        let pec = try XCTUnwrap(Library.standard.pattern("press_horizontal")?.links.first?.tissue)
        m.save(Injury(label: "Pec", side: .left, onset: Day("2026-06-01")!, tissues: [pec]))
        let first = await m.importGarminWorkouts(from: c, days: 30)
        XCTAssertEqual(first?.workoutsAdded, 1); XCTAssertEqual(first?.setsAdded, 6)
        XCTAssertEqual(first?.activitiesAdded, 1)        // the run comes too, as an activity
        let stored = m.sets(of: try XCTUnwrap(m.workouts.first { $0.activity == nil }))
        XCTAssertEqual(stored.first?.side, .both)        // the watch's side is not guessed from the injury
        XCTAssertEqual(stored.first?.convention, .perHand)
        XCTAssertEqual(stored.last?.convention, .bodyweight)
        let again = await m.importGarminWorkouts(from: c, days: 30)
        XCTAssertEqual(again?.workoutsAdded, 0)
        XCTAssertEqual(again?.activitiesAdded, 0)
    }

    func testOtherActivitiesImportOnceWithTheirTotals() async throws {
        let fake = FakeGarmin(expires: clock.timeIntervalSince1970 + 86_400)
        fake.answers = [("activitylist-service", """
            [{"activityId":11,"activityName":"Morning Run","activityType":{"typeKey":"running"},
              "startTimeLocal":"2026-11-10 07:00:00","duration":1830.5,"distance":5012.3,"averageHR":148.0,
              "maxHR":171.0,"calories":402.0,"elevationGain":31.0,"steps":5120},
             {"activityId":12,"activityName":"","activityType":{"typeKey":"road_biking"},
              "startTimeLocal":"2026-11-11 18:00:00","duration":3600,"distance":20500.0,"averageHR":0,"calories":null},
             {"activityId":13,"activityType":{"typeKey":"walking"},"startTimeLocal":"2026-11-12 12:00:00",
              "duration":1200,"distance":0}]
            """)]
        let c = client(fake)
        let found = try await c.workouts(from: Day("2026-11-01")!, through: Day("2026-11-16")!, zone: zone, unit: .lb)
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { $0.sets.isEmpty })
        let run = try XCTUnwrap(found.first { $0.sourceID == "11" })
        XCTAssertEqual(run.title, "Morning Run")
        XCTAssertEqual(run.activity?.type, "running")
        XCTAssertEqual(run.activity?.distanceMeters, 5012.3)
        XCTAssertEqual(run.activity?.averageHeartRate, 148)
        XCTAssertEqual(run.activity?.maxHeartRate, 171)
        XCTAssertEqual(run.activity?.calories, 402)
        XCTAssertEqual(run.activity?.elevationGainMeters, 31)
        XCTAssertEqual(run.activity?.steps, 5120)
        XCTAssertEqual(run.end?.timeIntervalSince(run.start), 1830.5)
        let ride = try XCTUnwrap(found.first { $0.sourceID == "12" })
        XCTAssertEqual(ride.title, "Road biking")        // an empty name falls back to the kind
        XCTAssertNil(ride.activity?.averageHeartRate)    // 0 means not measured
        XCTAssertNil(ride.activity?.calories)
        let walk = try XCTUnwrap(found.first { $0.sourceID == "13" })
        XCTAssertEqual(walk.title, "Walking")
        XCTAssertNil(walk.activity?.distanceMeters)
        let strength = try await c.strengthWorkouts(from: Day("2026-11-01")!, through: Day("2026-11-16")!, zone: zone, unit: .lb)
        XCTAssertTrue(strength.isEmpty)

        let store = try Store(path: ":memory:")
        let m = AppModel(store: store, zone: zone, now: { [clock] in clock })
        let first = await m.importGarminWorkouts(from: c, days: 30)
        XCTAssertEqual(first?.activitiesAdded, 3); XCTAssertEqual(first?.workoutsAdded, 0); XCTAssertEqual(first?.setsAdded, 0)
        let stored = try XCTUnwrap(m.workouts.first { $0.title == "Morning Run" })
        XCTAssertEqual(stored.activity?.distanceMeters, 5012.3)
        XCTAssertTrue(m.sets(of: stored).isEmpty)
        XCTAssertEqual(stored.minutes ?? 0, 30.5, accuracy: 0.01)
        let again = await m.importGarminWorkouts(from: c, days: 30)
        XCTAssertEqual(again?.activitiesAdded, 0); XCTAssertEqual(again?.workoutsSkipped, 3)

        // Kept through a reload from the store, and in the app's export.
        let reopened = AppModel(store: store, zone: zone, now: { [clock] in clock })
        XCTAssertEqual(reopened.workouts.first { $0.title == "Morning Run" }?.activity?.type, "running")
    }

    func testGarminIsAHealthSource() async throws {
        let fake = FakeGarmin(expires: clock.timeIntervalSince1970 + 86_400)
        fake.answers = [("hrv-service", "{\"hrvSummaries\":[{\"calendarDate\":\"2026-11-10\",\"lastNightAvg\":58}]}")]
        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [clock] in clock })
        let count = await m.importHealth(from: GarminSource(client: client(fake)), days: 20)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(m.dailyMetrics(MetricName.hrv).first?.value, 58)
    }
}

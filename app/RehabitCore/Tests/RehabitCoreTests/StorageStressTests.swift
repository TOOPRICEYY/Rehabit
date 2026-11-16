import XCTest
@testable import RehabitCore

/// Adversarial tests for storage, export and merge. Each test states the
/// promise it holds the code to; a failing test here is meant to point at a
/// defect in `Sources/`, not at the test.
final class StorageStressTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// A snapshot as it would travel between devices: through JSON.
    func travel(_ store: Store) throws -> Snapshot {
        try Store.decodeSnapshot(try store.snapshotJSON(at: t0))
    }

    /// Two devices that both start with the same workout, created at t0.
    func pair(_ workout: Workout) throws -> (Store, Store) {
        let phone = try Store(path: ":memory:"), tablet = try Store(path: ":memory:")
        try phone.save(workout)
        try tablet.merge(try travel(phone))
        return (phone, tablet)
    }

    /// Both devices export first, then each merges the other's export.
    func exchange(_ a: Store, _ b: Store) throws {
        let fromA = try travel(a), fromB = try travel(b)
        try a.merge(fromB)
        try b.merge(fromA)
    }

    func state(_ store: Store) throws -> [String] {
        try store.all(Workout.self).map { "\($0.id):\($0.title)" }
            + store.all(WorkoutSet.self).map { "\($0.id):\($0.exercise):\($0.notes)" }
            + store.all(Injury.self).map { "\($0.id):\($0.label)" }
    }

    func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rehabit-stress-\(UUID().uuidString).sqlite").path
    }

    // MARK: Timestamp precision

    /// The phone's edit is half a second newer than the tablet's. The JSON
    /// body keeps whole seconds only, so the tablet compares its own precise
    /// 10.2 against the phone's exported 10 and keeps its older edit.
    func testNewerSubSecondEditWinsOnBothDevices() throws {
        let w = Workout(id: "w", title: "Legs", start: t0)
        let (phone, tablet) = try pair(w)
        var p = w; p.title = "phone"; p.updatedAt = at(10.7); try phone.save(p)
        var t = w; t.title = "tablet"; t.updatedAt = at(10.2); try tablet.save(t)

        try exchange(phone, tablet)
        XCTAssertEqual(try phone.all(Workout.self).map(\.title), ["phone"])
        XCTAssertEqual(try tablet.all(Workout.self).map(\.title), ["phone"], "newer edit lost on tablet")
        XCTAssertEqual(try state(phone), try state(tablet), "devices did not converge")

        // Even after more rounds they stay apart.
        try exchange(phone, tablet)
        try exchange(phone, tablet)
        XCTAssertEqual(try state(phone), try state(tablet), "still diverged after three exchanges")
    }

    /// A deletion 0.5 s after an edit on another device. The tombstone travels
    /// as whole seconds, so it looks older than the edit and is ignored.
    func testNewerSubSecondDeletionWinsOnBothDevices() throws {
        let w = Workout(id: "w", title: "Legs", start: t0)
        let (phone, tablet) = try pair(w)
        var p = w; p.title = "edited"; p.updatedAt = at(10.3); try phone.save(p)
        try tablet.delete(Workout.self, id: "w", at: at(10.8))

        try exchange(phone, tablet)
        XCTAssertTrue(try phone.all(Workout.self).isEmpty, "newer deletion lost on phone")
        XCTAssertTrue(try tablet.all(Workout.self).isEmpty)
    }

    /// The same as above with whole-second timestamps: the merge rules
    /// themselves are right when precision is not lost.
    func testWholeSecondEditAndDeleteConverge() throws {
        let w = Workout(id: "w", title: "Legs", start: t0)
        let (phone, tablet) = try pair(w)
        var p = w; p.title = "phone"; p.updatedAt = at(11); try phone.save(p)
        var t = w; t.title = "tablet"; t.updatedAt = at(10); try tablet.save(t)
        try exchange(phone, tablet)
        XCTAssertEqual(try tablet.all(Workout.self).map(\.title), ["phone"])
        XCTAssertEqual(try state(phone), try state(tablet))

        try tablet.delete(Workout.self, id: "w", at: at(20))
        try exchange(phone, tablet)
        XCTAssertTrue(try phone.all(Workout.self).isEmpty)
        XCTAssertTrue(try tablet.all(Workout.self).isEmpty)
    }

    /// A record saved and read back on one device should be the record saved.
    func testSubSecondDatesSurviveSaveAndFind() throws {
        let store = try Store(path: ":memory:")
        let w = Workout(id: "w", title: "Legs", start: at(0.25), end: at(3600.75))
        try store.save(w)
        let back = try XCTUnwrap(store.find(Workout.self, id: "w"))
        XCTAssertEqual(back.start, w.start, "start loses its fraction of a second")
        XCTAssertEqual(back, w)
    }

    // MARK: Ties

    func testEqualTimestampEditsConverge() throws {
        let w = Workout(id: "w", title: "Legs", start: t0)
        let (phone, tablet) = try pair(w)
        var p = w; p.title = "phone"; p.updatedAt = at(10); try phone.save(p)
        var t = w; t.title = "tablet"; t.updatedAt = at(10); try tablet.save(t)
        try exchange(phone, tablet)
        XCTAssertEqual(try state(phone), try state(tablet), "a tie leaves each device with its own edit")
    }

    func testEqualTimestampEditAndDeleteConverge() throws {
        let w = Workout(id: "w", title: "Legs", start: t0)
        let (phone, tablet) = try pair(w)
        var p = w; p.title = "phone"; p.updatedAt = at(10); try phone.save(p)
        try tablet.delete(Workout.self, id: "w", at: at(10))
        try exchange(phone, tablet)
        XCTAssertEqual(try state(phone), try state(tablet), "a tie leaves one device deleted, one not")
    }

    // MARK: Edit and delete across devices, both orders

    func testEditAfterDeleteWinsInEitherMergeOrder() throws {
        for phoneFirst in [true, false] {
            let w = Workout(id: "w", title: "Legs", start: t0)
            let (phone, tablet) = try pair(w)
            try phone.delete(Workout.self, id: "w", at: at(100))
            var t = w; t.title = "kept"; t.updatedAt = at(200); try tablet.save(t)
            if phoneFirst {
                try phone.merge(try travel(tablet)); try tablet.merge(try travel(phone))
            } else {
                try tablet.merge(try travel(phone)); try phone.merge(try travel(tablet))
            }
            XCTAssertEqual(try phone.all(Workout.self).map(\.title), ["kept"])
            XCTAssertEqual(try tablet.all(Workout.self).map(\.title), ["kept"])
        }
    }

    func testDeleteAfterEditWinsInEitherMergeOrder() throws {
        for phoneFirst in [true, false] {
            let w = Workout(id: "w", title: "Legs", start: t0)
            let (phone, tablet) = try pair(w)
            var t = w; t.title = "edited"; t.updatedAt = at(100); try tablet.save(t)
            try phone.delete(Workout.self, id: "w", at: at(200))
            if phoneFirst {
                try phone.merge(try travel(tablet)); try tablet.merge(try travel(phone))
            } else {
                try tablet.merge(try travel(phone)); try phone.merge(try travel(tablet))
            }
            XCTAssertTrue(try phone.all(Workout.self).isEmpty)
            XCTAssertTrue(try tablet.all(Workout.self).isEmpty)
            // And a stale copy of the edit cannot bring it back.
            XCTAssertEqual(try phone.merge(Snapshot(exportedAt: t0, profile: Profile(), workouts: [t], sets: [],
                                                    injuries: [], painChecks: [], dailyMetrics: [],
                                                    tombstones: [])), 0)
        }
    }

    func testTombstoneForANeverSeenRecordBlocksAnOlderCopy() throws {
        let store = try Store(path: ":memory:")
        let stone = Snapshot.Tombstone(kind: Workout.kind, id: "ghost", deletedAt: at(100))
        try store.merge(Snapshot(exportedAt: t0, profile: Profile(), workouts: [], sets: [], injuries: [],
                                 painChecks: [], dailyMetrics: [], tombstones: [stone]))
        var old = Workout(id: "ghost", title: "old", start: t0); old.updatedAt = at(50)
        XCTAssertEqual(try store.merge(Snapshot(exportedAt: t0, profile: Profile(), workouts: [old], sets: [],
                                                injuries: [], painChecks: [], dailyMetrics: [],
                                                tombstones: [])), 0)
        XCTAssertNil(try store.find(Workout.self, id: "ghost"))
        // The tombstone is passed on.
        XCTAssertEqual(try travel(store).tombstones, [stone])
    }

    // MARK: Orphans

    /// The phone deletes a workout. Before hearing of it, the tablet logged one
    /// more set in that workout. After syncing, a set survives whose workout
    /// is gone everywhere.
    func testNoLiveSetSurvivesItsDeletedWorkout() throws {
        let w = Workout(id: "w", title: "Legs", start: t0)
        let (phone, tablet) = try pair(w)
        let s = WorkoutSet(id: "s", workout: w, position: 0, exercise: "Squat", pattern: "squat",
                           reps: 5, loadValue: 100, updatedAt: at(50))
        try tablet.save(s)
        try phone.deleteWorkout(id: "w", at: at(100))
        try exchange(phone, tablet)

        for (name, store) in [("phone", phone), ("tablet", tablet)] {
            let workouts = Set(try store.all(Workout.self).map(\.id))
            let orphans = try store.all(WorkoutSet.self).filter { !workouts.contains($0.workoutID) }
            XCTAssertEqual(orphans.map(\.id), [], "\(name) keeps a set of a deleted workout")
        }
    }

    // MARK: Three devices

    func testThreeDevicesConvergeWithWholeSecondClocks() throws {
        let a = try Store(path: ":memory:"), b = try Store(path: ":memory:"), c = try Store(path: ":memory:")
        let w1 = Workout(id: "w1", title: "one", start: t0), w2 = Workout(id: "w2", title: "two", start: t0)
        try a.save(w1); try a.save(w2)
        try b.merge(try travel(a)); try c.merge(try travel(a))
        var e = w1; e.title = "b-edit"; e.updatedAt = at(10); try b.save(e)
        var f = w1; f.title = "c-edit"; f.updatedAt = at(20); try c.save(f)
        try a.delete(Workout.self, id: "w2", at: at(5))
        var g = w2; g.title = "c-revive"; g.updatedAt = at(30); try c.save(g)
        let inj = Injury(id: "i", label: "Knee", side: .left, onset: Day("2026-01-02")!, tissues: ["patellar_tendon"],
                         updatedAt: at(7))
        try b.save(inj)
        // Ring a -> b -> c -> a, then once more.
        for _ in 0..<2 {
            try b.merge(try travel(a)); try c.merge(try travel(b)); try a.merge(try travel(c))
        }
        XCTAssertEqual(try state(a), try state(b))
        XCTAssertEqual(try state(b), try state(c))
        XCTAssertEqual(try a.all(Workout.self).map(\.title).sorted(), ["c-edit", "c-revive"])
        XCTAssertEqual(try a.all(Injury.self).count, 1)
    }

    // MARK: Idempotence

    func testMergingTheSameSnapshotTwiceChangesNothing() throws {
        let src = try Store(path: ":memory:"), dst = try Store(path: ":memory:")
        let w = Workout(id: "w", title: "Legs", start: at(0.4))
        try src.save(w)
        try src.save(WorkoutSet(id: "s", workout: w, position: 0, exercise: "Squat", pattern: "squat",
                                reps: 5, updatedAt: at(1.6)))
        try src.save(Workout(id: "gone", title: "x", start: t0))
        try src.delete(Workout.self, id: "gone", at: at(2.9))
        let snap = try travel(src)
        XCTAssertEqual(try dst.merge(snap), 3)
        let once = try dst.snapshotJSON(at: t0)
        XCTAssertEqual(try dst.merge(snap), 0)
        XCTAssertEqual(try dst.snapshotJSON(at: t0), once)
        // Merging its own export back is also a no-op.
        XCTAssertEqual(try src.merge(snap), 0)
    }

    // MARK: Profile and daily metrics

    func testProfileReachesTheOtherDevice() throws {
        let phone = try Store(path: ":memory:"), tablet = try Store(path: ":memory:")
        phone.profile = Profile(bodyweightKg: 81.5, unit: .kg)
        try tablet.merge(try travel(phone))
        XCTAssertEqual(tablet.profile, Profile(bodyweightKg: 81.5, unit: .kg), "profile is dropped by merge")
    }

    /// Both devices hold a different value for the same day, metric and source.
    /// After exchanging snapshots each has the other's value: they swap instead
    /// of converging.
    func testConflictingDailyMetricsConverge() throws {
        let phone = try Store(path: ":memory:"), tablet = try Store(path: ":memory:")
        let d = Day("2026-11-15")!
        try phone.save([DailyMetric(day: d, metric: "hrv_ms", value: 60, source: "apple_health")])
        try tablet.save([DailyMetric(day: d, metric: "hrv_ms", value: 65, source: "apple_health")])
        try exchange(phone, tablet)
        XCTAssertEqual(try phone.dailyMetrics(), try tablet.dailyMetrics(), "daily metrics swapped, not converged")
    }

    func testMissingNightStaysMissingThroughMerge() throws {
        let phone = try Store(path: ":memory:"), tablet = try Store(path: ":memory:")
        try phone.save([DailyMetric(day: Day("2026-11-14")!, metric: "hrv_ms", value: 58, source: "w"),
                        DailyMetric(day: Day("2026-11-16")!, metric: "hrv_ms", value: 0.5, source: "w")])
        try tablet.merge(try travel(phone))
        try phone.merge(try travel(tablet))
        for store in [phone, tablet] {
            XCTAssertEqual(try store.dailyMetrics("hrv_ms").map(\.day.description), ["2026-11-14", "2026-11-16"])
            XCTAssertEqual(try store.dailyMetrics("hrv_ms").map(\.value), [58, 0.5])
        }
    }

    /// One reading that is not a number (a 0/0 average from a source) should
    /// not throw away the whole day's batch of good readings.
    func testOneNaNReadingDoesNotLoseTheBatch() throws {
        let store = try Store(path: ":memory:")
        let d = Day("2026-11-15")!
        try? store.save([DailyMetric(day: d, metric: "steps", value: 9000, source: "w"),
                         DailyMetric(day: d, metric: "hrv_ms", value: .nan, source: "w")])
        XCTAssertEqual(try store.dailyMetrics("steps").map(\.value), [9000], "good readings rolled back with the bad one")
        XCTAssertNoThrow(try store.snapshotJSON())
    }

    // MARK: Missing stays missing

    func testNilPainStaysNilAndZeroStaysZero() throws {
        let src = try Store(path: ":memory:"), dst = try Store(path: ":memory:")
        let w = Workout(id: "w", start: t0)
        try src.save(w)
        try src.save(WorkoutSet(id: "none", workout: w, position: 0, exercise: "Squat", pattern: "squat", reps: 5,
                                pain: nil, updatedAt: at(1)))
        try src.save(WorkoutSet(id: "zero", workout: w, position: 1, exercise: "Squat", pattern: "squat", reps: 0,
                                loadValue: 0, repsInReserve: 0, pain: 0, updatedAt: at(1)))
        try src.save(PainCheck(id: "pc", injuryID: "i", workoutID: nil, moment: .evening, dueAt: at(3600),
                               zone: TimeZone(identifier: "UTC")!, updatedAt: at(2)))
        let json = try src.snapshotJSON(at: t0)
        try dst.merge(try Store.decodeSnapshot(json))
        let again = try Store.decodeSnapshot(try dst.snapshotJSON(at: t0))

        let none = try XCTUnwrap(again.sets.first { $0.id == "none" })
        XCTAssertNil(none.pain); XCTAssertNil(none.loadValue); XCTAssertNil(none.repsInReserve)
        XCTAssertNil(none.holdSeconds); XCTAssertNil(none.painType)
        let zero = try XCTUnwrap(again.sets.first { $0.id == "zero" })
        XCTAssertEqual(zero.pain, 0); XCTAssertEqual(zero.loadValue, 0); XCTAssertEqual(zero.reps, 0)
        let check = try XCTUnwrap(again.painChecks.first)
        XCTAssertNil(check.pain); XCTAssertNil(check.answeredAt); XCTAssertFalse(check.isAnswered)
        XCTAssertEqual(try XCTUnwrap(dst.find(WorkoutSet.self, id: "none")).pain, nil)

        // Clearing a pain value on one device clears it on the other.
        var cleared = try XCTUnwrap(src.find(WorkoutSet.self, id: "zero"))
        cleared.pain = nil; cleared.updatedAt = at(10)
        try src.save(cleared)
        try dst.merge(try travel(src))
        XCTAssertNil(try XCTUnwrap(dst.find(WorkoutSet.self, id: "zero")).pain)
    }

    // MARK: Text

    func testUnicodeQuotesControlCharactersAndLongNotes() throws {
        let src = try Store(path: ":memory:"), dst = try Store(path: ":memory:")
        let weird = "He said \"ouch\" \\ 'sharp' — 膝 🦵🏽 e\u{301} \n\t\r null:\u{0} end; DROP TABLE record;--"
        let long = String(repeating: "Ä🦵\"\\", count: 250_000)
        let w = Workout(id: "w'\"🦵", title: weird, start: t0, notes: long)
        try src.save(w)
        XCTAssertEqual(try src.find(Workout.self, id: w.id), w)
        try dst.merge(try travel(src))
        XCTAssertEqual(try dst.find(Workout.self, id: w.id)?.title, weird)
        XCTAssertEqual(try dst.find(Workout.self, id: w.id)?.notes, long)
        try dst.delete(Workout.self, id: w.id, at: at(5))
        XCTAssertEqual(try travel(dst).tombstones.map(\.id), [w.id])
    }

    func testOddDoublesRoundTripExactly() throws {
        let src = try Store(path: ":memory:"), dst = try Store(path: ":memory:")
        let w = Workout(id: "w", start: t0)
        let values: [Double] = [0.1 + 0.2, 1.0 / 3.0, 22.679618500000001, 1e-7, 123456.789, 2.5, 47.5]
        for (i, v) in values.enumerated() {
            try src.save(WorkoutSet(id: "s\(i)", workout: w, position: i, exercise: "Row", pattern: nil,
                                    loadValue: v, loadUnit: .kg, updatedAt: at(1)))
        }
        try dst.merge(try travel(src))
        let back = try dst.all(WorkoutSet.self).sorted { $0.position < $1.position }.map(\.loadValue)
        XCTAssertEqual(back, values)
    }

    // MARK: Schema drift and decoding

    /// A record written by a newer app version with a pain type this version
    /// does not know. It must not vanish silently from lists and exports.
    func testAnUndecodableRecordIsNotSilentlyDropped() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        let w = Workout(id: "w", start: t0)
        try store.save(w)
        try store.save(WorkoutSet(id: "s", workout: w, position: 0, exercise: "Squat", pattern: "squat", reps: 5,
                                  pain: 4, painType: .sharp, updatedAt: at(1)))
        let raw = try Database(path: path)
        try raw.run("UPDATE record SET body = replace(body, '\"sharp\"', '\"stabbing\"') WHERE id = 's'")

        let sets = try store.all(WorkoutSet.self)
        let snap = try store.snapshot()
        XCTAssertEqual(sets.count, 1, "the set vanished from the list without an error")
        XCTAssertEqual(snap.sets.count + snap.tombstones.count, 1, "the set vanished from the export")

        // Deleting the workout leaves the undecodable set live underneath.
        try store.deleteWorkout(id: "w", at: at(10))
        let live = try raw.run("SELECT id FROM record WHERE kind = 'set' AND deleted = 0")
        XCTAssertEqual(live.count, 0, "deleteWorkout skipped the set it could not decode")
    }

    /// One record this version cannot read must not stop the rest of an
    /// incoming snapshot from merging, and must itself be carried, not dropped.
    func testOneUnreadableRecordDoesNotBlockTheSnapshot() throws {
        let src = try Store(path: ":memory:")
        let w = Workout(id: "w", start: t0)
        try src.save(w)
        try src.save(WorkoutSet(id: "s", workout: w, position: 0, exercise: "Squat", pattern: "squat", reps: 5,
                                painType: .sharp, updatedAt: at(1)))
        var text = String(decoding: try src.snapshotJSON(at: t0), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"sharp\"", with: "\"stabbing\"")      // a newer pain word: kept
        text = text.replacingOccurrences(of: "\"both\"", with: "\"midline\"")        // a side this version lacks
        let snapshot = try Store.decodeSnapshot(Data(text.utf8))
        XCTAssertEqual(snapshot.workouts.count, 1)
        XCTAssertEqual(snapshot.unreadable.map(\.id), ["s"])
        let dst = try Store(path: ":memory:")
        try dst.merge(snapshot)
        XCTAssertEqual(try dst.all(Workout.self).count, 1)
        XCTAssertTrue(try dst.all(WorkoutSet.self).isEmpty)
        // It is still there, still exported, and goes with its workout when that is deleted.
        let again = try Store.decodeSnapshot(try dst.snapshotJSON(at: t0))
        XCTAssertEqual(again.unreadable.map(\.id), ["s"])
        XCTAssertTrue(again.unreadable[0].body.contains("stabbing"))
        try dst.deleteWorkout(id: "w", at: at(10))
        XCTAssertTrue(try dst.snapshot().unreadable.isEmpty)
        XCTAssertEqual(try dst.snapshot().tombstones.count, 2)
    }

    /// A snapshot from a future format must be refused, not merged as if it
    /// were version 1.
    func testSnapshotFromAFutureSchemaIsRefused() throws {
        let src = try Store(path: ":memory:"), dst = try Store(path: ":memory:")
        try src.save(Workout(id: "w", title: "Legs", start: t0))
        var text = String(decoding: try src.snapshotJSON(at: t0), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
        XCTAssertTrue(text.contains("99"))
        var refused = false
        do { try dst.merge(try Store.decodeSnapshot(Data(text.utf8))) } catch { refused = true }
        XCTAssertTrue(refused, "a schemaVersion 99 snapshot was merged without complaint")
    }

    /// A stored profile that cannot be decoded silently becomes the default
    /// (body weight gone), and the default is what gets exported.
    func testAnUndecodableProfileIsNotSilentlyReset() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        store.profile = Profile(bodyweightKg: 80, unit: .kg)
        let raw = try Database(path: path)
        try raw.run("UPDATE setting SET value = replace(value, '\"kg\"', '\"st\"') WHERE key = 'profile'")
        XCTAssertEqual(store.profile.bodyweightKg, 80, "body weight lost because the unit was not recognised")
    }

    // MARK: Day

    func testDayIsTimezoneFreeThroughJSON() throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!, la = TimeZone(identifier: "America/Los_Angeles")!
        let moment = Date(timeIntervalSince1970: 1_763_300_000) // 2025-11-16 13:33 UTC
        let w = Workout(id: "w", start: moment, zone: tokyo)
        let pc = PainCheck(id: "p", injuryID: "i", workoutID: "w", moment: .evening, dueAt: moment, zone: la)
        let src = try Store(path: ":memory:"), dst = try Store(path: ":memory:")
        try src.save(w); try src.save(pc)
        try dst.merge(try travel(src))
        XCTAssertEqual(try dst.find(Workout.self, id: "w")?.startDay.description, "2025-11-16")
        XCTAssertEqual(try dst.find(PainCheck.self, id: "p")?.dueDay.description, "2025-11-16")
        XCTAssertEqual(Day("2025-11-16")?.description, "2025-11-16")
        XCTAssertEqual(Day("1969-12-31")?.number, -1)
    }

    /// An impossible date in an incoming snapshot is silently moved to another day.
    func testAnImpossibleDayIsRejectedNotShifted() throws {
        XCTAssertNil(Day("2026-02-31"), "2026-02-31 is accepted as \(Day("2026-02-31")?.description ?? "")")
        let json = Data("[\"2026-02-30\"]".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([Day].self, from: json))
    }

    // MARK: Clock skew

    /// The tablet's clock runs two minutes fast. The person edits on the
    /// tablet, then later deletes the record on the phone. The phone stamps the
    /// deletion with its own (slower) clock, which is older than the edit, so
    /// the record comes back on the next sync.
    func testADeletionMadeAfterSeeingAnEditStaysDeleted() throws {
        let w = Workout(id: "w", title: "Legs", start: t0)
        let (phone, tablet) = try pair(w)
        var t = w; t.title = "edited"; t.updatedAt = at(200); try tablet.save(t)
        try phone.merge(try travel(tablet))
        XCTAssertEqual(try phone.find(Workout.self, id: "w")?.title, "edited")
        try phone.delete(Workout.self, id: "w", at: at(100))   // the phone's 'now'
        try exchange(phone, tablet)
        XCTAssertNil(try phone.find(Workout.self, id: "w"), "deleted record came back on the phone")
        XCTAssertNil(try tablet.find(Workout.self, id: "w"))
    }

    // MARK: Files and scale

    func testFileBackedStoreReopensWithEverything() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let w = Workout(id: "w", title: "Legs", start: t0)
        do {
            let store = try Store(path: path)
            try store.save(w)
            try store.save(Workout(id: "x", start: t0))
            try store.delete(Workout.self, id: "x", at: at(9))
            store.profile = Profile(bodyweightKg: 70, unit: .kg)
            try store.save([DailyMetric(day: Day("2026-11-01")!, metric: "steps", value: 1234, source: "w")])
        }
        let reopened = try Store(path: path)
        XCTAssertEqual(try reopened.all(Workout.self), [w])
        XCTAssertEqual(try reopened.snapshot().tombstones.map(\.id), ["x"])
        XCTAssertEqual(reopened.profile.bodyweightKg, 70)
        XCTAssertEqual(try reopened.dailyMetrics().count, 1)
    }

    func testLargeLogStaysFast() throws {
        let src = try Store(path: ":memory:"), dst = try Store(path: ":memory:")
        var start = Date()
        for i in 0..<2_000 {
            let w = Workout(id: "w\(i)", start: t0.addingTimeInterval(Double(i) * 86_400))
            try src.save(w)
            for j in 0..<10 {
                try src.save(WorkoutSet(id: "w\(i)s\(j)", workout: w, position: j, exercise: "Squat",
                                        pattern: "squat", reps: 5, loadValue: 100, pain: j % 2 == 0 ? nil : 1,
                                        updatedAt: w.start))
            }
        }
        let saveTime = Date().timeIntervalSince(start)
        start = Date()
        XCTAssertEqual(try src.all(WorkoutSet.self).count, 20_000)
        XCTAssertEqual(try src.all(WorkoutSet.self, parent: "w1999").count, 10)
        let allTime = Date().timeIntervalSince(start)
        start = Date()
        let json = try src.snapshotJSON(at: t0)
        try dst.merge(try Store.decodeSnapshot(json))
        let mergeTime = Date().timeIntervalSince(start)
        print("stress: save \(saveTime)s, all \(allTime)s, export+merge \(mergeTime)s, json \(json.count) bytes")
        XCTAssertLessThan(allTime, 3)
        XCTAssertLessThan(mergeTime, 10)
        XCTAssertEqual(try dst.all(WorkoutSet.self).count, 20_000)
    }

    /// Saving outside a transaction on a real file: each save is its own
    /// commit. Measured, with a generous bound.
    func testFileBackedSavesOfAnOrdinarySession() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        let w = Workout(id: "w", start: t0)
        let start = Date()
        for j in 0..<300 {
            try store.save(WorkoutSet(id: "s\(j)", workout: w, position: j, exercise: "Squat", pattern: "squat",
                                      reps: 5, updatedAt: at(Double(j))))
        }
        let elapsed = Date().timeIntervalSince(start)
        print("stress: 300 file-backed saves \(elapsed)s")
        XCTAssertLessThan(elapsed, 5)
    }
}

import XCTest
@testable import OpenWearablesHealthSDK

/// The history a full export sends was recorded before the zone log began. Its zones are
/// read from the samples HealthKit stored one with, a few one-sample lookups per stretch
/// (RHISE-8334).
final class ZoneHistoryTests: XCTestCase {

    /// Samples with a zone, answering as HealthKit does, and counting the questions.
    private final class Samples: ZoneEvidenceSource {
        let samples: [(date: Date, zone: String)]
        var lookups = 0
        /// Answers "another zone than X" with X itself, as a source ignoring the filter would.
        var ignoresExclusion = false

        init(_ samples: [(String, String)]) {
            self.samples = samples.map { (ISO8601DateFormatter().date(from: $0.0)!, $0.1) }.sorted { $0.date < $1.date }
        }

        func newestZonedSample(before: Date, excluding zone: String?, completion: @escaping ((date: Date, zone: String)?) -> Void) {
            lookups += 1
            completion(samples.last { $0.date < before && (ignoresExclusion || $0.zone != zone) })
        }

        func oldestSampleStart(in zone: String, after: Date?, completion: @escaping (Date?) -> Void) {
            lookups += 1
            completion(samples.first { $0.zone == zone && (after == nil || $0.date > after!) }?.date)
        }
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func stretches(_ source: Samples, before: String = "2026-11-27T00:00:00Z") -> [ZoneLog.Entry] {
        var result: [ZoneLog.Entry]?
        ZoneHistory.stretches(from: source, before: date(before)) { result = $0 }
        return (result ?? []).sorted { $0.since < $1.since }
    }

    func testAHistoryInOneZoneIsOneStretchAndThreeLookups() {
        let source = Samples([
            ("2024-01-10T22:00:00Z", "Europe/Berlin"),
            ("2025-06-01T22:00:00Z", "Europe/Berlin"),
            ("2026-11-20T22:00:00Z", "Europe/Berlin"),
        ])

        let found = stretches(source)

        XCTAssertEqual(found, [ZoneLog.Entry(since: date("2024-01-10T22:00:00Z"), zone: "Europe/Berlin", seeded: true)])
        XCTAssertEqual(source.lookups, 3)
    }

    func testATripIsItsOwnStretchBetweenTheStretchesAtHome() {
        let source = Samples([
            ("2026-09-01T22:00:00Z", "Europe/Berlin"),
            ("2026-10-01T22:00:00Z", "Europe/Berlin"),
            ("2026-10-05T13:00:00Z", "Asia/Tokyo"),
            ("2026-10-12T13:00:00Z", "Asia/Tokyo"),
            ("2026-10-15T22:00:00Z", "Europe/Berlin"),
            ("2026-11-20T22:00:00Z", "Europe/Berlin"),
        ])

        let found = stretches(source)

        XCTAssertEqual(found.map(\.zone), ["Europe/Berlin", "Asia/Tokyo", "Europe/Berlin"])
        XCTAssertEqual(
            found.map(\.since),
            [date("2026-09-01T22:00:00Z"), date("2026-10-05T13:00:00Z"), date("2026-10-15T22:00:00Z")]
        )
        XCTAssertEqual(source.lookups, 9)
    }

    func testOnlySamplesBeforeTheLogBeganAreRead() {
        let source = Samples([
            ("2026-10-05T13:00:00Z", "Asia/Tokyo"),
            ("2026-11-20T22:00:00Z", "Europe/Berlin"),
        ])

        let found = stretches(source, before: "2026-11-01T00:00:00Z")

        XCTAssertEqual(found.map(\.zone), ["Asia/Tokyo"])
    }

    func testNoSampleWithAZoneGivesNoStretch() {
        XCTAssertEqual(stretches(Samples([])), [])
    }

    func testASourceThatIgnoresTheExclusionEndsTheWalk() {
        let source = Samples([
            ("2026-10-05T13:00:00Z", "Asia/Tokyo"),
            ("2026-11-10T22:00:00Z", "Europe/Berlin"),
            ("2026-11-20T22:00:00Z", "Europe/Berlin"),
        ])
        source.ignoresExclusion = true

        let found = stretches(source)

        // Asked for another zone than Berlin's, it answers with Berlin again: nothing earlier is trusted.
        XCTAssertEqual(found.map(\.zone), ["Europe/Berlin"])
    }

    func testTheWalkStopsAtTheStretchLimit() {
        let start = date("2020-01-01T00:00:00Z")
        let formatter = ISO8601DateFormatter()
        let source = Samples((0..<(ZoneHistory.maxStretches + 20)).map {
            (formatter.string(from: start.addingTimeInterval(Double($0) * 86400)), $0.isMultiple(of: 2) ? "Europe/Berlin" : "Asia/Tokyo")
        })

        XCTAssertEqual(stretches(source).count, ZoneHistory.maxStretches)
    }

    // MARK: - Into the log

    func testSeededHistoryAnswersForSamplesOlderThanTheLog() {
        let suite = "ow-sdk-zone-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let log = ZoneLog(defaults: defaults)
        log.record(berlin, at: date("2026-11-01T08:00:00Z"))
        let now = date("2026-11-27T00:00:00Z")

        log.seedHistory([
            ZoneLog.Entry(since: date("2026-10-15T22:00:00Z"), zone: "Europe/Berlin", seeded: true),
            ZoneLog.Entry(since: date("2026-10-05T13:00:00Z"), zone: "Asia/Tokyo", seeded: true),
            ZoneLog.Entry(since: date("2026-09-01T22:00:00Z"), zone: "Europe/Berlin", seeded: true),
            // What the phone saw itself stands: evidence from its own time is dropped.
            ZoneLog.Entry(since: date("2026-11-10T00:00:00Z"), zone: "Asia/Tokyo", seeded: true),
        ])

        XCTAssertEqual(log.zone(at: date("2026-10-08T12:00:00Z"), current: berlin, now: now), tokyo)
        XCTAssertEqual(log.zone(at: date("2026-09-20T12:00:00Z"), current: berlin, now: now), berlin)
        XCTAssertEqual(log.zone(at: date("2026-10-20T12:00:00Z"), current: berlin, now: now), berlin)
        XCTAssertEqual(log.zone(at: date("2026-11-15T12:00:00Z"), current: berlin, now: now), berlin)
        // Older than every entry: the earliest zone known.
        XCTAssertEqual(log.zone(at: date("2020-01-01T12:00:00Z"), current: tokyo, now: now), berlin)
    }

    func testSeedingAgainReplacesTheEarlierSeedAndSurvivesARestart() {
        let suite = "ow-sdk-zone-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = ZoneLog(defaults: defaults)
        log.record(TimeZone(identifier: "Europe/Berlin")!, at: date("2026-11-01T08:00:00Z"))

        log.seedHistory([ZoneLog.Entry(since: date("2026-10-05T13:00:00Z"), zone: "Asia/Tokyo", seeded: true)])
        log.seedHistory([ZoneLog.Entry(since: date("2026-08-01T00:00:00Z"), zone: "America/New_York", seeded: true)])

        let restarted = ZoneLog(defaults: defaults).snapshot
        XCTAssertEqual(restarted.map(\.zone), ["America/New_York", "Europe/Berlin"])
        XCTAssertEqual(restarted.map(\.seeded), [true, false])
    }
}

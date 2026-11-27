import HealthKit
import XCTest
@testable import OpenWearablesHealthSDK

/// A sample without a stored zone takes the zone the phone was in when it was recorded,
/// not the zone at upload (RHISE-8334).
final class ZoneLogTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    override func setUp() {
        super.setUp()
        suiteName = "ow-sdk-zone-log-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testASampleTakesTheZoneThePhoneWasInAtItsTime() {
        let log = ZoneLog(defaults: defaults)
        log.record(berlin, at: date("2026-11-01T08:00:00Z"))
        log.record(tokyo, at: date("2026-11-10T03:00:00Z"))
        // Back home; the trip's samples are uploaded only now.
        let now = date("2026-11-20T09:00:00Z")

        XCTAssertEqual(log.zone(at: date("2026-11-05T12:00:00Z"), current: berlin, now: now), berlin)
        XCTAssertEqual(log.zone(at: date("2026-11-15T12:00:00Z"), current: berlin, now: now), tokyo)
        XCTAssertEqual(log.zone(at: date("2026-11-20T08:59:00Z"), current: berlin, now: now), tokyo)
        XCTAssertEqual(log.zone(at: date("2026-11-20T09:00:00Z"), current: berlin, now: now), berlin)
    }

    func testASampleOlderThanTheLogTakesItsFirstZone() {
        let log = ZoneLog(defaults: defaults)
        log.record(berlin, at: date("2026-11-01T08:00:00Z"))
        log.record(tokyo, at: date("2026-11-10T03:00:00Z"))

        let zone = log.zone(at: date("2024-03-01T12:00:00Z"), current: tokyo, now: date("2026-11-11T00:00:00Z"))

        XCTAssertEqual(zone, berlin)
    }

    func testAnEmptyLogStartsWithTheCurrentZone() {
        let log = ZoneLog(defaults: defaults)

        let zone = log.zone(at: date("2026-01-15T12:00:00Z"), current: tokyo, now: date("2026-11-11T00:00:00Z"))

        XCTAssertEqual(zone, tokyo)
        XCTAssertEqual(log.snapshot, [ZoneLog.Entry(since: date("2026-11-11T00:00:00Z"), zone: "Asia/Tokyo")])
    }

    func testTheSameZoneIsStoredOnce() {
        let log = ZoneLog(defaults: defaults)
        log.record(berlin, at: date("2026-11-01T08:00:00Z"))
        log.record(berlin, at: date("2026-11-02T08:00:00Z"))
        _ = log.zone(at: date("2026-11-02T09:00:00Z"), current: berlin, now: date("2026-11-03T08:00:00Z"))

        XCTAssertEqual(log.snapshot.count, 1)
    }

    func testTheLogSurvivesARestart() {
        let first = ZoneLog(defaults: defaults)
        first.record(berlin, at: date("2026-11-01T08:00:00Z"))
        first.record(tokyo, at: date("2026-11-10T03:00:00Z"))

        let restarted = ZoneLog(defaults: defaults)

        XCTAssertEqual(restarted.snapshot, first.snapshot)
        XCTAssertEqual(
            restarted.zone(at: date("2026-11-05T12:00:00Z"), current: tokyo, now: date("2026-11-12T00:00:00Z")),
            berlin
        )
    }

    func testAClockSetBackDoesNotReorderTheLog() {
        let log = ZoneLog(defaults: defaults)
        log.record(berlin, at: date("2026-11-10T08:00:00Z"))
        log.record(tokyo, at: date("2026-11-09T08:00:00Z"))

        XCTAssertEqual(log.snapshot.map(\.since), [date("2026-11-10T08:00:00Z"), date("2026-11-10T08:00:00Z")])
        XCTAssertEqual(log.zone(at: date("2026-11-10T07:00:00Z"), current: tokyo, now: date("2026-11-11T00:00:00Z")), berlin)
    }

    func testOnlyTheNewestEntriesAreKept() {
        let log = ZoneLog(defaults: defaults)
        let start = date("2026-01-01T00:00:00Z")
        for step in 0..<(ZoneLog.maxEntries + 10) {
            log.record(step.isMultiple(of: 2) ? berlin : tokyo, at: start.addingTimeInterval(Double(step) * 3600))
        }

        XCTAssertEqual(log.snapshot.count, ZoneLog.maxEntries)
        XCTAssertEqual(log.snapshot.first?.since, start.addingTimeInterval(10 * 3600))
    }

    func testAnUploadedSampleTakesItsOffsetFromTheLog() throws {
        let sdk = OpenWearablesHealthSDK.shared
        let previous = sdk.zoneLog
        defer { sdk.zoneLog = previous }
        let log = ZoneLog(defaults: defaults)
        // In Tokyo for a week that ended an hour ago; the phone is somewhere else now.
        log.record(tokyo, at: Date().addingTimeInterval(-8 * 86400))
        log.record(TimeZone(identifier: "America/New_York")!, at: Date().addingTimeInterval(-3600))
        sdk.zoneLog = log
        let steps = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let start = Date().addingTimeInterval(-2 * 86400)
        let sample = HKQuantitySample(
            type: steps, quantity: HKQuantity(unit: .count(), doubleValue: 120), start: start, end: start.addingTimeInterval(600)
        )

        let payload = sdk.buildCombinedPayload(samples: [sample])

        let data = try XCTUnwrap(payload["data"] as? [String: Any])
        let records = try XCTUnwrap(data["records"] as? [[String: Any]])
        XCTAssertEqual(records.first?["zoneOffset"] as? String, "+09:00")
    }
}

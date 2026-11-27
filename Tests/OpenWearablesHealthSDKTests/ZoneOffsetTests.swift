import HealthKit
import XCTest
@testable import OpenWearablesHealthSDK

/// HealthKit stores a time zone on few samples. One without it is sent with the phone's
/// offset at the sample's time, so the backend places it on the user's day, not the UTC
/// day (RHISE-8334).
final class ZoneOffsetTests: XCTestCase {

    private let sdk = OpenWearablesHealthSDK.shared
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testASampleWithoutAZoneTakesThePhonesOffsetAtItsOwnTime() {
        // The offset is the zone's at the sample's time, not at upload: winter and summer differ.
        XCTAssertEqual(sdk.zoneOffset(metadata: nil, date: date("2026-01-15T12:00:00Z"), deviceTimeZone: newYork), "-05:00")
        XCTAssertEqual(sdk.zoneOffset(metadata: [:], date: date("2026-07-15T12:00:00Z"), deviceTimeZone: newYork), "-04:00")
    }

    func testAZoneOffTheHourKeepsItsMinutes() {
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertEqual(sdk.zoneOffset(metadata: nil, date: date("2026-01-15T12:00:00Z"), deviceTimeZone: kolkata), "+05:30")
    }

    func testTheZoneHealthKitStoredWinsOverThePhones() {
        let tokyo: [String: Any] = [HKMetadataKeyTimeZone: "Asia/Tokyo"]
        let berlin: [String: Any] = [HKMetadataKeyTimeZone: "Europe/Berlin"]
        let at = date("2026-01-15T12:00:00Z")

        XCTAssertEqual(sdk.zoneOffset(metadata: tokyo, date: at, deviceTimeZone: newYork), "+09:00")
        // A nutrient without a zone of its own takes its food's.
        XCTAssertEqual(sdk.zoneOffset(metadata: nil, fallback: berlin, date: at, deviceTimeZone: newYork), "+01:00")
        XCTAssertEqual(sdk.zoneOffset(metadata: tokyo, fallback: berlin, date: at, deviceTimeZone: newYork), "+09:00")
    }

    func testAnUnknownStoredZoneFallsBackToThePhones() {
        let unknown: [String: Any] = [HKMetadataKeyTimeZone: "Not/AZone"]
        XCTAssertEqual(sdk.zoneOffset(metadata: unknown, date: date("2026-01-15T12:00:00Z"), deviceTimeZone: newYork), "-05:00")
    }
}

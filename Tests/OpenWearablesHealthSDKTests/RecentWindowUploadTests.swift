import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Covers the uploads of `syncRecentWindow` (Rhise fork), which cuts the re-read window
/// into chunks by count instead of going through a sync round.
final class RecentWindowUploadTests: XCTestCase {

    /// Uploads `samples` the way `syncRecentWindow` does, with `foodsAround` standing in for
    /// the HealthKit lookup of their foods, and returns the `/sync` requests.
    private func uploadRecentWindow(
        _ samples: [HKSample],
        foodsAround: [HKCorrelation] = [],
        on sdk: OpenWearablesHealthSDK,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [StubURLProtocol.Recorded] {
        guard let endpoint = sdk.syncEndpoint, let generation = sdk.beginSyncRun() else {
            XCTFail("Could not start a sync run", file: file, line: line)
            return []
        }
        defer { sdk.finishSync(generation: generation) }

        var outcome: Bool?
        sdk.uploadRecentWindow(
            samples, foodsAround: foodsAround, endpoint: endpoint, credential: "access-1", generation: generation
        ) { outcome = $0 }

        XCTAssertTrue(waitUntil { outcome != nil }, "the upload never completed", file: file, line: line)
        XCTAssertEqual(outcome, true, file: file, line: line)
        return StubURLProtocol.recorded(matching: "/sync")
    }

    private func records(in uploads: [StubURLProtocol.Recorded]) -> [[String: Any]] {
        uploads.flatMap { upload -> [[String: Any]] in
            let data = upload.json?["data"] as? [String: Any]
            return data?["records"] as? [[String: Any]] ?? []
        }
    }

    /// A nutrient read before its food lands in an earlier chunk. Built on its own, that
    /// chunk sent it loose, and the food's chunk sent it again under its `parentId`.
    func testNutrientInAnotherChunkThanItsFoodIsSentOnceUnderItsFood() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(200) }
            let previousChunk = sdk.recordsPerChunk
            sdk.recordsPerChunk = 1
            defer { sdk.recordsPerChunk = previousChunk }

            let start = Date(timeIntervalSince1970: 1_779_163_200)
            let protein = HKQuantitySample(
                type: HKQuantityType.quantityType(forIdentifier: .dietaryProtein)!,
                quantity: HKQuantity(unit: .gram(), doubleValue: 38.2),
                start: start,
                end: start
            )
            let food = HKCorrelation(
                type: HKObjectType.correlationType(forIdentifier: .food)!,
                start: start,
                end: start,
                objects: [protein]
            )

            let uploads = uploadRecentWindow([protein, food], on: sdk)

            XCTAssertEqual(uploads.count, 2, "one upload per chunk")
            let proteinRows = records(in: uploads).filter { $0["id"] as? String == protein.uuid.uuidString }
            XCTAssertEqual(proteinRows.count, 1)
            XCTAssertEqual(proteinRows.first?["parentId"] as? String, food.uuid.uuidString)
        }
    }

    /// The food starts before the window, its nutrient inside. No later round sends a window
    /// again, so leaving the nutrient to the food sent neither.
    func testFoodStartingBeforeTheWindowGoesOutWithItsNutrient() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(200) }
            let start = Date(timeIntervalSince1970: 1_779_163_200)
            let protein = HKQuantitySample(
                type: HKQuantityType.quantityType(forIdentifier: .dietaryProtein)!,
                quantity: HKQuantity(unit: .gram(), doubleValue: 38.2),
                start: start,
                end: start
            )
            let food = HKCorrelation(
                type: HKObjectType.correlationType(forIdentifier: .food)!,
                start: start.addingTimeInterval(-600),
                end: start,
                objects: [protein]
            )

            let rows = records(in: uploadRecentWindow([protein], foodsAround: [food], on: sdk))

            XCTAssertEqual(rows.filter { $0["id"] as? String == food.uuid.uuidString }.count, 1)
            let proteinRows = rows.filter { $0["id"] as? String == protein.uuid.uuidString }
            XCTAssertEqual(proteinRows.count, 1)
            XCTAssertEqual(proteinRows.first?["parentId"] as? String, food.uuid.uuidString)
        }
    }

    /// A food around the window whose nutrients are all outside it is not the window's to send.
    func testFoodAroundTheWindowWithoutANutrientInItIsNotSent() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(200) }
            let start = Date(timeIntervalSince1970: 1_779_163_200)
            let sugar = HKQuantitySample(
                type: HKQuantityType.quantityType(forIdentifier: .dietarySugar)!,
                quantity: HKQuantity(unit: .gram(), doubleValue: 12),
                start: start,
                end: start
            )
            let otherProtein = HKQuantitySample(
                type: HKQuantityType.quantityType(forIdentifier: .dietaryProtein)!,
                quantity: HKQuantity(unit: .gram(), doubleValue: 20),
                start: start.addingTimeInterval(-3_600),
                end: start.addingTimeInterval(-3_600)
            )
            let otherFood = HKCorrelation(
                type: HKObjectType.correlationType(forIdentifier: .food)!,
                start: start.addingTimeInterval(-3_600),
                end: start.addingTimeInterval(-3_600),
                objects: [otherProtein]
            )

            let rows = records(in: uploadRecentWindow([sugar], foodsAround: [otherFood], on: sdk))

            XCTAssertEqual(rows.map { $0["id"] as? String }, [sugar.uuid.uuidString])
            XCTAssertTrue(rows.first?["parentId"] is NSNull, "a loose nutrient stays loose")
        }
    }

    func testRecentWindowUploadsCarryTheirSyncTrigger() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { _ in .status(200) }
            let start = Date(timeIntervalSince1970: 1_779_163_200)
            let steps = HKQuantitySample(
                type: HKQuantityType.quantityType(forIdentifier: .stepCount)!,
                quantity: HKQuantity(unit: .count(), doubleValue: 120),
                start: start,
                end: start.addingTimeInterval(60)
            )

            let uploads = uploadRecentWindow([steps], on: sdk)

            XCTAssertEqual(uploads.count, 1)
            XCTAssertEqual(uploads.first?.request.value(forHTTPHeaderField: "X-Open-Wearables-Sync-Trigger"), "recent_window")
            XCTAssertNotNil(uploads.first?.request.value(forHTTPHeaderField: "X-Open-Wearables-App-State"))
        }
    }
}

import HealthKit
import XCTest
@testable import OpenWearablesHealthSDK

/// A type HealthKit cannot read must end its part of the export the way the crawl
/// already treats it, as a type with nothing to send, instead of pausing every run at
/// the anchor capture for good. A locked device still pauses and retries (RHISE-8003).
final class ReadFailureTests: XCTestCase {

    func testOnlyErrorsNoRetryFixesMakeATypeUnreadable() {
        let sdk = OpenWearablesHealthSDK.shared
        func healthKitError(_ code: HKError.Code, _ message: String) -> NSError {
            NSError(domain: HKErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
        }

        XCTAssertEqual(sdk.readFailure(of: healthKitError(.errorAuthorizationNotDetermined, "Authorization not determined")), .unreadable)
        XCTAssertEqual(sdk.readFailure(of: healthKitError(.errorAuthorizationDenied, "Authorization denied")), .unreadable)
        XCTAssertEqual(sdk.readFailure(of: healthKitError(.errorHealthDataUnavailable, "Health data unavailable")), .unreadable)
        XCTAssertEqual(sdk.readFailure(of: healthKitError(.errorInvalidArgument, "Invalid argument")), .unreadable)

        XCTAssertEqual(sdk.readFailure(of: healthKitError(.errorDatabaseInaccessible, "Protected health data is inaccessible")), .retryAfterUnlock)
        XCTAssertEqual(
            sdk.readFailure(of: NSError(domain: HKErrorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Protected health data is inaccessible"])),
            .retryAfterUnlock
        )

        // A failure nothing says is permanent may pass on the next run, so it must not
        // let a replay report success or end a type's export.
        XCTAssertEqual(sdk.readFailure(of: NSError(domain: HKErrorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])), .retryLater)
        XCTAssertEqual(
            sdk.readFailure(of: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted, userInfo: [NSLocalizedDescriptionKey: "Couldn't communicate with a helper application."])),
            .retryLater
        )
    }

    /// The production failure: every type with data was sent and anchored, one tracked
    /// type HealthKit never asked about stayed. Its capture now completes it without an
    /// anchor, so the export can be marked done and incremental sync starts.
    func testAnUnreadableTypeCompletesWithoutAnAnchorAndTheExportCanFinish() {
        withExportUnderTest { sdk, steps, water in
            XCTAssertTrue(sdk.recordAnchorCapture(.captured(HKQueryAnchor(fromValue: 42)), for: steps.identifier))
            XCTAssertTrue(sdk.recordAnchorCapture(.unreadable, for: water.identifier))

            let state = sdk.loadSyncState()
            XCTAssertEqual(state?.completedTypes, [steps.identifier, water.identifier])
            XCTAssertNotNil(sdk.loadAnchor(for: steps), "a captured anchor is kept for incremental sync")
            XCTAssertNil(sdk.loadAnchor(for: water), "nothing was read, so incremental sync must start it from scratch")

            sdk.finalizeSyncState()
            XCTAssertTrue(sdk.defaults.bool(forKey: sdk.fullDoneKey()), "the initial export is marked done")
        }
    }

    func testACaptureThatDidNotFinishPausesTheExportAndLeavesTheTypeOpen() {
        withExportUnderTest { sdk, steps, _ in
            XCTAssertFalse(sdk.recordAnchorCapture(.retryLater, for: steps.identifier))

            XCTAssertEqual(sdk.loadSyncState()?.completedTypes, [])
            XCTAssertNil(sdk.loadAnchor(for: steps))
            XCTAssertFalse(sdk.defaults.bool(forKey: sdk.fullDoneKey()))
        }
    }

    /// Runs `body` on a full-export session for steps and water, with the anchor and
    /// export-done keys of a user no other test uses, removed afterwards.
    private func withExportUnderTest(_ body: (OpenWearablesHealthSDK, HKSampleType, HKSampleType) -> Void) {
        withIsolatedSDK(userId: "read-failure-\(UUID().uuidString)") { sdk, _ in
            let steps = HKQuantityType(.stepCount)
            let water = HKQuantityType(.dietaryWater)
            defer {
                sdk.defaults.removeObject(forKey: sdk.fullDoneKey())
                sdk.defaults.removeObject(forKey: sdk.anchorKey(for: steps))
                sdk.defaults.removeObject(forKey: sdk.anchorKey(for: water))
            }
            _ = sdk.startNewSyncState(fullExport: true, types: [steps, water])
            body(sdk, steps, water)
        }
    }
}

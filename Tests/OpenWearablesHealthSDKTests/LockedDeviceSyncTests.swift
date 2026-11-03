import XCTest
@testable import OpenWearablesHealthSDK

/// Covers the flag that carries a sync blocked by a locked device over to a later wake.
/// The unlock notification only reaches a process that is still running, so the flag has
/// to outlive the process, and only a run that sends every type may clear it.
final class LockedDeviceSyncTests: XCTestCase {

    private let suiteName = "com.openwearables.healthsdk.state"
    private let key = "pendingSyncAfterUnlock"

    func testDeferredSyncSurvivesAProcessRestart() {
        withIsolatedSDK { sdk, _ in
            let previous = sdk.pendingSyncAfterUnlock
            defer { sdk.pendingSyncAfterUnlock = previous }
            sdk.pendingSyncAfterUnlock = false

            sdk.deferSyncUntilUnlock()

            // A fresh `UserDefaults` for the same suite reads what a relaunched process sees.
            XCTAssertTrue(UserDefaults(suiteName: suiteName)?.bool(forKey: key) ?? false)
            XCTAssertTrue(sdk.pendingSyncAfterUnlock)
        }
    }

    /// A run that ends before sending anything, here a cold start before `configure` has
    /// restored the tracked types, must leave the flag for the next wake.
    func testARunThatSendsNothingKeepsTheDeferredSync() {
        withIsolatedSDK { sdk, _ in
            let previous = sdk.pendingSyncAfterUnlock
            let previousTypes = sdk.trackedTypes
            defer {
                sdk.pendingSyncAfterUnlock = previous
                sdk.trackedTypes = previousTypes
            }
            sdk.pendingSyncAfterUnlock = true
            sdk.trackedTypes = []

            var finished = false
            sdk.collectAllData(fullExport: false) { finished = true }

            XCTAssertTrue(finished, "with no tracked types the run ends before any HealthKit read")
            XCTAssertTrue(sdk.pendingSyncAfterUnlock)
        }
    }
}

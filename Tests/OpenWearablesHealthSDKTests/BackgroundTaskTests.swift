import XCTest
@testable import OpenWearablesHealthSDK

/// Covers the background-task assertions that keep the app running while work the server
/// has already seen is still in flight. The server rotates the refresh token as soon as a
/// refresh reaches it, so a refresh response lost to suspension leaves the Keychain with a
/// token the server has replaced (RHISE-7020).
final class BackgroundTaskTests: XCTestCase {

    private static let refreshed = #"{"access_token":"access-2","refresh_token":"refresh-2"}"#

    private func isRefresh(_ request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/token/refresh") == true
    }

    // MARK: - Token refresh

    func testRefreshHoldsABackgroundTaskUntilTheTokensAreStored() {
        withIsolatedSDK { sdk, _ in
            withFakeBackgroundTasks { host in
                StubURLProtocol.install { _ in .status(200, Self.refreshed) }

                var result: TokenRefreshResult?
                var heldWhenDone: Bool?
                sdk.attemptTokenRefresh { outcome in
                    result = outcome
                    heldWhenDone = host.begun(named: "ow_token_refresh").first.map(host.isLive)
                }

                XCTAssertTrue(waitUntil { result != nil })
                guard case .success? = result else { return XCTFail("expected a successful refresh") }
                XCTAssertEqual(heldWhenDone, true, "the task must outlive the Keychain write and the callbacks")
                XCTAssertEqual(OpenWearablesHealthSdkKeychain.getRefreshToken(), "refresh-2")
                XCTAssertEqual(OpenWearablesHealthSdkKeychain.getAccessToken(), "access-2")
                let refreshTasks = host.begun(named: "ow_token_refresh")
                XCTAssertEqual(refreshTasks.count, 1)
                XCTAssertEqual(host.ended, refreshTasks, "the task is ended once the refresh is done")
            }
        }
    }

    func testRefreshesInFlightTogetherShareOneBackgroundTask() {
        withIsolatedSDK { sdk, _ in
            withFakeBackgroundTasks { host in
                StubURLProtocol.install { _ in .status(200, Self.refreshed) }

                var results = 0
                sdk.attemptTokenRefresh { _ in results += 1 }
                sdk.attemptTokenRefresh { _ in results += 1 }

                XCTAssertTrue(waitUntil { results == 2 })
                XCTAssertEqual(StubURLProtocol.requests.filter(isRefresh).count, 1)
                XCTAssertEqual(host.begun(named: "ow_token_refresh").count, 1)
                XCTAssertEqual(host.ended.count, 1)
            }
        }
    }

    func testExpiringTheRefreshTaskCancelsTheRefreshAndKeepsTheStoredTokens() {
        withIsolatedSDK { sdk, _ in
            withFakeBackgroundTasks { host in
                StubURLProtocol.install { _ in .hang }

                var result: TokenRefreshResult?
                sdk.attemptTokenRefresh { result = $0 }
                XCTAssertTrue(waitUntil { !StubURLProtocol.requests.filter(self.isRefresh).isEmpty })
                guard let task = host.begun(named: "ow_token_refresh").first else {
                    return XCTFail("the refresh did not begin a background task")
                }

                host.expire(task)

                XCTAssertTrue(waitUntil { result != nil })
                guard case .networkError? = result else { return XCTFail("a cancelled refresh is a network error") }
                XCTAssertEqual(host.ended, [task], "the expiration handler ends the task, and only once")
                XCTAssertEqual(OpenWearablesHealthSdkKeychain.getRefreshToken(), "refresh-1")
            }
        }
    }

    // MARK: - BGTask completion

    func testBackgroundSyncCompletesItsTaskOnceWhenTheRunUnwinds() {
        withIsolatedSDK { sdk, _ in
            var expire: (() -> Void)?
            var completions: [Bool] = []

            sdk.runBackgroundSync(
                label: "test",
                retryOutbox: false,
                setExpirationHandler: { expire = $0 },
                complete: { completions.append($0) }
            )

            XCTAssertTrue(waitUntil { !completions.isEmpty })
            XCTAssertEqual(completions, [true])
            expire?()
            XCTAssertEqual(completions, [true], "a late expiration must not complete the task again")
        }
    }

    func testBackgroundTaskCompletionRunsOnlyTheFirstFinish() {
        var completions: [Bool] = []
        let completion = BackgroundTaskCompletion { completions.append($0) }

        completion.finish(success: false)
        completion.finish(success: true)

        XCTAssertEqual(completions, [false])
    }

    // MARK: - Observer sync

    func testObserverTaskIsKeptByTheRunInTheSlotAndEndedWhenItUnwinds() {
        withIsolatedSDK { sdk, _ in
            withFakeBackgroundTasks { host in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("could not claim the sync slot") }

                sdk.triggerCombinedSync()
                guard let task = host.begun(named: "health_combined_sync").first else {
                    return XCTFail("the observer trigger did not begin a background task")
                }
                // The debounced trigger runs after 2s and finds the slot taken.
                RunLoop.current.run(until: Date().addingTimeInterval(2.5))
                XCTAssertTrue(host.isLive(task), "a trigger that found the slot taken must not end the run's task")

                sdk.finishSync(generation: generation)

                XCTAssertEqual(host.ended, [task])
                XCTAssertFalse(sdk.hasObserverBgTask)
            }
        }
    }

    func testObserverTaskOutlivesARunThatEndsBeforeTheScheduledSyncStarts() {
        withIsolatedSDK { sdk, _ in
            withFakeBackgroundTasks { host in
                guard let generation = sdk.beginSyncRun() else { return XCTFail("could not claim the sync slot") }
                sdk.triggerCombinedSync()
                guard let task = host.begun(named: "health_combined_sync").first else {
                    return XCTFail("the observer trigger did not begin a background task")
                }

                sdk.finishSync(generation: generation)
                XCTAssertTrue(host.isLive(task), "the scheduled observer sync has not started yet")

                XCTAssertTrue(waitUntil(timeout: 5) { !host.isLive(task) })
                XCTAssertEqual(host.ended, [task])
            }
        }
    }
}

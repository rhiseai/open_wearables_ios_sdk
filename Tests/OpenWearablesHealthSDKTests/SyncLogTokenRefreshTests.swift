import XCTest
@testable import OpenWearablesHealthSDK

/// Covers how a `/logs` request recovers from an expired access token. The start log is
/// the first request of a full export, so it is the one that meets a token that expired
/// while the app was idle; without a refresh every log of the run was rejected.
final class SyncLogTokenRefreshTests: XCTestCase {

    private static let refreshed = #"{"access_token":"access-2","refresh_token":"refresh-2"}"#

    private func isRefresh(_ request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/token/refresh") == true
    }

    private func logRequests() -> [StubURLProtocol.Recorded] {
        StubURLProtocol.recorded(matching: "/logs")
    }

    private func refreshRequests() -> [URLRequest] {
        StubURLProtocol.requests.filter(isRefresh)
    }

    /// Sends one start log and waits for its completion, which the sync loop waits on
    /// before it uploads anything.
    private func sendStartLog(on sdk: OpenWearablesHealthSDK) -> Bool {
        var finished = false
        sdk.sendSyncStartLog(types: [], typeCounts: [:], startDate: nil, endDate: Date()) {
            finished = true
        }
        return waitUntil { finished }
    }

    func testLogRetriesOnceWithRefreshedTokenAfterUnauthorized() {
        withIsolatedSDK { sdk, _ in
            var authErrors = 0
            sdk.onAuthError = { _, _ in authErrors += 1 }

            StubURLProtocol.install { request in
                if self.isRefresh(request) { return .status(200, Self.refreshed) }
                let credential = request.value(forHTTPHeaderField: "Authorization")
                return credential == "Bearer access-2" ? .status(202) : .status(401)
            }

            XCTAssertTrue(sendStartLog(on: sdk))

            let logs = logRequests()
            XCTAssertEqual(logs.count, 2, "expected the original attempt plus one retry")
            XCTAssertEqual(logs.first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
            XCTAssertEqual(logs.last?.request.value(forHTTPHeaderField: "Authorization"), "Bearer access-2")
            XCTAssertEqual(
                logs.first?.request.value(forHTTPHeaderField: "X-Request-Id"),
                logs.last?.request.value(forHTTPHeaderField: "X-Request-Id"),
                "both attempts should carry one request id so the server can correlate them"
            )
            XCTAssertEqual(logs.first?.body, logs.last?.body, "the retry resends the same log")
            XCTAssertEqual(refreshRequests().count, 1)
            XCTAssertEqual(OpenWearablesHealthSdkKeychain.getAccessToken(), "access-2")
            XCTAssertEqual(authErrors, 0)
        }
    }

    /// One retry, not a loop: a log the server still rejects with the new token is dropped.
    func testLogIsDroppedWhenTheRetryIsAlsoUnauthorized() {
        withIsolatedSDK { sdk, _ in
            var authErrors = 0
            sdk.onAuthError = { _, _ in authErrors += 1 }

            StubURLProtocol.install { request in
                self.isRefresh(request) ? .status(200, Self.refreshed) : .status(401)
            }

            XCTAssertTrue(sendStartLog(on: sdk))

            XCTAssertEqual(logRequests().count, 2)
            XCTAssertEqual(refreshRequests().count, 1)
            XCTAssertEqual(authErrors, 0, "a log never decides that the user is signed out")
        }
    }

    /// A rejected refresh token is the sync upload's to report. The log is dropped
    /// without a retry and without raising `onAuthError` a second time.
    func testLogIsDroppedWithoutAuthErrorWhenRefreshIsRejected() {
        withIsolatedSDK { sdk, _ in
            var authErrors = 0
            sdk.onAuthError = { _, _ in authErrors += 1 }

            StubURLProtocol.install { _ in .status(401) }

            XCTAssertTrue(sendStartLog(on: sdk))

            XCTAssertEqual(logRequests().count, 1, "no retry without a fresh token")
            XCTAssertEqual(refreshRequests().count, 1)
            XCTAssertEqual(OpenWearablesHealthSdkKeychain.getAccessToken(), "access-1")
            XCTAssertEqual(authErrors, 0)
        }
    }

    func testLogIsDroppedWhenRefreshHitsANetworkError() {
        withIsolatedSDK { sdk, _ in
            var authErrors = 0
            sdk.onAuthError = { _, _ in authErrors += 1 }

            StubURLProtocol.install { request in
                self.isRefresh(request) ? .failure(URLError(.notConnectedToInternet)) : .status(401)
            }

            XCTAssertTrue(sendStartLog(on: sdk))

            XCTAssertEqual(logRequests().count, 1)
            XCTAssertEqual(refreshRequests().count, 1)
            XCTAssertEqual(authErrors, 0)
        }
    }

    /// An API key cannot be refreshed, so the log is dropped and nothing is reported.
    func testLogWithApiKeyIsDroppedOnUnauthorized() {
        withIsolatedSDK(accessToken: nil, refreshToken: nil) { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveApiKey("key-1")
            var authErrors = 0
            sdk.onAuthError = { _, _ in authErrors += 1 }

            StubURLProtocol.install { _ in .status(401) }

            XCTAssertTrue(sendStartLog(on: sdk))

            XCTAssertEqual(logRequests().count, 1)
            XCTAssertEqual(logRequests().first?.request.value(forHTTPHeaderField: "X-Open-Wearables-API-Key"), "key-1")
            XCTAssertEqual(refreshRequests().count, 0)
            XCTAssertEqual(authErrors, 0)
        }
    }

    /// The production burst: the per-type end logs of one round all carry the same
    /// expired token. They share one refresh, and each resends once with the new token.
    func testConcurrentUnauthorizedLogsShareOneRefresh() {
        withIsolatedSDK { sdk, _ in
            StubURLProtocol.install { request in
                if self.isRefresh(request) { return .status(200, Self.refreshed) }
                let credential = request.value(forHTTPHeaderField: "Authorization")
                return credential == "Bearer access-2" ? .status(202) : .status(401)
            }

            let burst = 7
            for index in 0..<burst {
                sdk.sendTypeEndLog(type: "type-\(index)", success: true, recordCount: 1, durationMs: 1)
            }

            func sent(with token: String) -> [StubURLProtocol.Recorded] {
                logRequests().filter { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" }
            }

            // A retry is sent only after its 401 was handled, so once every log has
            // resent, no further refresh can start.
            XCTAssertTrue(waitUntil { sent(with: "access-2").count == burst })

            XCTAssertEqual(refreshRequests().count, 1, "one refresh for the whole burst")
            XCTAssertEqual(sent(with: "access-1").count, burst)
            XCTAssertEqual(logRequests().count, burst * 2)
            XCTAssertEqual(
                Set(sent(with: "access-1").compactMap { $0.request.value(forHTTPHeaderField: "X-Request-Id") }),
                Set(sent(with: "access-2").compactMap { $0.request.value(forHTTPHeaderField: "X-Request-Id") }),
                "every retry carries the request id of its own first attempt"
            )
        }
    }
}

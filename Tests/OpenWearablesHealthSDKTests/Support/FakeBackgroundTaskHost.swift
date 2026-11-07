import UIKit
import XCTest
@testable import OpenWearablesHealthSDK

/// Records the background tasks the SDK begins and ends, and lets a test play iOS by
/// firing a task's expiration handler.
final class FakeBackgroundTaskHost: BackgroundTaskHost {
    private let lock = NSLock()
    private var nextIdentifier = 1
    private var expirationHandlers: [UIBackgroundTaskIdentifier: () -> Void] = [:]
    private(set) var begun: [(name: String, identifier: UIBackgroundTaskIdentifier)] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []

    func beginBackgroundTask(withName name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        lock.lock()
        defer { lock.unlock() }
        let identifier = UIBackgroundTaskIdentifier(rawValue: nextIdentifier)
        nextIdentifier += 1
        begun.append((name: name, identifier: identifier))
        expirationHandlers[identifier] = expirationHandler
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        ended.append(identifier)
        expirationHandlers[identifier] = nil
    }

    func begun(named name: String) -> [UIBackgroundTaskIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return begun.filter { $0.name == name }.map(\.identifier)
    }

    func isLive(_ identifier: UIBackgroundTaskIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return expirationHandlers[identifier] != nil
    }

    /// Fires the expiration handler of a live task, as iOS does when the time runs out.
    func expire(_ identifier: UIBackgroundTaskIdentifier) {
        lock.lock()
        let handler = expirationHandlers[identifier]
        lock.unlock()
        handler?()
    }
}

extension XCTestCase {

    /// Runs `body` with the SDK's background tasks going to a recording host.
    func withFakeBackgroundTasks(_ body: (FakeBackgroundTaskHost) -> Void) {
        let sdk = OpenWearablesHealthSDK.shared
        let previous = sdk.backgroundTaskHost
        let host = FakeBackgroundTaskHost()
        sdk.backgroundTaskHost = host
        defer { sdk.backgroundTaskHost = previous }
        body(host)
    }
}

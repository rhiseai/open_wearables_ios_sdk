import UIKit

/// Begins and ends the UIKit background-task assertions the SDK holds. Production uses
/// `UIApplication.shared`; tests swap in a host that records each call.
internal protocol BackgroundTaskHost: AnyObject {
    func beginBackgroundTask(withName name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

internal final class ApplicationBackgroundTaskHost: BackgroundTaskHost {
    func beginBackgroundTask(withName name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

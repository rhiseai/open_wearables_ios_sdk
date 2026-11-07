import Foundation
import UIKit
import HealthKit
import BackgroundTasks

extension OpenWearablesHealthSDK {

    // MARK: - Background delivery
    internal func startBackgroundDelivery() {
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()

        let observableTypes = getQueryableTypes()

        for type in observableTypes {
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
                guard let self = self else {
                    completionHandler()
                    return
                }

                if let error = error {
                    print("Observer error for \(type.identifier): \(error.localizedDescription)")
                    completionHandler()
                    return
                }

                self.triggerCombinedSync()
                completionHandler()
            }
            healthStore.execute(observer)
            activeObserverQueries.append(observer)
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
        logMessage("Background observers registered for \(observableTypes.count) types")
    }

    internal func stopBackgroundDelivery() {
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()
        
        let observableTypes = getQueryableTypes()
        
        for t in observableTypes {
            healthStore.disableBackgroundDelivery(for: t) { _, _ in }
        }
        logMessage("Background observers stopped")
    }

    // MARK: - BGTaskScheduler
    internal func scheduleAppRefresh() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(req)
            logMessage("Scheduled app refresh task")
        }
        catch {
            logMessage("scheduleAppRefresh error: \(error.localizedDescription)")
        }
    }

    internal func scheduleProcessing() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGProcessingTaskRequest(identifier: processTaskId)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(req)
            logMessage("Scheduled processing task")
        }
        catch {
            logMessage("scheduleProcessing error: \(error.localizedDescription)")
        }
    }

    internal func cancelAllBGTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            logMessage("Cancelled all background tasks")
        }
    }

    @available(iOS 13.0, *)
    internal func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        runBackgroundSync(
            label: "BGAppRefresh",
            retryOutbox: false,
            setExpirationHandler: { task.expirationHandler = $0 },
            complete: { task.setTaskCompleted(success: $0) }
        )
    }

    @available(iOS 13.0, *)
    internal func handleProcessing(task: BGProcessingTask) {
        scheduleProcessing()
        runBackgroundSync(
            label: "BGProcessing",
            retryOutbox: true,
            setExpirationHandler: { task.expirationHandler = $0 },
            complete: { task.setTaskCompleted(success: $0) }
        )
    }

    /// Runs one background sync and completes its task when the run unwinds, not after a fixed
    /// 20s / 25s wait. A task completed while the run was still going let iOS suspend the app
    /// mid-run, in the middle of a token refresh too, whose response was then never stored, and
    /// a processing task, which may run for minutes, used a fraction of its time.
    ///
    /// The run stops on its own before the background time runs out ("Background time low").
    /// If iOS ends the task first, the expiration handler cancels the run's uploads, which
    /// leaves cursors in place because `SyncState` only advances on a 2xx. The task completes
    /// exactly once, from the run or from the expiration handler.
    internal func runBackgroundSync(
        label: String,
        retryOutbox: Bool,
        setExpirationHandler: (@escaping () -> Void) -> Void,
        complete: @escaping (Bool) -> Void
    ) {
        let completion = BackgroundTaskCompletion(complete)
        setExpirationHandler { [weak self] in
            self?.logMessage("\(label) task expired - cancelling in-flight uploads")
            self?.cancelInFlightSyncUploads(reason: "backgroundExpiration")
            completion.finish(success: false)
        }

        if retryOutbox { retryOutboxIfPossible() }
        collectAllData(fullExport: false, isBackground: true) {
            completion.finish(success: true)
        }
    }
}

/// Completes a background task once, whichever of the run and the expiration handler gets
/// there first.
internal final class BackgroundTaskCompletion {
    private let lock = NSLock()
    private var done = false
    private let complete: (Bool) -> Void

    init(_ complete: @escaping (Bool) -> Void) {
        self.complete = complete
    }

    func finish(success: Bool) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { complete(success) }
    }
}

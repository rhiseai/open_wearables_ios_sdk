import Foundation
import UIKit
import HealthKit

extension OpenWearablesHealthSDK {

    // MARK: - Logs Endpoint

    internal var logsEndpoint: URL? {
        guard let userId = userId, let base = apiBaseUrl else { return nil }
        return URL(string: "\(base)/sdk/users/\(userId)/logs")
    }

    // MARK: - Device State Collection

    internal func collectDeviceStateEvent() -> [String: Any] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        let thermalState: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = "nominal"
        case .fair: thermalState = "fair"
        case .serious: thermalState = "serious"
        case .critical: thermalState = "critical"
        @unknown default: thermalState = "unknown"
        }

        let batteryState: String
        switch device.batteryState {
        case .unknown: batteryState = "unknown"
        case .unplugged: batteryState = "unplugged"
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        @unknown default: batteryState = "unknown"
        }

        let totalRam = ProcessInfo.processInfo.physicalMemory
        let availableRam = os_proc_available_memory()

        let bgTimeRemaining = UIApplication.shared.backgroundTimeRemaining
        let taskType = bgTimeRemaining == .greatestFiniteMagnitude ? "foreground" : "background"

        return [
            "eventType": "device_state",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "batteryLevel": device.batteryLevel,
            "batteryState": batteryState,
            "isLowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermalState": thermalState,
            "taskType": taskType,
            "availableRamBytes": availableRam,
            "totalRamBytes": totalRam
        ]
    }

    // MARK: - Sync Start Log

    internal func sendSyncStartLog(
        types: [HKSampleType],
        typeCounts: [String: Int],
        startDate: Date?,
        endDate: Date,
        completion: @escaping () -> Void
    ) {
        guard let endpoint = logsEndpoint, let credential = authCredential else {
            completion()
            return
        }

        let formatter = ISO8601DateFormatter()

        let dataTypeCounts: [[String: Any]] = types.map {
            ["type": $0.identifier, "count": typeCounts[$0.identifier] ?? 0]
        }

        var timeRange: [String: String] = ["endDate": formatter.string(from: endDate)]
        if let startDate = startDate {
            timeRange["startDate"] = formatter.string(from: startDate)
        }

        let startEvent: [String: Any] = [
            "eventType": "historical_data_sync_start",
            "timestamp": formatter.string(from: Date()),
            "dataTypeCounts": dataTypeCounts,
            "timeRange": timeRange
        ]

        let body: [String: Any] = [
            "sdkVersion": OpenWearablesHealthSDK.sdkVersion,
            "provider": "apple",
            "events": [startEvent, collectDeviceStateEvent()]
        ]

        sendLogRequest(endpoint: endpoint, credential: credential, body: body, completion: completion)
    }

    // MARK: - Per-Type End Log (fire-and-forget, called during sync as each type completes)

    internal func sendTypeEndLog(type: String, success: Bool, recordCount: Int, durationMs: Int) {
        guard let endpoint = logsEndpoint, let credential = authCredential else { return }

        let endEvent: [String: Any] = [
            "eventType": "historical_data_type_sync_end",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "dataType": type,
            "success": success,
            "recordCount": recordCount,
            "durationMs": durationMs
        ]

        let body: [String: Any] = [
            "sdkVersion": OpenWearablesHealthSDK.sdkVersion,
            "provider": "apple",
            "events": [endEvent, collectDeviceStateEvent()]
        ]

        sendLogRequest(endpoint: endpoint, credential: credential, body: body) { }
    }

    // MARK: - Helper: fire end log when a type finishes during full export

    internal func fireTypeCompletedLog(_ typeIdentifier: String) {
        guard let startTime = fullSyncStartTime else { return }
        let recordCount = loadSyncState()?.typeProgress[typeIdentifier]?.sentCount ?? 0
        guard recordCount > 0 else { return }
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        sendTypeEndLog(type: typeIdentifier, success: true, recordCount: recordCount, durationMs: durationMs)
    }

    // MARK: - Send Log Request

    private func sendLogRequest(
        endpoint: URL,
        credential: String,
        body: [String: Any],
        completion: @escaping () -> Void
    ) {
        var body = body
        // Opens (or continues) the SyncRun. `syncType` is not on the logs schema yet,
        // so it stays off this body; the matching `/sync` batches carry both fields.
        if let sessionId = currentSyncAttribution()?.sessionId {
            body["syncSessionId"] = sessionId
        }
        
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            logMessage("Failed to serialize sync log")
            completion()
            return
        }

        let requestId = UUID().uuidString
        var req = buildRequest(url: endpoint, credential: credential, requestId: requestId)
        req.httpBody = data

        let task = foregroundSession.dataTask(with: req) { [weak self] _, response, error in
            guard let self = self else {
                completion()
                return
            }
            if let error = error {
                self.logMessage("Sync log error: \(error.localizedDescription)")
                completion()
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            if let statusCode = statusCode {
                self.logMessage("Sync log: HTTP \(statusCode)")
            }
            if statusCode == 401 {
                self.handle401ForLog(
                    endpoint: endpoint, sentCredential: credential, data: data,
                    requestId: requestId, completion: completion
                )
                return
            }
            completion()
        }
        task.resume()
    }

    /// The start log is the first request of a full export, so it is the one that meets
    /// an access token that expired while the app was idle. It refreshes through the
    /// shared refresh lock and is sent once more under the same request id.
    ///
    /// A log is diagnostics: with API-key auth, a rejected refresh or a network error it
    /// is dropped. It never raises `onAuthError` - the sync upload that follows owns that
    /// decision and reaches it on its own request.
    private func handle401ForLog(
        endpoint: URL,
        sentCredential: String,
        data: Data,
        requestId: String,
        completion: @escaping () -> Void
    ) {
        if isApiKeyAuth {
            logMessage("Sync log: 401 with apiKey auth - dropped")
            completion()
            return
        }

        // A burst of logs shares one expired token. Once one of them has refreshed it,
        // the rest resend with the new token instead of refreshing again.
        if let current = authCredential, current != sentCredential {
            resendLog(endpoint: endpoint, credential: current, data: data, requestId: requestId, completion: completion)
            return
        }

        attemptTokenRefresh { [weak self] result in
            guard let self = self else {
                completion()
                return
            }
            guard case .success = result, let newCredential = self.authCredential else {
                self.logMessage("Sync log: token refresh failed - dropped")
                completion()
                return
            }
            self.resendLog(
                endpoint: endpoint, credential: newCredential, data: data,
                requestId: requestId, completion: completion
            )
        }
    }

    private func resendLog(
        endpoint: URL,
        credential: String,
        data: Data,
        requestId: String,
        completion: @escaping () -> Void
    ) {
        var req = buildRequest(url: endpoint, credential: credential, requestId: requestId)
        req.httpBody = data

        let task = foregroundSession.dataTask(with: req) { [weak self] _, response, error in
            if let error = error {
                self?.logMessage("Sync log retry error: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                self?.logMessage("Sync log retry: HTTP \(httpResponse.statusCode)")
            }
            completion()
        }
        task.resume()
    }
}

import Foundation
import HealthKit

extension OpenWearablesHealthSDK {

    internal enum UploadDisposition: Equatable {
        case delivered
        case permanentlyRejected(statusCode: Int)
        case retryableFailure
    }

    internal enum HTTPUploadResponseDisposition: Equatable {
        case delivered
        case refreshAuthentication
        case permanentlyRejected
        case retryableFailure
    }

    internal func classifyUploadResponse(statusCode: Int) -> HTTPUploadResponseDisposition {
        if (200...299).contains(statusCode) { return .delivered }
        if statusCode == 401 { return .refreshAuthentication }
        if (400...499).contains(statusCode) { return .permanentlyRejected }
        return .retryableFailure
    }

    // MARK: - Outbox model
    internal struct OutboxItem: Codable {
        let typeIdentifier: String
        let userKey: String
        let payloadPath: String
        let anchorPath: String?
        let wasFullExport: Bool?
        let recordCount: Int?
        let byteCount: Int?
        var authRetryCount: Int?
    }

    internal func outboxDir() -> URL {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("health_outbox", isDirectory: true)
    }

    internal func ensureOutboxDir() {
        try? FileManager.default.createDirectory(at: outboxDir(), withIntermediateDirectories: true)
    }

    internal func newPath(_ name: String, ext: String) -> URL {
        ensureOutboxDir()
        return outboxDir().appendingPathComponent("\(name).\(ext)")
    }

    // MARK: - Combined upload
    internal func enqueueCombinedUpload(
        payload: [String: Any],
        anchors: [String: HKQueryAnchor],
        endpoint: URL,
        credential: String,
        wasFullExport: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            self.logMessage("Failed to serialize payload")
            completion(false)
            return
        }

        let recordCount: Int = {
            guard let payloadData = payload["data"] as? [String: Any] else { return 0 }
            return (payloadData["workouts"] as? [[String: Any]] ?? []).count
                + (payloadData["records"] as? [[String: Any]] ?? []).count
                + (payloadData["sleep"] as? [[String: Any]] ?? []).count
        }()

        enqueueCombinedUpload(
            payloadData: data,
            recordCount: recordCount,
            anchors: anchors,
            endpoint: endpoint,
            credential: credential,
            wasFullExport: wasFullExport
        ) { disposition in
            switch disposition {
            case .delivered:
                completion(true)
            case .permanentlyRejected, .retryableFailure:
                completion(false)
            }
        }
    }

    internal func enqueueCombinedUpload(
        payloadData: Data,
        recordCount: Int,
        anchors: [String: HKQueryAnchor],
        endpoint: URL,
        credential: String,
        wasFullExport: Bool = false,
        completion: @escaping (UploadDisposition) -> Void
    ) {

        let id = UUID().uuidString
        let payloadURL = newPath("combined_payload_\(id)", ext: "json")

        do {
            try payloadData.write(to: payloadURL, options: Data.WritingOptions.atomic)
        } catch {
            self.logMessage("Failed to write payload: \(error.localizedDescription)")
            completion(.retryableFailure)
            return
        }

        var anchorsURL: URL? = nil
        if !anchors.isEmpty {
            var anchorsData: [String: Data] = [:]
            for (typeId, anchor) in anchors {
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
                    anchorsData[typeId] = data
                }
            }

            if let serializedData = try? NSKeyedArchiver.archivedData(withRootObject: anchorsData, requiringSecureCoding: true) {
                let u = newPath("combined_anchors_\(id)", ext: "bin")
                try? serializedData.write(to: u, options: Data.WritingOptions.atomic)
                anchorsURL = u
            }
        }

        let item = OutboxItem(
            typeIdentifier: "combined",
            userKey: userKey(),
            payloadPath: payloadURL.path,
            anchorPath: anchorsURL?.path,
            wasFullExport: wasFullExport,
            recordCount: recordCount,
            byteCount: payloadData.count,
            authRetryCount: 0
        )
        let itemURL = newPath("combined_item_\(id)", ext: "json")
        do {
            let metadata = try JSONEncoder().encode(item)
            try metadata.write(to: itemURL, options: Data.WritingOptions.atomic)
        } catch {
            self.logMessage("Failed to persist outbox metadata: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: payloadURL)
            if let anchorsURL = anchorsURL { try? FileManager.default.removeItem(at: anchorsURL) }
            completion(.retryableFailure)
            return
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &req, credential: credential)
        req.httpBody = payloadData
        req.setValue("\(payloadData.count)", forHTTPHeaderField: "Content-Length")

        self.logPayloadSummary(payloadData, label: "Sending")

        let task = foregroundSession.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                let nsError = error as NSError
                if nsError.code != NSURLErrorCancelled {
                    self.logMessage("Upload error: \(error.localizedDescription)")
                    self.markNetworkError()
                }
                completion(.retryableFailure)
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                switch self.classifyUploadResponse(statusCode: httpResponse.statusCode) {
                case .delivered:
                    self.logMessage("HTTP \(httpResponse.statusCode)")

                    self.handleSuccessfulUpload(itemPath: itemURL.path, anchorPath: anchorsURL?.path, wasFullExport: wasFullExport)

                    try? FileManager.default.removeItem(atPath: payloadURL.path)
                    completion(.delivered)
                case .refreshAuthentication:
                    self.handle401ForUpload(
                        payloadData: payloadData,
                        endpoint: endpoint,
                        itemPath: itemURL.path,
                        payloadPath: payloadURL.path,
                        anchorsPath: anchorsURL?.path,
                        wasFullExport: wasFullExport,
                        completion: completion
                    )
                case .permanentlyRejected:
                    var errorMsg = "HTTP \(httpResponse.statusCode)"
                    if let data = data, let errorBody = String(data: data, encoding: .utf8) {
                        let truncated = errorBody.count > 200 ? String(errorBody.prefix(200)) + "..." : errorBody
                        errorMsg += " - \(truncated)"
                    }
                    self.logMessage(errorMsg)
                    self.logMessage("Dropping chunk rejected with HTTP \(httpResponse.statusCode)")
                    self.removeOutboxFiles(itemPath: itemURL.path, payloadPath: payloadURL.path, anchorPath: anchorsURL?.path)
                    completion(.permanentlyRejected(statusCode: httpResponse.statusCode))
                case .retryableFailure:
                    self.logMessage("HTTP \(httpResponse.statusCode) - will retry later")
                    completion(.retryableFailure)
                }
            } else {
                self.logMessage("No HTTP response")
                self.markNetworkError()
                completion(.retryableFailure)
            }
        }

        task.resume()
    }

    /// Handles 401 response for combined uploads.
    private func handle401ForUpload(
        payloadData: Data,
        endpoint: URL,
        itemPath: String,
        payloadPath: String,
        anchorsPath: String?,
        wasFullExport: Bool,
        completion: @escaping (UploadDisposition) -> Void
    ) {
        if isApiKeyAuth {
            self.logMessage("Got 401 with apiKey auth")
            self.emitAuthError(statusCode: 401)
            removeOutboxFiles(itemPath: itemPath, payloadPath: payloadPath, anchorPath: anchorsPath)
            completion(.permanentlyRejected(statusCode: 401))
            return
        }

        self.logMessage("Got 401, refreshing token...")

        self.attemptTokenRefresh { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success:
                guard let newCredential = self.authCredential else {
                    self.logMessage("Token refreshed but no credential available")
                    completion(.retryableFailure)
                    return
                }
                self.logMessage("Token refreshed, retrying...")

                var retryReq = URLRequest(url: endpoint)
                retryReq.httpMethod = "POST"
                retryReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                self.applyAuth(to: &retryReq, credential: newCredential)
                retryReq.httpBody = payloadData
                retryReq.setValue("\(payloadData.count)", forHTTPHeaderField: "Content-Length")

                let retryTask = self.foregroundSession.dataTask(with: retryReq) { [weak self] retryData, retryResponse, retryError in
                    guard let self = self else { return }

                    if let retryError = retryError {
                        self.logMessage("Retry failed: \(retryError.localizedDescription)")
                        completion(.retryableFailure)
                        return
                    }

                    let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                    switch self.classifyUploadResponse(statusCode: retryStatus) {
                    case .delivered:
                        self.logMessage("Retry: HTTP \(retryStatus)")
                        self.handleSuccessfulUpload(itemPath: itemPath, anchorPath: anchorsPath, wasFullExport: wasFullExport)
                        try? FileManager.default.removeItem(atPath: payloadPath)
                        completion(.delivered)
                    case .refreshAuthentication, .permanentlyRejected:
                        self.logMessage("Retry permanently rejected: HTTP \(retryStatus)")
                        if (401...403).contains(retryStatus) { self.emitAuthError(statusCode: retryStatus) }
                        self.removeOutboxFiles(itemPath: itemPath, payloadPath: payloadPath, anchorPath: anchorsPath)
                        completion(.permanentlyRejected(statusCode: retryStatus))
                    case .retryableFailure:
                        self.logMessage("Retry failed: HTTP \(retryStatus) - will retry later")
                        completion(.retryableFailure)
                    }
                }
                retryTask.resume()

            case .authFailure:
                self.logMessage("Token refresh rejected - auth is invalid")
                self.emitAuthError(statusCode: 401)
                removeOutboxFiles(itemPath: itemPath, payloadPath: payloadPath, anchorPath: anchorsPath)
                completion(.permanentlyRejected(statusCode: 401))

            case .networkError:
                self.logMessage("Token refresh failed (network) - will retry later")
                self.markNetworkError()
                completion(.retryableFailure)
            }
        }
    }

    internal func removeOutboxFiles(itemPath: String, payloadPath: String, anchorPath: String?) {
        try? FileManager.default.removeItem(atPath: itemPath)
        try? FileManager.default.removeItem(atPath: payloadPath)
        if let anchorPath = anchorPath, !anchorPath.isEmpty {
            try? FileManager.default.removeItem(atPath: anchorPath)
        }
    }

    /// Records the single authentication refresh allowed for a persisted item.
    /// Returns false when that item has already been retried with fresh credentials.
    internal func markOutboxAuthenticationRetried(itemPath: String) -> Bool {
        let url = URL(fileURLWithPath: itemPath)
        guard let data = try? Data(contentsOf: url),
              var item = try? JSONDecoder().decode(OutboxItem.self, from: data),
              (item.authRetryCount ?? 0) == 0 else { return false }
        item.authRetryCount = 1
        guard let updated = try? JSONEncoder().encode(item) else { return false }
        do {
            try updated.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    internal func outboxAuthenticationWasRetried(itemPath: String) -> Bool {
        let url = URL(fileURLWithPath: itemPath)
        guard let data = try? Data(contentsOf: url),
              let item = try? JSONDecoder().decode(OutboxItem.self, from: data) else { return false }
        return (item.authRetryCount ?? 0) > 0
    }

    internal func pendingOutboxStats() -> (chunks: Int, records: Int, bytes: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: outboxDir(), includingPropertiesForKeys: nil
        ) else { return (0, 0, 0) }

        var chunks = 0
        var records = 0
        var bytes = 0
        for itemURL in files where
            itemURL.lastPathComponent.hasPrefix("combined_item_") ||
            itemURL.lastPathComponent.hasPrefix("item_") {
            guard let data = try? Data(contentsOf: itemURL),
                  let item = try? JSONDecoder().decode(OutboxItem.self, from: data),
                  FileManager.default.fileExists(atPath: item.payloadPath) else { continue }
            chunks += 1
            records += item.recordCount ?? 0
            bytes += item.byteCount ?? ((try? Data(contentsOf: URL(fileURLWithPath: item.payloadPath)).count) ?? 0)
        }
        return (chunks, records, bytes)
    }

    // MARK: - Handle successful upload
    internal func handleSuccessfulUpload(itemPath: String, anchorPath: String?, wasFullExport: Bool) {
        guard let itemData = try? Data(contentsOf: URL(fileURLWithPath: itemPath)),
              let item = try? JSONDecoder().decode(OutboxItem.self, from: itemData) else {
            logMessage("Failed to read item for anchor saving")
            return
        }

        if let anchorPath = anchorPath, !anchorPath.isEmpty {
            if item.typeIdentifier == "combined" {
                if let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)),
                   let anchorsDict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, NSData.self], from: anchorData) as? [String: Data] {
                    for (typeId, anchorData) in anchorsDict {
                        saveAnchorData(anchorData, typeIdentifier: typeId, userKey: item.userKey)
                    }
                    logMessage("Saved anchors for \(anchorsDict.count) types")
                }
            } else {
                if let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)) {
                    saveAnchorData(anchorData, typeIdentifier: item.typeIdentifier, userKey: item.userKey)
                }
            }

            try? FileManager.default.removeItem(atPath: anchorPath)
        }

        if wasFullExport {
            let fullDoneKey = "fullDone.\(item.userKey)"
            defaults.set(true, forKey: fullDoneKey)
            defaults.synchronize()
            logMessage("Marked full export complete")
        }

        try? FileManager.default.removeItem(atPath: itemPath)
    }

    // MARK: - Clear outbox
    internal func clearOutbox() {
        let dir = outboxDir()
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        logMessage("Cleared outbox")
    }

    // MARK: - Retry pending items

    /// Minimum file age before an outbox item is retried (the original upload may
    /// still be in flight).
    private static let outboxMinRetryAge: TimeInterval = 30
    /// Items older than this are dropped - the data is re-fetched from HealthKit by
    /// the regular sync anyway, so there is no point in re-sending week-old batches.
    private static let outboxMaxItemAge: TimeInterval = 7 * 24 * 3600

    /// Retries pending outbox items through the *background* URLSession.
    /// - uploads go through the background session (survive suspension/kill),
    /// - the session is limited to one connection per host, so items go out serially,
    /// - a retry pass is skipped while a regular sync is running,
    /// - only one retry pass can run at a time,
    /// - items already enqueued in the background session are not enqueued again.
    internal func retryOutboxIfPossible() {
        guard let endpoint = self.syncEndpoint, let credential = self.authCredential else { return }

        if isSyncInProgress {
            logMessage("Outbox retry skipped - sync in progress")
            return
        }

        outboxRetryLock.lock()
        if isRetryingOutbox {
            outboxRetryLock.unlock()
            return
        }
        isRetryingOutbox = true
        outboxRetryLock.unlock()

        session.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            defer {
                self.outboxRetryLock.lock()
                self.isRetryingOutbox = false
                self.outboxRetryLock.unlock()
            }

            // Payloads already queued in the background session (possibly from a
            // previous app run) must not be enqueued a second time.
            let inFlightPayloadPaths = Set(tasks.compactMap { task -> String? in
                let parts = task.taskDescription?.split(separator: "|", omittingEmptySubsequences: false)
                guard let parts = parts, parts.count > 1 else { return nil }
                return String(parts[1])
            })

            let dir = self.outboxDir()
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

            let itemFiles = files.filter {
                $0.pathExtension == "json" &&
                ($0.lastPathComponent.hasPrefix("item_") || $0.lastPathComponent.hasPrefix("combined_item_"))
            }

            var enqueued = 0
            for itemURL in itemFiles {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: itemURL.path),
                      let mdate = attrs[.modificationDate] as? Date else { continue }
                let age = Date().timeIntervalSince(mdate)
                if age < Self.outboxMinRetryAge { continue }

                guard let data = try? Data(contentsOf: itemURL),
                      let item = try? JSONDecoder().decode(OutboxItem.self, from: data) else {
                    try? FileManager.default.removeItem(at: itemURL)
                    continue
                }

                let payloadURL = URL(fileURLWithPath: item.payloadPath)
                guard FileManager.default.fileExists(atPath: payloadURL.path) else {
                    // Orphaned metadata without a payload - clean up
                    try? FileManager.default.removeItem(at: itemURL)
                    continue
                }

                if age > Self.outboxMaxItemAge {
                    self.logMessage("Outbox: dropping stale item (\(Int(age / 3600))h old)")
                    try? FileManager.default.removeItem(at: payloadURL)
                    if let anchorPath = item.anchorPath {
                        try? FileManager.default.removeItem(atPath: anchorPath)
                    }
                    try? FileManager.default.removeItem(at: itemURL)
                    continue
                }

                if inFlightPayloadPaths.contains(payloadURL.path) { continue }

                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                self.applyAuth(to: &req, credential: credential)

                let task = self.session.uploadTask(with: req, fromFile: payloadURL)
                task.taskDescription = [itemURL.path, payloadURL.path, item.anchorPath ?? ""].joined(separator: "|")
                task.resume()
                enqueued += 1
            }

            if enqueued > 0 {
                self.logMessage("Outbox: enqueued \(enqueued) pending upload(s) to background session")
            }
        }
    }
}

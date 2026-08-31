import Foundation

extension OpenWearablesHealthSDK {

    // MARK: - URLSession delegate
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription else { return }
        let parts = desc.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let itemPath = parts.count > 0 ? parts[0] : ""
        let payloadPath = parts.count > 1 ? parts[1] : ""
        let anchorPath = parts.count > 2 ? parts[2] : ""

        if backgroundDataBuffer[task.taskIdentifier] != nil {
            backgroundDataBuffer.removeValue(forKey: task.taskIdentifier)
        }

        if let error = error {
            let nsError = error as NSError
            if nsError.code != NSURLErrorCancelled {
                NSLog("[OpenWearablesHealthSDK] background upload failed: \(error.localizedDescription) - will retry later")
            }
            return
        }

        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0

        if (200...299).contains(statusCode) {
            if !itemPath.isEmpty,
               let itemData = try? Data(contentsOf: URL(fileURLWithPath: itemPath)),
               let item = try? JSONDecoder().decode(OutboxItem.self, from: itemData) {
                // Saves anchors (combined & per-type), marks fullDone when applicable,
                // and removes the item + anchor files.
                handleSuccessfulUpload(
                    itemPath: itemPath,
                    anchorPath: anchorPath.isEmpty ? nil : anchorPath,
                    wasFullExport: item.wasFullExport ?? false
                )
            }
            if !payloadPath.isEmpty { try? FileManager.default.removeItem(atPath: payloadPath) }
            return
        }

        if statusCode == 401 {
            if isApiKeyAuth {
                self.logMessage("Background 401 with API key - dropping item")
                removeOutboxFiles(itemPath: itemPath, payloadPath: payloadPath, anchorPath: anchorPath)
                recordPermanentSyncFailure(statusCode: 401)
                DispatchQueue.main.async { [weak self] in
                    self?.emitAuthError(statusCode: 401)
                }
            } else if outboxAuthenticationWasRetried(itemPath: itemPath) {
                self.logMessage("Background 401 persisted after token refresh - dropping item")
                removeOutboxFiles(itemPath: itemPath, payloadPath: payloadPath, anchorPath: anchorPath)
                recordPermanentSyncFailure(statusCode: 401)
                DispatchQueue.main.async { [weak self] in
                    self?.emitAuthError(statusCode: 401)
                }
            } else {
                self.attemptTokenRefresh { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        if self.markOutboxAuthenticationRetried(itemPath: itemPath) {
                            self.logMessage("Token refreshed after background 401 - retrying outbox once")
                            self.retryOutboxIfPossible()
                        } else {
                            self.logMessage("Background 401 persisted after token refresh - dropping item")
                            self.removeOutboxFiles(itemPath: itemPath, payloadPath: payloadPath, anchorPath: anchorPath)
                            self.recordPermanentSyncFailure(statusCode: 401)
                            DispatchQueue.main.async { [weak self] in
                                self?.emitAuthError(statusCode: 401)
                            }
                        }
                    case .authFailure:
                        self.removeOutboxFiles(itemPath: itemPath, payloadPath: payloadPath, anchorPath: anchorPath)
                        self.recordPermanentSyncFailure(statusCode: 401)
                        DispatchQueue.main.async { [weak self] in
                            self?.emitAuthError(statusCode: 401)
                        }
                    case .networkError:
                        self.logMessage("Token refresh failed (network) after background 401 - will retry later")
                    }
                }
            }
            return
        }

        if (400...499).contains(statusCode) {
            NSLog("[OpenWearablesHealthSDK] background upload rejected (HTTP \(statusCode)) - dropping item")
            removeOutboxFiles(itemPath: itemPath, payloadPath: payloadPath, anchorPath: anchorPath)
            recordPermanentSyncFailure(statusCode: statusCode)
            return
        }

        // 5xx / no response: keep the files for a later retry pass.
        NSLog("[OpenWearablesHealthSDK] background upload failed (HTTP \(statusCode)) - will retry later")
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let handler = OpenWearablesHealthSDK.bgCompletionHandler {
            OpenWearablesHealthSDK.bgCompletionHandler = nil
            handler()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend) * 100
        if Int(progress) % 20 == 0 || progress > 99 {
            NSLog("[OpenWearablesHealthSDK] Upload progress: \(String(format: "%.1f", progress))%% (\(totalBytesSent)/\(totalBytesExpectedToSend) bytes)")
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if backgroundDataBuffer[dataTask.taskIdentifier] == nil {
            backgroundDataBuffer[dataTask.taskIdentifier] = data
        } else {
            backgroundDataBuffer[dataTask.taskIdentifier]?.append(data)
        }
    }
}

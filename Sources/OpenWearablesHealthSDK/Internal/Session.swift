import Foundation
import HealthKit

/// Progress tracking per data type - memory efficient
struct TypeSyncProgress: Codable {
    let typeIdentifier: String
    var sentCount: Int
    var isComplete: Bool
    var pendingAnchorData: Data?
    var pendingOlderThan: Date?
}

/// Lightweight sync state - tracks progress per type instead of all UUIDs
struct SyncState: Codable {
    let userKey: String
    let fullExport: Bool
    let createdAt: Date
    
    var typeProgress: [String: TypeSyncProgress]
    var totalSentCount: Int
    var completedTypes: Set<String>
    var currentTypeIndex: Int
    /// Stable for one historical or live run. Optional so a state file written
    /// before this field existed still decodes; the next attribution call fills it in.
    var sessionId: String?
    /// Stable client rejections pause automatic retries until the host clears the session.
    /// Optional so state files written by older SDK versions continue to decode.
    var permanentFailureStatusCode: Int?
    
    var hasProgress: Bool {
        return totalSentCount > 0 || !completedTypes.isEmpty
    }
    
    /// What the backend `/sync` and `/logs` endpoints already accept.
    var syncType: String {
        fullExport ? "historical" : "live"
    }
}

extension OpenWearablesHealthSDK {
    
    // MARK: - Sync State File
    
    internal func syncStateDir() -> URL {
        return stateBaseDirectory().appendingPathComponent("health_sync_state", isDirectory: true)
    }
    
    internal func ensureSyncStateDir() {
        try? FileManager.default.createDirectory(at: syncStateDir(), withIntermediateDirectories: true)
    }
    
    internal func syncStateFilePath() -> URL {
        return syncStateDir().appendingPathComponent("state.json")
    }
    
    internal func anchorsFilePath() -> URL {
        return syncStateDir().appendingPathComponent("anchors.bin")
    }
    
    // MARK: - Save/Load Sync State
    
    internal func saveSyncState(_ state: SyncState) {
        ensureSyncStateDir()
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: syncStateFilePath(), options: .atomic)
        }
    }
    
    internal func loadSyncState() -> SyncState? {
        guard let data = try? Data(contentsOf: syncStateFilePath()),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return nil
        }
        
        guard state.userKey == userKey() else {
            logMessage("Sync state for different user, clearing")
            clearSyncSession()
            return nil
        }
        
        return state
    }
    
    internal func updateTypeProgress(typeIdentifier: String, sentInChunk: Int, isComplete: Bool, anchorData: Data?, olderThan: Date? = nil) {
        guard var state = loadSyncState() else { return }
        
        var progress = state.typeProgress[typeIdentifier] ?? TypeSyncProgress(
            typeIdentifier: typeIdentifier,
            sentCount: 0,
            isComplete: false,
            pendingAnchorData: nil,
            pendingOlderThan: nil
        )
        
        progress.sentCount += sentInChunk
        progress.isComplete = isComplete
        if let anchorData = anchorData {
            progress.pendingAnchorData = anchorData
        }
        if let olderThan = olderThan {
            progress.pendingOlderThan = olderThan
        }
        
        state.typeProgress[typeIdentifier] = progress
        state.totalSentCount += sentInChunk
        
        if isComplete {
            state.completedTypes.insert(typeIdentifier)
            if let anchorData = progress.pendingAnchorData {
                saveAnchorData(anchorData, typeIdentifier: typeIdentifier, userKey: state.userKey)
            }
        }
        
        saveSyncState(state)
    }
    
    internal func updateCurrentTypeIndex(_ index: Int) {
        guard var state = loadSyncState() else { return }
        state.currentTypeIndex = index
        saveSyncState(state)
    }

    internal func recordPermanentSyncFailure(statusCode: Int) {
        var state = loadSyncState() ?? SyncState(
            userKey: userKey(),
            fullExport: false,
            createdAt: Date(),
            typeProgress: [:],
            totalSentCount: 0,
            completedTypes: [],
            currentTypeIndex: 0,
            sessionId: UUID().uuidString,
            permanentFailureStatusCode: nil
        )
        state.permanentFailureStatusCode = statusCode
        saveSyncState(state)
        logMessage("Sync paused after permanent HTTP \(statusCode); clear or reset the sync session before retrying")
    }

    /// Lift a sync pause left behind by a permanently rejected upload.
    ///
    /// Only the sync state file goes: anchors live in `defaults` and the
    /// initial-export flag in `fullDoneKey()`, so the next round resumes as an
    /// incremental anchored sync instead of re-exporting the whole history.
    /// Outbox items and credentials are untouched.
    ///
    /// - Returns: `true` when a pause existed and was cleared, `false` when
    ///   there was nothing to clear.
    @discardableResult
    public func clearPermanentSyncFailure() -> Bool {
        guard let statusCode = loadSyncState()?.permanentFailureStatusCode else {
            return false
        }

        do {
            try FileManager.default.removeItem(at: syncStateFilePath())
        } catch {
            logMessage("Failed to clear sync pause from permanent HTTP \(statusCode): \(error.localizedDescription)")
            return false
        }

        // Callers start a multi-hour retry throttle after success, so verify
        // that the durable pause is actually gone before reporting success.
        if let remainingStatusCode = loadSyncState()?.permanentFailureStatusCode {
            logMessage("Sync pause clear did not persist; permanent HTTP \(remainingStatusCode) remains")
            return false
        }

        logMessage("Cleared sync pause from permanent HTTP \(statusCode) - next sync resumes incrementally")
        return true
    }
    
    public func clearSyncSession() {
        try? FileManager.default.removeItem(at: syncStateFilePath())
        try? FileManager.default.removeItem(at: anchorsFilePath())
        logMessage("Cleared sync state")
    }
    
    // MARK: - Start New Sync State
    
    /// Session id and type the backend uses to group batches and log events into one
    /// `SyncRun`. Generates and persists an id if the on-disk state predates the field.
    internal func currentSyncAttribution() -> (sessionId: String, syncType: String)? {
        guard var state = loadSyncState() else { return nil }
        if let sessionId = state.sessionId, !sessionId.isEmpty {
            return (sessionId, state.syncType)
        }
        let sessionId = UUID().uuidString
        state.sessionId = sessionId
        saveSyncState(state)
        return (sessionId, state.syncType)
    }
    
    internal func startNewSyncState(fullExport: Bool, types: [HKSampleType]) -> SyncState {
        let state = SyncState(
            userKey: userKey(),
            fullExport: fullExport,
            createdAt: Date(),
            typeProgress: [:],
            totalSentCount: 0,
            completedTypes: [],
            currentTypeIndex: 0,
            sessionId: UUID().uuidString,
            permanentFailureStatusCode: nil
        )
        
        saveSyncState(state)
        return state
    }
    
    // MARK: - Finalize Sync (mark complete)
    
    internal func finalizeSyncState() {
        guard let state = loadSyncState() else { return }
        
        if state.fullExport {
            let fullDoneKey = "fullDone.\(state.userKey)"
            defaults.set(true, forKey: fullDoneKey)
            defaults.synchronize()
            logMessage("Marked full export complete")
        }
        
        logMessage("Sync complete: \(state.totalSentCount) samples across \(state.completedTypes.count) types")
        
        clearSyncSession()
    }
    
    // MARK: - Check for Resumable Session
    
    internal func hasResumableSyncSession() -> Bool {
        guard let state = loadSyncState() else { return false }
        return state.hasProgress
    }
    
    internal func shouldSyncType(_ typeIdentifier: String) -> Bool {
        guard let state = loadSyncState() else { return true }
        return !state.completedTypes.contains(typeIdentifier)
    }
    
    internal func getResumeTypeIndex() -> Int {
        guard let state = loadSyncState() else { return 0 }
        return state.currentTypeIndex
    }
    
    internal func getResumeCursors() -> (completedTypes: Set<String>, olderThanCursors: [String: Date], anchorDataCursors: [String: Data]) {
        guard let state = loadSyncState() else { return ([], [:], [:]) }
        var olderThanCursors: [String: Date] = [:]
        var anchorDataCursors: [String: Data] = [:]
        for (id, progress) in state.typeProgress {
            if !progress.isComplete {
                if let olderThan = progress.pendingOlderThan {
                    olderThanCursors[id] = olderThan
                }
                if let anchorData = progress.pendingAnchorData {
                    anchorDataCursors[id] = anchorData
                }
            }
        }
        return (state.completedTypes, olderThanCursors, anchorDataCursors)
    }
    
    // MARK: - Get Sync Status
    
    internal func getSyncStatusDict() -> [String: Any] {
        // Whether the initial full export (newest-first crawl of the whole history)
        // has ever completed for this user. False = historical sync still pending
        // or in progress; apps can use this to show a "keep the app open" hint.
        let initialExportDone = defaults.bool(forKey: fullDoneKey())
        
        if let state = loadSyncState() {
            return [
                "hasResumableSession": state.hasProgress,
                "sentCount": state.totalSentCount,
                "completedTypes": state.completedTypes.count,
                "isFullExport": state.fullExport,
                "initialExportDone": initialExportDone,
                "isSyncing": isSyncingVisible,
                "hasPermanentFailure": state.permanentFailureStatusCode != nil,
                "permanentFailureStatusCode": (state.permanentFailureStatusCode as Any?) ?? NSNull(),
                "createdAt": ISO8601DateFormatter().string(from: state.createdAt)
            ]
        } else {
            return [
                "hasResumableSession": false,
                "sentCount": 0,
                "completedTypes": 0,
                "isFullExport": false,
                "initialExportDone": initialExportDone,
                "isSyncing": isSyncingVisible,
                "hasPermanentFailure": false,
                "permanentFailureStatusCode": NSNull(),
                "createdAt": NSNull()
            ]
        }
    }
    
    internal func loadSyncSession() -> SyncState? {
        return loadSyncState()
    }
}

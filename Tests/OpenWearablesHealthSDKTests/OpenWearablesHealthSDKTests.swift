import XCTest
@testable import OpenWearablesHealthSDK

final class OpenWearablesHealthSDKTests: XCTestCase {
    
    func testSharedInstanceExists() {
        let sdk = OpenWearablesHealthSDK.shared
        XCTAssertNotNil(sdk)
    }
    
    func testConfigureSetsHost() {
        let sdk = OpenWearablesHealthSDK.shared
        sdk.configure(host: "https://test.example.com")
        // Verify the SDK is configured (host is internal, so we check via credentials)
        let credentials = sdk.getStoredCredentials()
        XCTAssertEqual(credentials["host"] as? String, "https://test.example.com")
    }
    
    func testIsSessionValidWithoutSignIn() {
        let sdk = OpenWearablesHealthSDK.shared
        // Without sign in, session should not be valid (unless prior state exists)
        // This is a basic sanity check
        XCTAssertNotNil(sdk.isSessionValid)
    }
    
    func testGetSyncStatusReturnsValidStructure() {
        let sdk = OpenWearablesHealthSDK.shared
        let status = sdk.getSyncStatus()
        XCTAssertNotNil(status["hasResumableSession"])
        XCTAssertNotNil(status["sentCount"])
        XCTAssertNotNil(status["completedTypes"])
        XCTAssertNotNil(status["isFullExport"])
        XCTAssertNotNil(status["uploadedChunks"])
        XCTAssertNotNil(status["uploadedRecords"])
        XCTAssertNotNil(status["uploadedBytes"])
        XCTAssertNotNil(status["queuedChunks"])
        XCTAssertNotNil(status["queuedRecords"])
        XCTAssertNotNil(status["queuedBytes"])
        XCTAssertNotNil(status["hasPermanentFailure"])
        XCTAssertNotNil(status["permanentFailureStatusCode"])
    }

    func testPayloadChunksRespectEncodedByteAndRecordLimits() throws {
        let sdk = OpenWearablesHealthSDK.shared
        let records: [[String: Any]] = (0..<24).map { index in
            ["id": "record-\(index)", "value": String(repeating: "x", count: 80)]
        }

        let chunks = try sdk.makePayloadChunks(
            workouts: [],
            records: records,
            sleep: [],
            syncTimestamp: "2026-08-31T00:00:00Z",
            maxBytes: 640,
            maxRecords: 4
        )

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.recordCount }, records.count)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.data.count, 640)
            XCTAssertLessThanOrEqual(chunk.recordCount, 4)
            XCTAssertFalse(chunk.isOversized)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: chunk.data))
        }
    }

    func testSingleOversizedRecordIsEmittedAlone() throws {
        let sdk = OpenWearablesHealthSDK.shared
        let chunks = try sdk.makePayloadChunks(
            workouts: [],
            records: [["id": "large", "value": String(repeating: "x", count: 2_000)]],
            sleep: [],
            syncTimestamp: "2026-08-31T00:00:00Z",
            maxBytes: 384,
            maxRecords: 2_000
        )

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].recordCount, 1)
        XCTAssertTrue(chunks[0].isOversized)
        XCTAssertGreaterThan(chunks[0].data.count, 384)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: chunks[0].data))
    }

    func testPermanent4xxPausesWithoutAdvancingProgress() {
        let sdk = OpenWearablesHealthSDK.shared
        sdk.clearSyncSession()
        defer { sdk.clearSyncSession() }

        XCTAssertEqual(sdk.classifyUploadResponse(statusCode: 422), .permanentlyRejected)
        XCTAssertEqual(sdk.classifyUploadResponse(statusCode: 503), .retryableFailure)

        XCTAssertNil(sdk.loadSyncState())
        sdk.recordPermanentSyncFailure(statusCode: 422)

        let state = sdk.loadSyncState()
        XCTAssertEqual(state?.fullExport, false)
        XCTAssertEqual(state?.totalSentCount, 0)
        XCTAssertEqual(state?.uploadedChunkCount, 0)
        XCTAssertEqual(state?.uploadedRecordCount, 0)
        XCTAssertEqual(state?.uploadedByteCount, 0)
        XCTAssertEqual(state?.permanentFailureStatusCode, 422)

        let status = sdk.getSyncStatus()
        XCTAssertEqual(status["hasPermanentFailure"] as? Bool, true)
        XCTAssertEqual(status["permanentFailureStatusCode"] as? Int, 422)
    }

    func testInitialExportKickoffIsSingleFlight() {
        let sdk = OpenWearablesHealthSDK.shared
        sdk.finishInitialSync()
        defer { sdk.finishInitialSync() }

        XCTAssertTrue(sdk.tryStartInitialSync())
        XCTAssertFalse(sdk.tryStartInitialSync())
        XCTAssertTrue(sdk.isInitialSyncActive)
    }

    func testIncrementalTriggerEscalatesUntilInitialExportCompletes() {
        let sdk = OpenWearablesHealthSDK.shared

        XCTAssertTrue(
            sdk.resolveFullExport(
                requestedFullExport: false,
                existingState: nil,
                initialExportDone: false
            )
        )
    }

    func testIncrementalTriggerCannotDowngradeFullExportSession() {
        let sdk = OpenWearablesHealthSDK.shared
        let fullExportState = SyncState(
            userKey: "test-user",
            fullExport: true,
            createdAt: Date(),
            typeProgress: [:],
            totalSentCount: 0,
            completedTypes: [],
            currentTypeIndex: 0,
            uploadedChunkCount: 0,
            uploadedRecordCount: 0,
            uploadedByteCount: 0,
            permanentFailureStatusCode: nil
        )

        XCTAssertTrue(
            sdk.resolveFullExport(
                requestedFullExport: false,
                existingState: fullExportState,
                initialExportDone: true
            )
        )
    }

    func testIncrementalTriggerStaysIncrementalAfterInitialExport() {
        let sdk = OpenWearablesHealthSDK.shared

        XCTAssertFalse(
            sdk.resolveFullExport(
                requestedFullExport: false,
                existingState: nil,
                initialExportDone: true
            )
        )
    }
}

import XCTest
@testable import BiscuitTin

/// Sync scope semantics and persistence (requirement 14, DESIGN.md D17).
final class SyncScopeTests: XCTestCase {

    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "sync-scope-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Scope model

    func testAllScopeHasNoAnchor() {
        XCTAssertNil(SyncScope.all.anchor)
        XCTAssertFalse(SyncScope.all.isNewOnly)
    }

    func testNewOnlyCarriesItsAnchor() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let scope = SyncScope.newOnly(anchor: anchor)
        XCTAssertTrue(scope.isNewOnly)
        XCTAssertEqual(scope.anchor, anchor)
    }

    // MARK: - Persistence

    func testDefaultsToAllBeforeAnyChoice() {
        XCTAssertEqual(settings.syncScope, .all)
        XCTAssertFalse(settings.hasChosenSyncScope,
                       "the scope prompt must still be shown the first time")
        XCTAssertFalse(settings.syncEnabled)
    }

    func testNewOnlyScopeRoundTrips() {
        let anchor = Date(timeIntervalSince1970: 1_755_000_000)
        settings.syncScope = .newOnly(anchor: anchor)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.syncScope.isNewOnly)
        XCTAssertEqual(reloaded.syncScope.anchor?.timeIntervalSince1970 ?? 0,
                       anchor.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(reloaded.hasChosenSyncScope)
    }

    func testAllScopeRoundTripsAndClearsAnchor() {
        settings.syncScope = .newOnly(anchor: Date())
        settings.syncScope = .all

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.syncScope, .all)
        XCTAssertNil(reloaded.syncScope.anchor, "upgrading must clear the anchor")
        XCTAssertTrue(reloaded.hasChosenSyncScope)
    }

    func testEnabledFlagRoundTrips() {
        settings.syncEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).syncEnabled)
        settings.syncEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).syncEnabled)
    }

    /// A stored "new_only" with no anchor would otherwise silently exclude everything.
    func testNewOnlyWithoutAnchorFallsBackToAll() {
        defaults.set("new_only", forKey: "sync.scope")
        defaults.removeObject(forKey: "sync.scopeAnchor")
        XCTAssertEqual(AppSettings(defaults: defaults).syncScope, .all)
    }

    // MARK: - Scope filtering

    /// The rule the enumeration step applies: capture date before the anchor is excluded.
    func testAnchorPartitionsAssetsByCaptureDate() {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let scope = SyncScope.newOnly(anchor: anchor)

        func isExcluded(captureDate: Date) -> Bool {
            scope.anchor.map { captureDate < $0 } ?? false
        }

        XCTAssertTrue(isExcluded(captureDate: anchor.addingTimeInterval(-1)))
        XCTAssertFalse(isExcluded(captureDate: anchor),
                       "an asset captured exactly at the anchor is included")
        XCTAssertFalse(isExcluded(captureDate: anchor.addingTimeInterval(1)))
    }

    func testAllScopeExcludesNothing() {
        let scope = SyncScope.all
        for offset in [-1_000_000.0, 0, 1_000_000.0] {
            let date = Date(timeIntervalSince1970: 1_000_000 + offset)
            XCTAssertFalse(scope.anchor.map { date < $0 } ?? false)
        }
    }

    // MARK: - Backup state

    func testOutstandingStatesDriveTheBadge() {
        // Uploaded and ineligible are settled; out_of_scope was deliberately excluded, so none
        // of them should make the grid show a pending count.
        let outstanding = Set(BackupStateRecord.outstandingStates)
        XCTAssertEqual(outstanding, ["pending", "uploading", "failed"])
        XCTAssertFalse(outstanding.contains(BackupStateRecord.State.uploaded.rawValue))
        XCTAssertFalse(outstanding.contains(BackupStateRecord.State.outOfScope.rawValue))
        XCTAssertFalse(outstanding.contains(BackupStateRecord.State.ineligible.rawValue))
    }

    func testBackupStateRecordDefaults() {
        let record = BackupStateRecord(localIdentifier: "abc")
        XCTAssertEqual(record.backupState, .pending)
        XCTAssertEqual(record.retryCount, 0)
        XCTAssertNil(record.checksumHex)
    }

    @MainActor
    func testStatusStoreIndicatorReflectsState() {
        let store = BackupStatusStore()

        store.update(remaining: 0, uploading: false, enabled: false)
        XCTAssertEqual(store.indicatorSymbol, "icloud.slash")

        store.update(remaining: 12, uploading: false, enabled: true)
        XCTAssertEqual(store.indicatorSymbol, "icloud.and.arrow.up")

        store.update(remaining: 12, uploading: true, enabled: true)
        XCTAssertEqual(store.indicatorSymbol, "arrow.up.circle")

        store.update(remaining: 0, uploading: false, enabled: true)
        XCTAssertEqual(store.indicatorSymbol, "checkmark.icloud")
    }

    @MainActor
    func testInfoBarCountsProgressSinceQueueWasLastEmpty() {
        let store = BackupStatusStore()
        store.update(remaining: 40, uploading: false, enabled: true)
        XCTAssertEqual(store.infoBarText, "0/40 · Queued")

        store.setPhase(.uploading)
        store.update(remaining: 37, uploading: true, enabled: true)
        XCTAssertEqual(store.infoBarText, "3/40 · Uploading")

        store.setUploadRate(47_000)
        XCTAssertEqual(store.infoBarText, "3/40 · Uploading 376 kbps")

        // New photos taken mid-run grow the total rather than resetting progress.
        store.update(remaining: 39, uploading: true, enabled: true)
        XCTAssertEqual(store.infoBarText, "3/42 · Uploading 376 kbps")

        store.update(remaining: 0, uploading: false, enabled: true)
        XCTAssertNil(store.infoBarText, "bar hides once everything is backed up")
        XCTAssertEqual(store.stateText, "All backed up", "Settings still says so")

        store.update(remaining: 90, uploading: false, enabled: true)
        store.setPhase(.waitingForNetwork)
        XCTAssertEqual(store.infoBarText, "0/90 · Waiting for network")
        XCTAssertEqual(store.infoBarSymbol, "wifi.slash")

        store.update(remaining: 90, uploading: false, enabled: false)
        XCTAssertNil(store.infoBarText, "bar hides when sync is off")
    }

    @MainActor
    func testInfoBarExplainsAStalledQueue() {
        let store = BackupStatusStore()
        store.update(remaining: 2, uploading: false, enabled: true, failed: 2)
        XCTAssertEqual(store.infoBarText, "0/2 · 2 failed")
        XCTAssertEqual(store.infoBarSymbol, "exclamationmark.icloud")

        store.update(remaining: 3, uploading: false, enabled: true, retrying: 3)
        XCTAssertEqual(store.infoBarText, "0/3 · 3 to retry")

        // Rates only show while uploading: a stale one would read as current.
        store.setUploadRate(1_000_000)
        XCTAssertEqual(store.infoBarText, "0/3 · 3 to retry")
    }

    @MainActor
    func testInfoBarSeparatesRateFromState() {
        let store = BackupStatusStore()
        store.update(remaining: 10, uploading: true, enabled: true)
        store.setPhase(.preparing)
        XCTAssertEqual(store.stateTitle, "Preparing")
        XCTAssertNil(store.rateText)

        store.setPhase(.uploading)
        store.setUploadRate(100_000)
        XCTAssertEqual(store.stateTitle, "Uploading")
        XCTAssertEqual(store.rateText, "800 kbps")

        // One upload finishing makes the raw rate swing; the reading moves part of the way.
        store.setUploadRate(200_000)
        XCTAssertEqual(store.rateText, "1.1 Mbps")

        // Leaving the uploading phase drops the rate, so the next one starts afresh.
        store.setPhase(.preparing)
        XCTAssertNil(store.rateText)
        store.setPhase(.uploading)
        store.setUploadRate(200_000)
        XCTAssertEqual(store.rateText, "1.6 Mbps")
    }

    func testBitRateFormatting() {
        XCTAssertEqual(BackupStatusStore.formatBitRate(bytesPerSecond: 47_000), "376 kbps")
        XCTAssertEqual(BackupStatusStore.formatBitRate(bytesPerSecond: 10), "1 kbps")
        XCTAssertEqual(BackupStatusStore.formatBitRate(bytesPerSecond: 300_000), "2.4 Mbps")
        XCTAssertEqual(BackupStatusStore.formatBitRate(bytesPerSecond: 5_000_000), "40 Mbps")
    }

    func testTransferRateMeterAveragesOverObservedTime() {
        let meter = TransferRateMeter()
        XCTAssertNil(meter.bytesPerSecond(at: 0))
        meter.record(bytes: 1_000, at: 100)
        meter.record(bytes: 1_000, at: 101)
        XCTAssertEqual(meter.bytesPerSecond(at: 102)!, 1_000, accuracy: 0.001)
        // Once samples leave the window, a stalled upload reads as zero, not as its old rate.
        XCTAssertEqual(meter.bytesPerSecond(at: 110)!, 0, accuracy: 0.001)
    }

    @MainActor
    func testWaitReasonSurvivesTheStatusRefreshThatFollowsIt() {
        let store = BackupStatusStore()
        store.setPhase(.waitingForWiFi)
        store.update(remaining: 5, uploading: false, enabled: true)
        XCTAssertEqual(store.infoBarText, "0/5 · Waiting for Wi-Fi")

        store.setPhase(.noPhotoAccess)
        store.update(remaining: 5, uploading: false, enabled: true)
        XCTAssertEqual(store.stateText, "No photo access")

        // A run that starts and finishes clears the wait.
        store.setPhase(.scanning)
        store.update(remaining: 5, uploading: false, enabled: true)
        XCTAssertEqual(store.phase, .idle)
    }

    func testCellularIsOffByDefault() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.syncAllowsCellular)
        settings.syncAllowsCellular = true
        XCTAssertTrue(AppSettings(defaults: defaults).syncAllowsCellular)
    }
}

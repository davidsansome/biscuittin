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
        XCTAssertNil(store.indicatorText, "indicator is hidden when sync is off")

        store.update(remaining: 12, uploading: false, enabled: true)
        XCTAssertEqual(store.indicatorText, "12")
        XCTAssertEqual(store.indicatorSymbol, "icloud.and.arrow.up")

        store.update(remaining: 12, uploading: true, enabled: true)
        XCTAssertEqual(store.indicatorSymbol, "arrow.up.circle")

        store.update(remaining: 0, uploading: false, enabled: true)
        XCTAssertNil(store.indicatorText, "no count once everything is backed up")
        XCTAssertEqual(store.indicatorSymbol, "checkmark.icloud")
    }
}

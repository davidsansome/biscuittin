import XCTest
@testable import BiscuitTin

/// Multi-select state machine (requirement 11).
final class SelectionControllerTests: XCTestCase {

    private func id(_ raw: String) -> AssetID { AssetID(raw: raw) }

    func testStartsInactiveAndEmpty() {
        let selection = SelectionController()
        XCTAssertFalse(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }

    func testBeginActivatesWithThePressedAsset() {
        let selection = SelectionController()
        selection.begin(with: id("a"))
        XCTAssertTrue(selection.isActive)
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(selection.contains(id("a")))
    }

    func testToggleAddsAndRemoves() {
        let selection = SelectionController()
        selection.begin(with: id("a"))
        selection.toggle(id("b"))
        XCTAssertEqual(selection.count, 2)

        selection.toggle(id("b"))
        XCTAssertEqual(selection.count, 1)
        XCTAssertFalse(selection.contains(id("b")))
    }

    func testToggleIsIgnoredWhenInactive() {
        let selection = SelectionController()
        selection.toggle(id("a"))
        XCTAssertFalse(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }

    /// A long press while already selecting should toggle rather than restart the selection.
    func testBeginWhileActiveTogglesInstead() {
        let selection = SelectionController()
        selection.begin(with: id("a"))
        selection.toggle(id("b"))
        selection.begin(with: id("c"))
        XCTAssertEqual(selection.count, 3)
        XCTAssertTrue(selection.contains(id("a")))
    }

    /// Deselecting everything keeps the mode active — the user is still selecting, just with
    /// nothing chosen, and the toolbar disables itself rather than the mode vanishing.
    func testEmptyingSelectionKeepsModeActive() {
        let selection = SelectionController()
        selection.begin(with: id("a"))
        selection.toggle(id("a"))
        XCTAssertTrue(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }

    func testEndClearsEverything() {
        let selection = SelectionController()
        selection.begin(with: id("a"))
        selection.end()
        XCTAssertFalse(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }

    /// Assets can vanish underneath a live selection — deleted here, or removed on another
    /// device and reported by a sync.
    func testRetainDropsAssetsThatNoLongerExist() {
        let selection = SelectionController()
        selection.begin(with: id("a"))
        selection.toggle(id("b"))
        selection.toggle(id("c"))

        selection.retain(only: [id("a"), id("c")])
        XCTAssertEqual(selection.count, 2)
        XCTAssertFalse(selection.contains(id("b")))
    }

    func testRetainOnlyNotifiesWhenSomethingChanged() {
        let selection = SelectionController()
        selection.begin(with: id("a"))

        var notifications = 0
        selection.onChange = { notifications += 1 }

        selection.retain(only: [id("a"), id("b")])
        XCTAssertEqual(notifications, 0, "a no-op retain must not churn the UI")

        selection.retain(only: [id("b")])
        XCTAssertEqual(notifications, 1)
    }

    func testChangeNotificationsFireForEachMutation() {
        let selection = SelectionController()
        var notifications = 0
        selection.onChange = { notifications += 1 }

        selection.begin(with: id("a"))   // 1
        selection.toggle(id("b"))        // 2
        selection.toggle(id("b"))        // 3
        selection.end()                  // 4
        XCTAssertEqual(notifications, 4)

        selection.end()
        XCTAssertEqual(notifications, 4, "ending an inactive selection must be a no-op")
    }
}

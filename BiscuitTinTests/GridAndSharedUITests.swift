import UIKit
import XCTest
@testable import BiscuitTin

final class GridAndSharedUITests: XCTestCase {

    private struct SampleLocalizedError: LocalizedError {
        let errorDescription: String?
    }

    func testToastMessageUsesVerbForSkippedUnsupported() {
        let outcome = ActionOutcome(succeeded: [],
                                    failures: [],
                                    skippedUnsupported: [AssetID(raw: "a"), AssetID(raw: "b")])
        XCTAssertEqual(Toast.message(for: outcome, verb: "deleted"), "2 items can’t be deleted yet")
        XCTAssertEqual(Toast.message(for: outcome, verb: "rotated"), "2 items can’t be rotated yet")
    }

    func testToastMessageUsesLocalizedErrorDescription() {
        let error = SampleLocalizedError(errorDescription: "Server unreachable")
        let outcome = ActionOutcome(succeeded: [],
                                    failures: [(AssetID(raw: "a"), error)],
                                    skippedUnsupported: [])
        XCTAssertEqual(Toast.message(for: outcome, verb: "deleted"), "Server unreachable")
    }

    @MainActor
    func testToastReplacesExistingToastInSameView() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        Toast.show("First", in: host, duration: 10)
        XCTAssertEqual(host.subviews.count, 1)
        Toast.show("Second", in: host, duration: 10)
        XCTAssertEqual(host.subviews.count, 1)
    }

    @MainActor
    func testAssetCellDurationTextDelegatesSafely() {
        XCTAssertEqual(AssetCell.durationText(4), "0:04")
        XCTAssertEqual(AssetCell.durationText(75), "1:15")
        XCTAssertEqual(AssetCell.durationText(3661), "1:01:01")
        XCTAssertEqual(AssetCell.durationText(.nan), "0:00")
        XCTAssertEqual(AssetCell.durationText(-5), "0:00")
    }

    @MainActor
    func testMapDragHandleAdjustableCallbacks() {
        let handle = MapDragHandle()
        var increments = 0
        var decrements = 0
        handle.onIncrement = { increments += 1 }
        handle.onDecrement = { decrements += 1 }

        handle.accessibilityIncrement()
        handle.accessibilityDecrement()

        XCTAssertEqual(increments, 1)
        XCTAssertEqual(decrements, 1)
    }

    func testGridLayoutProviderClampsColumns() {
        XCTAssertEqual(GridLayoutProvider.clampedColumns(0), AppSettings.minColumns)
        XCTAssertEqual(GridLayoutProvider.clampedColumns(100), AppSettings.maxColumns)
    }
}

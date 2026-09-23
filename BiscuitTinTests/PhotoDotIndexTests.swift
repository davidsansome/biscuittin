import MapKit
import XCTest
@testable import BiscuitTin

/// The map shows one dot per dot-sized cell rather than one per photo (DESIGN.md §20).
final class PhotoDotIndexTests: XCTestCase {

    /// Offsets are from the middle of the map: near its edges, latitudes past ~85° do not survive
    /// the round trip through `CLLocationCoordinate2D`.
    private static let origin = MKMapPoint(x: MKMapRect.world.midX, y: MKMapRect.world.midY)

    private func index(_ points: [(Double, Double)]) -> PhotoDotIndex {
        PhotoDotIndex(coordinates: points.map {
            MKMapPoint(x: Self.origin.x + $0.0, y: Self.origin.y + $0.1).coordinate
        })
    }

    private let everywhere = MKMapRect.world

    func testPhotosInOneCellShareADot() {
        let dots = index([(1000, 1000), (1001, 1002), (1003, 1001)]).dots(in: everywhere, cellSize: 16)
        XCTAssertEqual(dots.count, 1)
    }

    func testPhotosInDifferentCellsEachGetADot() {
        let dots = index([(1000, 1000), (1100, 1000), (1000, 1100)]).dots(in: everywhere, cellSize: 16)
        XCTAssertEqual(dots.count, 3)
    }

    func testOnlyPhotosInsideTheRegionAreShown() {
        let photos = index([(1000, 1000), (5000, 1000), (1000, 5000)])
        let region = MKMapRect(x: Self.origin.x, y: Self.origin.y, width: 2000, height: 2000)
        XCTAssertEqual(photos.dots(in: region, cellSize: 16).count, 1)
    }

    /// A dot sits where a photo was taken, not at the centre of its cell.
    func testADotIsAtARealPhotoLocation() {
        let dot = index([(1003.5, 1007.25)]).dots(in: everywhere, cellSize: 16).first
        XCTAssertEqual(dot?.point.x ?? 0, Self.origin.x + 1003.5, accuracy: 0.01)
        XCTAssertEqual(dot?.point.y ?? 0, Self.origin.y + 1007.25, accuracy: 0.01)
    }

    /// Cells are rounded to a power of two, so a small zoom keeps every dot rather than
    /// replacing the whole annotation set.
    func testSmallZoomChangesKeepTheSameCells() {
        let photos = index((0..<200).map { (Double($0) * 37, Double($0 % 13) * 53) })
        XCTAssertEqual(photos.dots(in: everywhere, cellSize: 30), photos.dots(in: everywhere, cellSize: 34))
    }

    func testNoPhotosMeansNoDots() {
        XCTAssertTrue(index([]).dots(in: everywhere, cellSize: 16).isEmpty)
    }
}

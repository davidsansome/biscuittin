import MapKit

/// Decides which photo dots the map actually shows.
///
/// Dots were first one annotation per located photo. At 63k photos MapKit asked for 63k
/// annotation views on opening (1.9 s on the main thread on an iPhone 13) and blocked for up to
/// 7 s while zooming. A dot drawn on top of another in the same spot adds nothing, so the map
/// shows one per dot-sized cell of what is on screen: the annotation count is bounded by screen
/// area, not by the library.
///
/// An `MKOverlay` drawing every dot was tried and dropped: MapKit renders overlay tiles at whole
/// zoom levels and scales them in between, so dots grew from 30 to 58 px across one zoom level.
struct PhotoDotIndex {
    /// A dot to show: a real photo's location, standing for everything else in its cell.
    struct Dot: Hashable {
        /// Cell position in a grid anchored at the map origin, so panning at a fixed zoom keeps
        /// the same keys and only the edges change.
        let cellX: Int64
        let cellY: Int64
        let point: MKMapPoint

        static func == (lhs: Dot, rhs: Dot) -> Bool { lhs.cellX == rhs.cellX && lhs.cellY == rhs.cellY }
        func hash(into hasher: inout Hasher) {
            hasher.combine(cellX)
            hasher.combine(cellY)
        }
    }

    /// Sorted by `x`, so a region finds its points by binary search rather than a full scan.
    private let points: [MKMapPoint]

    init(coordinates: [CLLocationCoordinate2D]) {
        points = coordinates.map(MKMapPoint.init).sorted { $0.x < $1.x }
    }

    /// One dot per occupied cell of side `cellSize` (map points) inside `rect`.
    ///
    /// `cellSize` is rounded to a power of two, so small zoom changes keep the same cells and do
    /// not churn every annotation.
    func dots(in rect: MKMapRect, cellSize: Double) -> Set<Dot> {
        guard cellSize > 0, !points.isEmpty else { return [] }
        let cell = Self.quantized(cellSize)
        var dots = Set<Dot>()
        var i = firstIndex(atOrAfterX: rect.minX)
        while i < points.count, points[i].x <= rect.maxX {
            let point = points[i]
            i += 1
            guard point.y >= rect.minY, point.y <= rect.maxY else { continue }
            dots.insert(Dot(cellX: Int64((point.x / cell).rounded(.down)),
                            cellY: Int64((point.y / cell).rounded(.down)),
                            point: point))
        }
        return dots
    }

    static func quantized(_ cellSize: Double) -> Double {
        pow(2, log2(cellSize).rounded())
    }

    private func firstIndex(atOrAfterX x: Double) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].x < x { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

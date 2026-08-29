import UIKit
import MapKit

/// Split-screen map and grid: a map of where photos were taken above, the photos in the visible
/// region below (DESIGN.md §20).
///
/// The grid half is a real `GridViewController` in a fixed, externally-supplied mode rather than
/// a second grid implementation — so tiles, prefetching, pinch columns, multi-select and the
/// zoom transition into the viewer all behave exactly as they do on the home screen, because
/// they *are* the same code.
final class MapViewController: UIViewController {

    private let env: AppEnvironment
    /// Clips the map. Only this changes height when the bar moves — see `configureMap`.
    private let mapContainer = UIView()
    private let mapView = MKMapView()
    private let dragHandle = MapDragHandle()
    private var gridController: GridViewController!

    /// The bar rests at one of two heights; dragging snaps between them.
    ///
    /// Free positioning was tried first and was disorienting: shrinking the map narrowed its
    /// visible region, which silently dropped photos out of the grid, so a gesture about *layout*
    /// changed *content*. The two stops, plus the region decoupling in `filterMapRect`, keep the
    /// grid showing the same photos at either height.
    enum SplitPosition {
        /// Bar at the midpoint — map and grid share the screen.
        case centered
        /// Bar near the top — the grid gets almost everything, the map stays as an orientation
        /// strip rather than disappearing.
        case raised

        var fraction: CGFloat {
            switch self {
            case .centered: return 0.5
            case .raised: return 0.1
            }
        }
    }

    private var position: SplitPosition = .centered
    /// Live height fraction during a drag; settles onto `position.fraction` on release.
    private var mapFraction: CGFloat = SplitPosition.centered.fraction
    private var mapHeightConstraint: NSLayoutConstraint!
    private var mapViewHeightConstraint: NSLayoutConstraint!
    private var dragStartFraction: CGFloat = 0

    /// All stubs that carry a coordinate, held once. Filtering per map move is a scan over this
    /// rather than a query, which is what lets the grid track a pan without lag (§20.1).
    private var located: [AssetStub] = []
    private var annotationsByID: [AssetID: MKPointAnnotation] = [:]
    private var regionChangeWork: DispatchWorkItem?

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureMap()
        configureGrid()
        configureHandle()
        configureCloseButton()

        loadLocatedAssets()
    }

    // MARK: - Setup

    /// The map is a **fixed-height view inside a clipping container**; raising the bar shrinks the
    /// container, never the map.
    ///
    /// Resizing the map itself was tried first and was subtly wrong. `MKMapView` re-adjusts its
    /// own region after a resize — instrumenting the filter showed two region callbacks per drag,
    /// the first preserving zoom and a second with a completely different region, which collapsed
    /// the grid to zero photos. Compensating arithmetic was chasing a moving target. With a fixed
    /// map, `visibleMapRect` simply does not change when the split moves, so the filter is
    /// invariant by construction rather than by correction, and raising the bar reveals the
    /// middle strip of the same map.
    private func configureMap() {
        mapContainer.clipsToBounds = true
        mapContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapContainer)

        mapView.delegate = self
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.showsUserLocation = false      // the feature is about photos, not the viewer
        mapView.pointOfInterestFilter = .excludingAll
        mapView.register(PhotoDotAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: PhotoDotAnnotationView.reuseIdentifier)
        mapContainer.addSubview(mapView)

        mapHeightConstraint = mapContainer.heightAnchor.constraint(equalToConstant: 0)
        mapViewHeightConstraint = mapView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            mapContainer.topAnchor.constraint(equalTo: view.topAnchor),
            mapContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapHeightConstraint,

            mapView.leadingAnchor.constraint(equalTo: mapContainer.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: mapContainer.trailingAnchor),
            // Centred, so the raised strip shows the middle of the region rather than its top.
            mapView.centerYAnchor.constraint(equalTo: mapContainer.centerYAnchor),
            mapViewHeightConstraint
        ])
    }

    private func configureGrid() {
        // `.map` suppresses the home screen's own chrome (search bar, date scrubber, settings
        // items) — none of which belong in a half-height panel filtered by geography.
        gridController = GridViewController(env: env, mode: .map)
        addChild(gridController)
        gridController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gridController.view)
        gridController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            gridController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureHandle() {
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dragHandle.topAnchor.constraint(equalTo: mapContainer.bottomAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: MapDragHandle.height),
            gridController.view.topAnchor.constraint(equalTo: dragHandle.bottomAnchor)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        dragHandle.addGestureRecognizer(pan)
        // Tapping the bar toggles between the two useful extremes, which is faster than
        // dragging when the user just wants the photos.
        dragHandle.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                               action: #selector(toggleExpansion)))
    }

    private func configureCloseButton() {
        let close = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "xmark",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        close.configuration = config
        close.accessibilityLabel = "Close map"
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        // Above the map so it stays reachable however far the map is collapsed.
        view.addSubview(close)
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])
        close.layer.shadowColor = UIColor.black.cgColor
        close.layer.shadowOpacity = 0.2
        close.layer.shadowRadius = 4
        close.layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyMapFraction(animated: false)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    // MARK: - Data

    private func loadLocatedAssets() {
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.env.timelineStore.currentSnapshot()
            let located = snapshot.flattened().filter(\.hasCoordinate)
            await MainActor.run {
                self.located = located
                self.populateAnnotations()
                self.showInitialRegion()
            }
        }
    }

    private func populateAnnotations() {
        mapView.removeAnnotations(mapView.annotations)
        annotationsByID.removeAll()

        var annotations = [MKPointAnnotation]()
        annotations.reserveCapacity(located.count)
        for stub in located {
            guard let coordinate = stub.coordinate else { continue }
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            annotations.append(annotation)
            annotationsByID[stub.id] = annotation
        }
        mapView.addAnnotations(annotations)
    }

    /// Opens on everything that has a location, so the user starts with the whole picture and
    /// zooms into what interests them.
    private func showInitialRegion() {
        guard !located.isEmpty else {
            updateGridForVisibleRegion()
            return
        }
        let coordinates = located.compactMap(\.coordinate)
        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        let padding = UIEdgeInsets(top: 60, left: 40, bottom: 40, right: 40)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        updateGridForVisibleRegion()
    }

    /// Filters the grid to the map's region.
    ///
    /// Uses `MKMapRect` containment rather than latitude/longitude comparison: a longitude range
    /// straddling the antimeridian is not a simple interval, and `MKMapRect` already handles
    /// that wrap correctly.
    private func updateGridForVisibleRegion() {
        let region = mapView.visibleMapRect
        let matching = located.filter { stub in
            guard let coordinate = stub.coordinate else { return false }
            return region.contains(MKMapPoint(coordinate))
        }
        gridController.showExternalSnapshot(Self.snapshot(for: matching))
    }


    /// One bucket, newest first — `located` comes from the flattened timeline, which is already
    /// in that order, so the filter preserves it.
    private static func snapshot(for stubs: [AssetStub]) -> TimelineSnapshot {
        guard !stubs.isEmpty else {
            return TimelineSnapshot(grouping: .day, buckets: [], totalCount: 0, provenance: .live)
        }
        let title = stubs.count == 1 ? "1 photo here" : "\(stubs.count) photos here"
        return TimelineSnapshot(grouping: .day,
                                buckets: [.init(id: "map-region", title: title, items: stubs)],
                                totalCount: stubs.count,
                                provenance: .live)
    }

    // MARK: - Split behaviour

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        let available = availableHeight()
        guard available > 0 else { return }

        switch gesture.state {
        case .began:
            dragStartFraction = mapFraction
        case .changed:
            // The bar tracks the finger between the two stops so the drag feels direct, but it
            // cannot be left anywhere in between.
            let translation = gesture.translation(in: view).y
            mapFraction = clamped(dragStartFraction + translation / available)
            applyMapFraction(animated: false)
        case .ended, .cancelled:
            // Project where the flick was heading, so a quick swipe lands on the far stop even
            // when the finger stopped short of the midpoint.
            let velocity = gesture.velocity(in: view).y
            let projected = clamped(mapFraction + (velocity / available) * 0.15)
            let midpoint = (SplitPosition.raised.fraction + SplitPosition.centered.fraction) / 2
            settle(on: projected < midpoint ? .raised : .centered)
        default:
            break
        }
    }

    @objc private func toggleExpansion() {
        settle(on: position == .centered ? .raised : .centered)
    }

    private func settle(on newPosition: SplitPosition) {
        position = newPosition
        mapFraction = newPosition.fraction
        applyMapFraction(animated: true)
        dragHandle.setRaised(newPosition == .raised)
    }

    private func clamped(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, SplitPosition.raised.fraction), SplitPosition.centered.fraction)
    }

    private func availableHeight() -> CGFloat {
        max(0, view.bounds.height - MapDragHandle.height)
    }

    private func applyMapFraction(animated: Bool) {
        mapHeightConstraint.constant = availableHeight() * mapFraction
        // Fixed at the centred height whatever the split is doing, so the map's own region — and
        // therefore the grid's filter — never moves when the bar does.
        mapViewHeightConstraint.constant = availableHeight() * SplitPosition.centered.fraction
        guard animated else {
            view.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: 0.3, delay: 0,
                       usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4) {
            self.view.layoutIfNeeded()
        }
    }
}

// MARK: - Map delegate

extension MapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        mapView.dequeueReusableAnnotationView(withIdentifier: PhotoDotAnnotationView.reuseIdentifier,
                                              for: annotation)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        // A pan fires this continuously. Re-filtering and re-applying a diffable snapshot per
        // callback would fight the gesture, so coalesce to the end of the movement (§14 P4).
        regionChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateGridForVisibleRegion() }
        regionChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

/// A plain red dot. Deliberately not a pin or a cluster: at photo densities the useful signal is
/// *where photographs happened*, which reads better as a scatter than as annotated markers.
private final class PhotoDotAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "PhotoDot"
    private static let size: CGFloat = 9

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        backgroundColor = .systemRed
        layer.cornerRadius = Self.size / 2
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        // Dots are a density display, not tap targets — the grid below is how photos are opened.
        isEnabled = false
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

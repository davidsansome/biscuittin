import Foundation

/// Backs the info sheet. Publishes the stub-derived subset synchronously so the sheet can be
/// presented on the same runloop tick as the tap (§14 P4), then fills in the slower sources.
@MainActor
final class InfoViewModel: ObservableObject {
    @Published private(set) var metadata: AssetMetadata
    @Published private(set) var isLoading = true

    private let stub: AssetStub
    private let timelineStore: TimelineStore
    private let metadataService: MetadataService
    private var loadTask: Task<Void, Never>?

    init(stub: AssetStub, timelineStore: TimelineStore, metadataService: MetadataService) {
        self.stub = stub
        self.timelineStore = timelineStore
        self.metadataService = metadataService
        self.metadata = AssetMetadata(stub: stub)
    }

    deinit { loadTask?.cancel() }

    func load() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            guard let asset = await self.timelineStore.asset(for: self.stub.id) else {
                self.isLoading = false
                return
            }
            let full = await self.metadataService.metadata(for: asset)
            guard !Task.isCancelled else { return }
            self.metadata = full
            self.isLoading = false
        }
    }

    var title: String {
        switch stub.kind {
        case .video: return "Video"
        case .livePhoto: return "Live Photo"
        case .image: return "Photo"
        }
    }
}

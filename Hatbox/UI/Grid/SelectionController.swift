import Foundation

/// Multi-select state for the grid (requirement 11).
///
/// Deliberately dumb: it owns only membership and notifies on change. The grid decides what
/// that means visually, and `PhotoActionService` decides what it means for actions.
final class SelectionController {
    private(set) var isActive = false
    private(set) var selected: Set<AssetID> = []

    /// Fires whenever activation or membership changes.
    var onChange: (() -> Void)?

    var count: Int { selected.count }
    var isEmpty: Bool { selected.isEmpty }
    var orderedIDs: [AssetID] { Array(selected) }

    /// Enters selection mode with the long-pressed asset already selected.
    func begin(with id: AssetID) {
        guard !isActive else {
            toggle(id)
            return
        }
        isActive = true
        selected = [id]
        onChange?()
    }

    func toggle(_ id: AssetID) {
        guard isActive else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        onChange?()
    }

    func contains(_ id: AssetID) -> Bool { selected.contains(id) }

    func end() {
        guard isActive else { return }
        isActive = false
        selected.removeAll()
        onChange?()
    }

    /// Drops ids that no longer exist — after a delete, or after the timeline reconciles.
    func retain(only present: Set<AssetID>) {
        guard isActive else { return }
        let filtered = selected.intersection(present)
        guard filtered != selected else { return }
        selected = filtered
        onChange?()
    }
}

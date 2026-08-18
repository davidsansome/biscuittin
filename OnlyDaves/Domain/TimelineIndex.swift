import Foundation

/// The date-sorted asset index, extracted as a pure value type.
///
/// `TimelineStore` owns one of these. Keeping the ordering logic here (rather than inline in
/// the actor) is what makes the D20 invariant testable: a sequence of incremental mutations
/// must leave exactly the array a full rebuild would have produced.
struct TimelineIndex: Equatable {
    /// Newest first. Also the viewer's flattened paging order.
    private(set) var stubs: [AssetStub]

    init(_ stubs: [AssetStub] = []) {
        self.stubs = stubs
    }

    var count: Int { stubs.count }
    var isEmpty: Bool { stubs.isEmpty }

    /// Replaces the whole index, sorting only when the input is not already ordered.
    mutating func replaceAll(_ newStubs: [AssetStub]) {
        stubs = Self.isSortedNewestFirst(newStubs)
            ? newStubs
            : newStubs.sorted { $0.captureDate > $1.captureDate }
    }

    /// Inserts stubs, ignoring ones already present. Uses a linear merge for bulk inserts
    /// and binary-search splices for small ones.
    mutating func insert(_ incoming: [AssetStub]) {
        guard !incoming.isEmpty else { return }
        let existing = Set(stubs.map(\.id))
        let fresh = incoming.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }

        let sorted = fresh.sorted { $0.captureDate > $1.captureDate }
        if sorted.count > 64 {
            stubs = Self.merge(stubs, sorted)
        } else {
            for stub in sorted {
                stubs.insert(stub, at: insertionIndex(for: stub.captureDate))
            }
        }
    }

    @discardableResult
    mutating func remove(_ ids: [AssetID]) -> Bool {
        guard !ids.isEmpty else { return false }
        let doomed = Set(ids)
        let before = stubs.count
        stubs.removeAll { doomed.contains($0.id) }
        return stubs.count != before
    }

    /// Replaces stubs by identity. Implemented as remove-then-insert because an edited
    /// capture date can move an item, and that keeps the sort invariant true by construction.
    mutating func update(_ changed: [AssetStub]) {
        guard !changed.isEmpty else { return }
        let ids = Set(changed.map(\.id))
        stubs.removeAll { ids.contains($0.id) }
        insert(changed)
    }

    func contains(_ id: AssetID) -> Bool {
        stubs.contains { $0.id == id }
    }

    func stub(for id: AssetID) -> AssetStub? {
        stubs.first { $0.id == id }
    }

    func neighbors(of id: AssetID) -> (prev: AssetID?, next: AssetID?) {
        guard let position = stubs.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
        return (position > 0 ? stubs[position - 1].id : nil,
                position + 1 < stubs.count ? stubs[position + 1].id : nil)
    }

    /// First position whose capture date is not newer than `date`, in a newest-first array.
    func insertionIndex(for date: Date) -> Int {
        var low = 0
        var high = stubs.count
        while low < high {
            let mid = (low + high) / 2
            if stubs[mid].captureDate > date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - Helpers

    static func isSortedNewestFirst(_ stubs: [AssetStub]) -> Bool {
        guard stubs.count > 1 else { return true }
        for i in 1..<stubs.count where stubs[i - 1].captureDate < stubs[i].captureDate {
            return false
        }
        return true
    }

    static func merge(_ a: [AssetStub], _ b: [AssetStub]) -> [AssetStub] {
        var out = [AssetStub]()
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i].captureDate >= b[j].captureDate { out.append(a[i]); i += 1 }
            else { out.append(b[j]); j += 1 }
        }
        if i < a.count { out.append(contentsOf: a[i...]) }
        if j < b.count { out.append(contentsOf: b[j...]) }
        return out
    }
}

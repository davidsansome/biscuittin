import Foundation

/// How the grid groups the timeline into sections (requirement 3).
enum Grouping: String, CaseIterable, Codable {
    case day, week, month

    var calendarComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    var localizedName: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
}

/// An immutable view of the whole timeline, handed to the grid (DESIGN.md §6.2).
struct TimelineSnapshot {
    /// Whether this snapshot came from the launch boot cache or the live index (D19).
    /// The grid shows a subtle activity hint while it is still `.bootCache`.
    enum Provenance { case bootCache, live }

    struct Bucket: Identifiable, Hashable {
        let id: String
        let title: String
        let items: [AssetStub]
    }

    let grouping: Grouping
    let buckets: [Bucket]
    let totalCount: Int
    let provenance: Provenance

    static func empty(grouping: Grouping, provenance: Provenance = .live) -> TimelineSnapshot {
        TimelineSnapshot(grouping: grouping, buckets: [], totalCount: 0, provenance: provenance)
    }

    var isEmpty: Bool { totalCount == 0 }

    /// Resolves a section/item position to its stub. O(1); used by the grid's cell provider.
    func stub(at indexPath: IndexPath) -> AssetStub? {
        guard indexPath.section >= 0, indexPath.section < buckets.count else { return nil }
        let items = buckets[indexPath.section].items
        guard indexPath.item >= 0, indexPath.item < items.count else { return nil }
        return items[indexPath.item]
    }

    /// The viewer pages across the flattened timeline, ignoring bucket boundaries (§13.2).
    func flattened() -> [AssetStub] {
        var out = [AssetStub]()
        out.reserveCapacity(totalCount)
        for bucket in buckets { out.append(contentsOf: bucket.items) }
        return out
    }

    /// Position of a section/item position in the flattened order. O(sections) — used on the
    /// tap path, so it must not scan every asset.
    func flatIndex(of indexPath: IndexPath) -> Int? {
        guard indexPath.section >= 0, indexPath.section < buckets.count else { return nil }
        guard indexPath.item >= 0, indexPath.item < buckets[indexPath.section].items.count else {
            return nil
        }
        var offset = 0
        for section in 0..<indexPath.section { offset += buckets[section].items.count }
        return offset + indexPath.item
    }

    /// Position of an asset in the flattened order, or nil when absent.
    func flatIndex(of id: AssetID) -> Int? {
        var offset = 0
        for bucket in buckets {
            if let idx = bucket.items.firstIndex(where: { $0.id == id }) { return offset + idx }
            offset += bucket.items.count
        }
        return nil
    }

    func indexPath(of id: AssetID) -> IndexPath? {
        for (section, bucket) in buckets.enumerated() {
            if let item = bucket.items.firstIndex(where: { $0.id == id }) {
                return IndexPath(item: item, section: section)
            }
        }
        return nil
    }
}

/// Incremental mutations applied to the timeline index (DESIGN.md D20).
/// Sources: PhotoKit change details, remote sync batches, and optimistic UI actions.
enum TimelineChange {
    case insert([AssetStub])
    case remove([AssetID])
    case update([AssetStub])

    var isEmpty: Bool {
        switch self {
        case .insert(let s): return s.isEmpty
        case .remove(let s): return s.isEmpty
        case .update(let s): return s.isEmpty
        }
    }
}

/// Groups a date-sorted stub array into buckets.
///
/// Performance note (§14 P3): `Calendar` component math is expensive, so this walks the
/// already-sorted index and only asks the calendar for a new interval when it crosses a
/// bucket boundary — O(buckets) calendar calls rather than O(assets).
struct TimelineBucketer {
    private let calendar: Calendar
    private let dayFormatter: DateFormatter
    private let dayWithYearFormatter: DateFormatter
    private let monthFormatter: DateFormatter
    private let monthWithYearFormatter: DateFormatter
    private let weekFormatter: DateIntervalFormatter
    private let now: Date

    init(calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.now = now

        func formatter(_ template: String) -> DateFormatter {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = calendar.locale ?? .current
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f
        }
        dayFormatter = formatter("EEEEdMMMM")
        dayWithYearFormatter = formatter("EEEEdMMMMyyyy")
        monthFormatter = formatter("MMMM")
        monthWithYearFormatter = formatter("MMMMyyyy")

        let interval = DateIntervalFormatter()
        interval.calendar = calendar
        interval.locale = calendar.locale ?? .current
        interval.timeZone = calendar.timeZone
        interval.dateStyle = .medium
        interval.timeStyle = .none
        weekFormatter = interval
    }

    /// - Parameter sortedStubs: newest-first, as held by `TimelineStore`.
    func buckets(from sortedStubs: [AssetStub], grouping: Grouping) -> [TimelineSnapshot.Bucket] {
        guard !sortedStubs.isEmpty else { return [] }

        var result: [TimelineSnapshot.Bucket] = []
        result.reserveCapacity(max(8, sortedStubs.count / 16))

        let component = grouping.calendarComponent
        var currentInterval: DateInterval?
        var currentItems: [AssetStub] = []

        func flush() {
            guard let interval = currentInterval, !currentItems.isEmpty else { return }
            result.append(TimelineSnapshot.Bucket(id: identifier(for: interval, grouping: grouping),
                                                  title: title(for: interval, grouping: grouping),
                                                  items: currentItems))
        }

        for stub in sortedStubs {
            if let interval = currentInterval, stub.captureDate >= interval.start {
                currentItems.append(stub)
                continue
            }
            flush()
            currentInterval = calendar.dateInterval(of: component, for: stub.captureDate)
                ?? DateInterval(start: stub.captureDate, duration: 1)
            currentItems = [stub]
        }
        flush()
        return result
    }

    private func identifier(for interval: DateInterval, grouping: Grouping) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .weekOfYear, .yearForWeekOfYear],
                                        from: interval.start)
        switch grouping {
        case .day:
            return String(format: "d-%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        case .week:
            return String(format: "w-%04d-%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        case .month:
            return String(format: "m-%04d-%02d", c.year ?? 0, c.month ?? 0)
        }
    }

    private func title(for interval: DateInterval, grouping: Grouping) -> String {
        let start = interval.start
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)

        switch grouping {
        case .day:
            // Compare against the injected `now`, not the wall clock: `isDateInToday` would
            // ignore it, which makes these titles untestable and lets a long-running session
            // disagree with the rest of the snapshot after midnight.
            if calendar.isDate(start, inSameDayAs: now) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(start, inSameDayAs: yesterday) { return "Yesterday" }
            return (sameYear ? dayFormatter : dayWithYearFormatter).string(from: start)
        case .week:
            // `end` is exclusive; step back so the label reads "12 – 18 Aug".
            let inclusiveEnd = interval.end.addingTimeInterval(-1)
            return weekFormatter.string(from: start, to: inclusiveEnd)
        case .month:
            return (sameYear ? monthFormatter : monthWithYearFormatter).string(from: start)
        }
    }
}

import Foundation

/// Small, thread-safe user preferences store. Reads are cheap enough for the launch path
/// (UserDefaults is memory-mapped), which matters because grouping and column count are
/// needed to paint the first frame (D19).
final class AppSettings: @unchecked Sendable {
    private enum Key {
        static let grouping = "grid.grouping"
        static let columns = "grid.columns"
    }

    static let minColumns = 1
    static let maxColumns = 8
    static let defaultColumns = 3

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var grouping: Grouping {
        get {
            guard let raw = defaults.string(forKey: Key.grouping),
                  let value = Grouping(rawValue: raw) else { return .day }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Key.grouping) }
    }

    var gridColumns: Int {
        get {
            let stored = defaults.integer(forKey: Key.columns)
            guard stored >= Self.minColumns, stored <= Self.maxColumns else { return Self.defaultColumns }
            return stored
        }
        set {
            defaults.set(min(max(newValue, Self.minColumns), Self.maxColumns), forKey: Key.columns)
        }
    }
}

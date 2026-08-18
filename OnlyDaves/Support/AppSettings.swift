import Foundation

/// Small, thread-safe user preferences store. Reads are cheap enough for the launch path
/// (UserDefaults is memory-mapped), which matters because grouping and column count are
/// needed to paint the first frame (D19).
final class AppSettings: @unchecked Sendable {
    private enum Key {
        static let grouping = "grid.grouping"
        static let columns = "grid.columns"
        static let syncEnabled = "sync.enabled"
        static let syncScope = "sync.scope"
        static let syncScopeAnchor = "sync.scopeAnchor"
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

    // MARK: - Sync (requirement 14, D17)

    var syncEnabled: Bool {
        get { defaults.bool(forKey: Key.syncEnabled) }
        set { defaults.set(newValue, forKey: Key.syncEnabled) }
    }

    /// Lives in UserDefaults rather than the `kv` table so the sync scope is readable without
    /// opening SQLite — the launch path must not touch the database (D19).
    var syncScope: SyncScope {
        get {
            guard defaults.string(forKey: Key.syncScope) == "new_only" else { return .all }
            let anchor = defaults.double(forKey: Key.syncScopeAnchor)
            guard anchor > 0 else { return .all }
            return .newOnly(anchor: Date(timeIntervalSince1970: anchor))
        }
        set {
            switch newValue {
            case .all:
                defaults.set("all", forKey: Key.syncScope)
                defaults.removeObject(forKey: Key.syncScopeAnchor)
            case let .newOnly(anchor):
                defaults.set("new_only", forKey: Key.syncScope)
                defaults.set(anchor.timeIntervalSince1970, forKey: Key.syncScopeAnchor)
            }
        }
    }

    /// True once the user has been asked to choose a scope, so enabling sync again does not
    /// re-prompt unnecessarily.
    var hasChosenSyncScope: Bool {
        defaults.string(forKey: Key.syncScope) != nil
    }
}

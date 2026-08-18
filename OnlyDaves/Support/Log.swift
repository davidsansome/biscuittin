import OSLog

/// Logging categories used across the app (DESIGN.md §15).
enum Log {
    private static let subsystem = "dev.onlydaves.app"

    static let timeline = Logger(subsystem: subsystem, category: "timeline")
    static let immich = Logger(subsystem: subsystem, category: "immich")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let perf = Logger(subsystem: subsystem, category: "perf")
}

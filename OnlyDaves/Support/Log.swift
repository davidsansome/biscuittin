import Foundation
import OSLog

/// Logging categories used across the app (DESIGN.md §15).
enum Log {
    private static let subsystem = "dev.onlydaves.app"

    static let timeline = Logger(subsystem: subsystem, category: "timeline")
    static let immich = Logger(subsystem: subsystem, category: "immich")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let perf = Logger(subsystem: subsystem, category: "perf")

    /// Mirrors a diagnostic to stderr as well as the log store.
    ///
    /// On a physical device the only channel available from a terminal is
    /// `devicectl device process launch --console`, which relays stdout/stderr but **not**
    /// os_log — so `Logger` output is invisible there. Anything needed while debugging on real
    /// hardware goes through here. Debug builds only; release keeps os_log alone.
    static func device(_ category: String, _ message: @autoclosure () -> String) {
        let text = message()
        switch category {
        case "sync": sync.error("\(text, privacy: .public)")
        case "immich": immich.error("\(text, privacy: .public)")
        case "timeline": timeline.error("\(text, privacy: .public)")
        default: ui.error("\(text, privacy: .public)")
        }
        #if DEBUG
        FileHandle.standardError.write(Data("[onlydaves/\(category)] \(text)\n".utf8))
        #endif
    }
}

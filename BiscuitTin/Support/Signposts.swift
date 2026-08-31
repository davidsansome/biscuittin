import OSLog

/// Named signpost intervals from the performance contract (DESIGN.md §14 P7).
/// The names are part of the contract so Instruments runs stay comparable.
enum Signposts {
    static let log = OSLog(subsystem: "dev.biscuittin.app", category: .pointsOfInterest)

    static let launchToFirstFrame: StaticString = "launch-to-first-frame"
    static let snapshotApply: StaticString = "snapshot-apply"
    static let photoVisibleLatency: StaticString = "photo-visible-latency"
    static let tapToTransition: StaticString = "tap-to-transition"
    static let indexBuild: StaticString = "index-build"
    static let bootCacheLoad: StaticString = "boot-cache-load"

    /// Runs `body`, emitting a signpost interval around it.
    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try body()
    }
}

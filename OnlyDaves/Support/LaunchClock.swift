import Foundation

/// Measures true cold-launch time for the §14 P1 budget (first grid frame < 300 ms).
///
/// Timed from the kernel's record of process start, so it includes dyld and pre-`main` work —
/// the part an in-app stopwatch started in `init` would silently omit, and the part that
/// dominates a cold launch.
enum LaunchClock {

    /// When the kernel says this process began.
    static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec)
                    + Double(started.tv_usec) / 1_000_000)
    }()

    static var elapsedMilliseconds: Double? {
        guard let processStart else { return nil }
        return Date().timeIntervalSince(processStart) * 1000
    }

    /// Reports when the grid's view is first on screen. Note this can precede any content:
    /// the boot snapshot is loaded in a `Task`, so an empty frame may be presented first.
    static func reportFirstFrame(itemCount: Int, provenance: String) {
        guard let ms = elapsedMilliseconds else { return }
        Log.device("perf", String(format: "first-frame %.0f ms items=%d source=%@",
                                  ms, itemCount, provenance))
    }

    private static var hasReportedContent = false

    /// The measurement P1 actually cares about: photos visible, not merely a view on screen.
    /// Reported once, on the first snapshot that carries any items.
    static func reportFirstContent(itemCount: Int, provenance: String) {
        guard !hasReportedContent, itemCount > 0, let ms = elapsedMilliseconds else { return }
        hasReportedContent = true
        let verdict = ms <= 300 ? "within" : "OVER"
        Log.device("perf", String(format:
            "launch-to-first-content %.0f ms (%@ the 300 ms budget) items=%d source=%@",
            ms, verdict, itemCount, provenance))
    }
}

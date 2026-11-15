import Foundation

/// Decisions for replacing a server asset's file, kept free of I/O so they can be tested.
enum ReplacementPlan {
    /// Outside this, an offset is taken to be a bad `localDateTime` rather than a real zone.
    private static let offsetRange = -43_200...50_400

    /// The asset's true capture instant and its offset from UTC, from the server's own
    /// description. `localDateTime` is wall-clock time written as if it were UTC, so the
    /// difference between the two is the offset.
    static func captureTime(fileCreatedAt: String?, localDateTime: String?,
                            fallback: Date) -> (instant: Date, offsetSeconds: Int) {
        let instant = Immich.parseDate(fileCreatedAt) ?? fallback
        guard let local = Immich.parseDate(localDateTime) else { return (instant, 0) }
        // Every real zone offset is a multiple of 15 minutes.
        let quarterHours = (local.timeIntervalSince(instant) / 900).rounded()
        let offset = Int(quarterHours) * 900
        return (instant, offsetRange.contains(offset) ? offset : 0)
    }

    /// The server's name for the asset with the exported file's extension. PhotoKit names
    /// every edited rendition "FullSizeRender", which must not replace the real name.
    static func filename(serverName: String?, exportedName: String) -> String {
        guard let serverName, !serverName.isEmpty else { return exportedName }
        let ext = (exportedName as NSString).pathExtension
        guard !ext.isEmpty else { return serverName }
        return (serverName as NSString).deletingPathExtension + "." + ext.lowercased()
    }
}

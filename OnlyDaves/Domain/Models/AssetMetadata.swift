import Foundation
import CoreLocation

/// Unified metadata shown in the info sheet (requirement 9, DESIGN.md §6.3).
///
/// Every field is optional: the sheet opens immediately with whatever is already known from
/// the timeline stub and fills rows in as slower sources resolve (§14 P4), so this type has
/// to be meaningful when only half-populated.
struct AssetMetadata: Equatable {
    /// Where a copy of this asset lives, shown as badges in the Availability section.
    enum Source: String, Equatable {
        case device = "On this iPhone"
        case immich = "On Immich"
    }

    var fileName: String?
    var captureDate: Date?
    var pixelSize: CGSize?
    var fileSizeBytes: Int64?
    /// Videos only.
    var durationSeconds: Double?

    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var fNumber: Double?
    var exposureSeconds: Double?
    var iso: Int?
    var focalLengthMM: Double?

    var coordinate: CLLocationCoordinate2D?
    /// Reverse-geocoded locally, or the city/state Immich already knows (M5).
    var placeName: String?

    var sources: [Source] = []

    /// True when there is nothing worth rendering in the Camera section.
    var hasCameraInfo: Bool {
        cameraMake != nil || cameraModel != nil || lensModel != nil
            || fNumber != nil || exposureSeconds != nil || iso != nil || focalLengthMM != nil
    }

    var hasLocation: Bool { coordinate != nil }

    /// The immediately-available subset, derived from the timeline stub alone.
    init(stub: AssetStub) {
        captureDate = stub.captureDate
        if stub.pixelWidth > 0 && stub.pixelHeight > 0 {
            pixelSize = CGSize(width: CGFloat(stub.pixelWidth), height: CGFloat(stub.pixelHeight))
        }
        if stub.kind == .video, stub.durationSeconds > 0 {
            durationSeconds = Double(stub.durationSeconds)
        }
        if stub.hasLocal { sources.append(.device) }
        if stub.hasRemote { sources.append(.immich) }
    }

    init() {}

    // MARK: - Formatting helpers

    static func formattedFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func formattedExposure(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))s"
    }

    static func formattedDuration(_ seconds: Double) -> String {
        AssetCell.durationText(Float(seconds))
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

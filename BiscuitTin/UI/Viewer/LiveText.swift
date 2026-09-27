import UIKit
import VisionKit

/// On-device text recognition for the viewer (D25). VisionKit does both the OCR and the
/// selection UI; nothing leaves the device.
@MainActor
enum LiveText {
    /// False on devices older than A12, where the viewer simply never offers Live Text.
    static var isSupported: Bool { ImageAnalyzer.isSupported }

    /// One analyzer for every page, rather than one per cell.
    private static let analyzer = ImageAnalyzer()
    private static let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])

    static func analyze(_ image: UIImage) async throws -> ImageAnalysis {
        try await analyzer.analyze(image, configuration: configuration)
    }
}

import XCTest
import CoreGraphics
import ImageIO
import Photos
import UniformTypeIdentifiers
@testable import OnlyDaves

/// Rotation strategy dispatch and actual pixel behaviour (DESIGN.md D10, §16).
final class RotationTests: XCTestCase {

    // MARK: - Registry dispatch

    /// As of M9 every media kind has a rotator, and each dispatches to the right strategy.
    func testRegistryCoversEveryMediaKind() {
        let registry = RotatorRegistry.v1
        for kind in [MediaKind.image, .video, .livePhoto] {
            XCTAssertTrue(registry.canRotate(kind), "\(kind) should be rotatable")
            XCTAssertEqual(registry.rotator(for: kind)?.supportedKind, kind,
                           "\(kind) must dispatch to its own strategy")
        }
        XCTAssertTrue(registry.rotator(for: .image) is ImageRotator)
        XCTAssertTrue(registry.rotator(for: .video) is VideoRotator)
        XCTAssertTrue(registry.rotator(for: .livePhoto) is LivePhotoRotator)
    }

    /// A registry built without a kind must report it unrotatable rather than failing later —
    /// this is what let v1 ship images-only without special cases in callers.
    func testRegistryReportsMissingKindsAsUnrotatable() {
        let registry = RotatorRegistry(rotators: [ImageRotator()])
        XCTAssertTrue(registry.canRotate(.image))
        XCTAssertFalse(registry.canRotate(.video))
        XCTAssertNil(registry.rotator(for: .video))
    }

    func testRegistryDispatchesByKind() {
        let registry = RotatorRegistry(rotators: [ImageRotator(), StubVideoRotator()])
        XCTAssertTrue(registry.canRotate(.video))
        XCTAssertEqual(registry.rotator(for: .video)?.supportedKind, .video)
    }

    /// Stands in for M9's `VideoRotator` — only its `supportedKind` matters here.
    private struct StubVideoRotator: AssetRotator {
        let supportedKind: MediaKind = .video
        func rotateLocal(input: PHContentEditingInput, clockwise: Bool) async throws -> URL {
            URL(fileURLWithPath: "/dev/null")
        }
        func rotateRemoteOriginal(fileURL: URL, clockwise: Bool) async throws -> URL { fileURL }
    }

    // MARK: - Pixel rotation

    /// A clockwise turn must move the top-left corner to the top-right. This is the exact
    /// property that was inverted in the first implementation.
    func testClockwiseRotationMovesTopLeftToTopRight() throws {
        let url = try makeMarkedImage(width: 40, height: 20)
        defer { try? FileManager.default.removeItem(at: url) }

        let rotated = try ImageRotator().rotate(fileURL: url, clockwise: true, preferredUTI: nil)
        defer { try? FileManager.default.removeItem(at: rotated) }

        let image = try loadCGImage(rotated)
        XCTAssertEqual(image.width, 20, "width and height must swap on a quarter turn")
        XCTAssertEqual(image.height, 40)

        let pixels = try readPixels(image)
        XCTAssertTrue(pixels.isMarker(x: image.width - 1, y: 0),
                      "clockwise: the marker belongs in the top-right")
        XCTAssertFalse(pixels.isMarker(x: 0, y: 0))
    }

    func testCounterClockwiseRotationMovesTopLeftToBottomLeft() throws {
        let url = try makeMarkedImage(width: 40, height: 20)
        defer { try? FileManager.default.removeItem(at: url) }

        let rotated = try ImageRotator().rotate(fileURL: url, clockwise: false, preferredUTI: nil)
        defer { try? FileManager.default.removeItem(at: rotated) }

        let image = try loadCGImage(rotated)
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 40)

        let pixels = try readPixels(image)
        XCTAssertTrue(pixels.isMarker(x: 0, y: image.height - 1),
                      "counter-clockwise: the marker belongs in the bottom-left")
        XCTAssertFalse(pixels.isMarker(x: 0, y: 0))
    }

    func testFourClockwiseRotationsRestoreOriginalGeometry() throws {
        var current = try makeMarkedImage(width: 40, height: 20)
        defer { try? FileManager.default.removeItem(at: current) }

        for _ in 0..<4 {
            let next = try ImageRotator().rotate(fileURL: current, clockwise: true, preferredUTI: nil)
            try? FileManager.default.removeItem(at: current)
            current = next
        }

        let image = try loadCGImage(current)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 20)
        let pixels = try readPixels(image)
        XCTAssertTrue(pixels.isMarker(x: 0, y: 0), "four turns must return to the start")
    }

    func testRotationPreservesCameraMetadata() throws {
        let url = try makeMarkedImage(width: 40, height: 20, includeExif: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let rotated = try ImageRotator().rotate(fileURL: url, clockwise: true, preferredUTI: nil)
        defer { try? FileManager.default.removeItem(at: rotated) }

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(rotated as CFURL, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "OnlyDaves")

        // The turn is baked into the pixels, so the file must declare identity orientation —
        // otherwise viewers would apply the rotation twice.
        let orientation = props[kCGImagePropertyOrientation] as? UInt32
        XCTAssertEqual(orientation, CGImagePropertyOrientation.up.rawValue)
    }

    // MARK: - Helpers

    /// Writes a PNG (lossless, so pixel assertions are exact) with a red marker square in the
    /// visual top-left corner.
    private func makeMarkedImage(width: Int, height: Int, includeExif: Bool = false) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext is y-up, so the visual top-left is at the high-y end.
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: height - 5, width: 5, height: 5))

        let image = try XCTUnwrap(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rot-test-\(UUID().uuidString).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))

        var properties: [CFString: Any] = [:]
        if includeExif {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "OnlyDaves",
                kCGImagePropertyTIFFModel: "Test Camera"
            ]
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func loadCGImage(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private struct PixelBuffer {
        let bytes: [UInt8]
        let width: Int
        /// True when the pixel is predominantly red (the marker colour).
        func isMarker(x: Int, y: Int) -> Bool {
            let i = (y * width + x) * 4
            guard i + 2 < bytes.count else { return false }
            return bytes[i] > 180 && bytes[i + 1] < 80 && bytes[i + 2] < 80
        }
    }

    /// Reads pixels with y = 0 meaning the visual *top*.
    ///
    /// Note the asymmetry with `makeMarkedImage`: `CGContext.fill` draws in user space, which
    /// is y-up from the bottom-left, whereas indexing the bitmap's backing memory is y-down
    /// from the top. So a fill at `height - 5` is the visual top, and row 0 here is that same
    /// visual top. Adding a flip to this reader would silently invert every assertion below.
    private func readPixels(_ image: CGImage) throws -> PixelBuffer {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return PixelBuffer(bytes: bytes, width: width)
    }
}

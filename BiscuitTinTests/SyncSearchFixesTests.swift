import XCTest
import CoreML
@testable import BiscuitTin

/// Regression tests for Sync, Search, and Support review fixes.
final class SyncSearchFixesTests: XCTestCase {

    // MARK: - CLIPEncoder bounds & dataType safety

    func testMakeTokenArrayZeroFillsShortInput() throws {
        let array = try CLIPEncoder.makeTokenArray(from: [49406, 123, 49407])
        XCTAssertEqual(array.count, CLIPTokenizer.contextLength)
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: CLIPTokenizer.contextLength)
        XCTAssertEqual(ptr[0], 49406)
        XCTAssertEqual(ptr[1], 123)
        XCTAssertEqual(ptr[2], 49407)
        for index in 3..<CLIPTokenizer.contextLength {
            XCTAssertEqual(ptr[index], 0, "slot \(index) must be zero-filled")
        }
    }

    func testMakeTokenArrayClampsOverlongInputWithoutOverflow() throws {
        let overlong = (0..<(CLIPTokenizer.contextLength + 50)).map { Int32($0 + 1) }
        let array = try CLIPEncoder.makeTokenArray(from: overlong)
        XCTAssertEqual(array.count, CLIPTokenizer.contextLength)
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: CLIPTokenizer.contextLength)
        XCTAssertEqual(ptr[0], 1)
        XCTAssertEqual(ptr[CLIPTokenizer.contextLength - 1], Int32(CLIPTokenizer.contextLength))
    }

    func testExtractVectorSupportsFloat32() throws {
        let array = try MLMultiArray(shape: [1, NSNumber(value: EmbeddingStore.dimensions)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: EmbeddingStore.dimensions)
        for i in 0..<EmbeddingStore.dimensions { ptr[i] = Float(i) * 0.01 }

        let vector = try CLIPEncoder.extractVector(from: array)
        XCTAssertEqual(vector.count, EmbeddingStore.dimensions)
        XCTAssertEqual(vector[0], 0, accuracy: 1e-5)
        XCTAssertEqual(vector[100], 1.0, accuracy: 1e-5)
    }

    func testExtractVectorSupportsFloat16() throws {
        let source = (0..<EmbeddingStore.dimensions).map { Float($0) / Float(EmbeddingStore.dimensions) }
        let encoded = EmbeddingStore.encode(source)
        let array = try MLMultiArray(shape: [1, NSNumber(value: EmbeddingStore.dimensions)], dataType: .float16)
        _ = encoded.withUnsafeBytes { bytes in
            memcpy(array.dataPointer, bytes.baseAddress!, encoded.count)
        }

        let vector = try CLIPEncoder.extractVector(from: array)
        XCTAssertEqual(vector.count, EmbeddingStore.dimensions)
        let expected = EmbeddingStore.normalized(source)
        let cosine = zip(expected, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertGreaterThan(cosine, 0.9999)
    }

    func testExtractVectorRejectsUnsupportedDataType() throws {
        let array = try MLMultiArray(shape: [1, NSNumber(value: EmbeddingStore.dimensions)], dataType: .int32)
        XCTAssertThrowsError(try CLIPEncoder.extractVector(from: array)) { error in
            guard case CLIPEncoder.EncoderError.badOutput = error else {
                return XCTFail("Expected .badOutput, got \(error)")
            }
        }
    }

    func testExtractVectorRejectsWrongCount() throws {
        let array = try MLMultiArray(shape: [1, 16], dataType: .float32)
        XCTAssertThrowsError(try CLIPEncoder.extractVector(from: array)) { error in
            guard case CLIPEncoder.EncoderError.badOutput = error else {
                return XCTFail("Expected .badOutput, got \(error)")
            }
        }
    }
}

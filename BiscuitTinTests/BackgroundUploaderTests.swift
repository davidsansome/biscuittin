import XCTest
@testable import BiscuitTin

/// What the background upload session hands `SyncEngine.record` (DESIGN.md D12).
final class BackgroundUploaderTests: XCTestCase {

    private let url = URL(string: "https://s.example.com/api/assets")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// The ticket is the only record of an upload a relaunched process has, so it must
    /// survive the trip through `taskDescription` intact.
    func testTicketRoundTripsThroughTaskDescription() throws {
        let ticket = BackgroundUploader.Ticket(localIdentifier: "L1/L0/001",
                                               checksumHex: "abc123",
                                               filename: "IMG_0001.HEIC",
                                               byteCount: 4_200_000_000,
                                               bodyFilename: "upload-1.multipart",
                                               modifiedBeforeExport: Date(timeIntervalSince1970: 1_700_000_000))
        let description = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        let decoded = try JSONDecoder().decode(BackgroundUploader.Ticket.self, from: Data(description.utf8))
        XCTAssertEqual(decoded, ticket)
    }

    func testCreatedAndDuplicateAreBothSuccess() throws {
        for status in ["created", "duplicate"] {
            let body = Data(#"{"id":"R1","status":"\#(status)"}"#.utf8)
            let result = BackgroundUploader.result(response: response(201), body: body, error: nil)
            XCTAssertEqual(try result.get()?.id, "R1", status)
        }
    }

    func testUnauthorizedIsReportedAsSuch() {
        let result = BackgroundUploader.result(response: response(401), body: nil, error: nil)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? ImmichError, .unauthorized)
        }
    }

    func testServerErrorCarriesItsStatus() {
        let result = BackgroundUploader.result(response: response(500), body: Data("oops".utf8), error: nil)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? ImmichError, .http(status: 500))
        }
    }

    /// A transport error wins over whatever partial response came with it.
    func testTransportErrorIsPassedThrough() {
        let result = BackgroundUploader.result(response: response(200), body: nil,
                                               error: URLError(.cancelled))
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
    }

    func testMissingHTTPResponseIsTreatedAsFailure() {
        let nilResponse = BackgroundUploader.result(response: nil, body: nil, error: nil)
        XCTAssertThrowsError(try nilResponse.get()) { error in
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
        let nonHTTP = BackgroundUploader.result(
            response: URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil),
            body: nil,
            error: nil)
        XCTAssertThrowsError(try nonHTTP.get()) { error in
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testPendingRecordingTicketsStayInFlightUntilHandlerCompletes() async {
        let uploader = BackgroundUploader()
        let ticket = BackgroundUploader.Ticket(localIdentifier: "L-inflight",
                                               checksumHex: "deadbeef",
                                               filename: "IMG.JPG",
                                               byteCount: 123,
                                               bodyFilename: "body.multipart",
                                               modifiedBeforeExport: nil)
        let outcome = BackgroundUploader.Outcome(ticket: ticket, result: .success(nil))

        // Before a handler is registered, undelivered outcomes count as pending.
        uploader.deliver(outcome)
        XCTAssertEqual(uploader.pendingRecordingTickets(), [ticket])

        let entered = expectation(description: "handler entered")
        let gate = AsyncStream.makeStream(of: Void.self)
        uploader.setHandler { _ in
            entered.fulfill()
            for await _ in gate.stream { break }
        }
        await fulfillment(of: [entered], timeout: 2)

        // While the handler is still running, the ticket remains in-flight.
        XCTAssertEqual(uploader.pendingRecordingTickets(), [ticket])

        // Release the handler and wait for recording to clear.
        gate.continuation.yield(())
        gate.continuation.finish()
        for _ in 0..<50 where !uploader.pendingRecordingTickets().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(uploader.pendingRecordingTickets().isEmpty)
    }

    func testMultipartBodyIsWrittenWhereAsked() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jpg")
        try Data("pixels".utf8).write(to: source)

        let body = try MultipartBuilder.buildBody(boundary: "B", fields: ["deviceId": "D"],
                                                  fileField: "assetData", fileURL: source,
                                                  filename: "source.jpg", outputDirectory: directory)
        XCTAssertEqual(body.deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
        let text = String(decoding: try Data(contentsOf: body), as: UTF8.self)
        XCTAssertTrue(text.contains("pixels"))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }
}

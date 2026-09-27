import XCTest
@testable import BiscuitTin

/// An image request refused as unauthorized only expires the session once an account-level
/// call is refused as well: `ImmichClient` reports a per-asset 403 the same way as a dead token.
final class RemoteImageFetcherTests: XCTestCase {

    private final class ExpiryCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func makeFetcher(_ counter: ExpiryCounter) -> RemoteImageFetcher {
        let session = ImmichAuthSession(defaults: UserDefaults(suiteName: "fetcher-tests-\(UUID())")!)
        return RemoteImageFetcher(session: session,
                                  cache: RemoteThumbnailCache(),
                                  onCredentialRejected: { counter.increment() })
    }

    private func makeClient(_ recorder: RequestRecorder) -> ImmichClient {
        ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                     session: StubURLProtocol.makeSession(recorder),
                     tokenProvider: { "tok" })
    }

    func testRefusedAccountCallExpiresSession() async {
        let recorder = RequestRecorder()
        await recorder.stub(path: "/api/users/me", json: #"{"message":"unauthorized"}"#, status: 401)
        let counter = ExpiryCounter()

        await makeFetcher(counter).confirmCredentialRejected(using: makeClient(recorder))

        XCTAssertEqual(counter.count, 1)
    }

    func testAccountCallThatSucceedsKeepsSession() async {
        let recorder = RequestRecorder()
        await recorder.stub(path: "/api/users/me", json: #"{"id":"u1","email":"a@b.c","name":"A"}"#)
        let counter = ExpiryCounter()

        await makeFetcher(counter).confirmCredentialRejected(using: makeClient(recorder))

        XCTAssertEqual(counter.count, 0)
    }

    /// Being offline says nothing about the credential.
    func testUnreachableServerKeepsSession() async {
        let recorder = RequestRecorder()
        await recorder.stub(path: "/api/users/me", json: "{}", status: 503)
        let counter = ExpiryCounter()

        await makeFetcher(counter).confirmCredentialRejected(using: makeClient(recorder))

        XCTAssertEqual(counter.count, 0)
    }
}

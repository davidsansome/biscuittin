import XCTest
import Photos
@testable import BiscuitTin

final class RetryPolicyTests: XCTestCase {

    func testDelayDoublesFromAMinuteUpToSixHours() {
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 0), 0)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 1), 60)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 2), 120)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 5), 960)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 10), 21_600)
        XCTAssertEqual(RetryPolicy.delay(afterFailures: 50), 21_600)
    }

    func testCancellationIsTransient() {
        XCTAssertEqual(RetryPolicy.kind(of: CancellationError()), .transient)
        XCTAssertEqual(RetryPolicy.kind(of: URLError(.cancelled)), .transient)
    }

    func testConnectivityErrorIsTransient() {
        XCTAssertEqual(RetryPolicy.kind(of: URLError(.notConnectedToInternet)), .transient)
    }

    func testUnreachableIsTransient() {
        XCTAssertEqual(RetryPolicy.kind(of: ImmichError.unreachable), .transient)
    }

    func testSignInProblemsAreAuthentication() {
        XCTAssertEqual(RetryPolicy.kind(of: ImmichError.unauthorized), .authentication)
        XCTAssertEqual(RetryPolicy.kind(of: ImmichError.notConfigured), .authentication)
    }

    func testServerTroubleIsTransient() {
        for status in [408, 429, 500, 502, 503] {
            XCTAssertEqual(RetryPolicy.kind(of: ImmichError.http(status: status)), .transient, "\(status)")
        }
    }

    func testEverythingElseIsTheItemsFault() {
        XCTAssertEqual(RetryPolicy.kind(of: ImmichError.http(status: 400)), .item)
        XCTAssertEqual(RetryPolicy.kind(of: ImmichError.rejected("bad")), .item)
        XCTAssertEqual(RetryPolicy.kind(of: RotationError.renderFailed), .item)
        XCTAssertFalse(RetryPolicy.isPhotoKitError(ImmichError.http(status: 400)))
    }

    func testPhotoKitErrorsClassifyNetworkVsItem() {
        let networkRequired = NSError(domain: PHPhotosErrorDomain,
                                      code: PHPhotosError.networkAccessRequired.rawValue)
        XCTAssertEqual(RetryPolicy.kind(of: networkRequired), .transient)

        let underlyingOffline = NSError(domain: PHPhotosErrorDomain, code: -1,
                                        userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
        XCTAssertEqual(RetryPolicy.kind(of: underlyingOffline), .transient)

        let internalError = NSError(domain: PHPhotosErrorDomain, code: -1)
        XCTAssertEqual(RetryPolicy.kind(of: internalError), .item)
        XCTAssertTrue(RetryPolicy.isPhotoKitError(internalError))
    }
}

final class ServerPauseTests: XCTestCase {
    func testPauseDoublesUpToFifteenMinutesAndResets() {
        var pause = ServerPause()
        let taken = (0..<8).map { _ in pause.take() }
        XCTAssertEqual(taken, [30, 60, 120, 240, 480, 900, 900, 900])
        pause.reset()
        XCTAssertEqual(pause.take(), 30)
    }
}

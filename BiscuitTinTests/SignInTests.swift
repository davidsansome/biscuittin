import XCTest
@testable import BiscuitTin

/// Server discovery, credentials and OAuth plumbing behind the sign-in flow (DESIGN.md §13.4).
/// Response bodies are copied from a live Immich v3.1.0 server.
final class SignInTests: XCTestCase {

    // MARK: - Candidate URLs

    func testBareHostTriesHTTPSThenHTTPThenDefaultPort() {
        XCTAssertEqual(ImmichServerProbe.candidates(for: "photos.example.com").map(\.absoluteString),
                       ["https://photos.example.com", "http://photos.example.com",
                        "http://photos.example.com:2283"])
    }

    func testExplicitPortIsNotSecondGuessed() {
        XCTAssertEqual(ImmichServerProbe.candidates(for: "192.168.1.20:2283").map(\.absoluteString),
                       ["https://192.168.1.20:2283", "http://192.168.1.20:2283"])
    }

    func testExplicitSchemeIsTakenAtItsWord() {
        XCTAssertEqual(ImmichServerProbe.candidates(for: " http://nas.local:2283/api/ ")
                        .map(\.absoluteString),
                       ["http://nas.local:2283"])
    }

    func testEmptyInputHasNoCandidates() {
        XCTAssertTrue(ImmichServerProbe.candidates(for: "  ").isEmpty)
    }

    // MARK: - .well-known

    func testWellKnownRelativeEndpointHangsOffTheOrigin() {
        let base = ImmichServerProbe.baseURL(forAPIEndpoint: "/api",
                                             relativeTo: URL(string: "https://photos.example.com")!)
        XCTAssertEqual(base?.absoluteString, "https://photos.example.com")
    }

    func testWellKnownProxyPathIsKept() {
        let base = ImmichServerProbe.baseURL(forAPIEndpoint: "/immich/api",
                                             relativeTo: URL(string: "https://example.com")!)
        XCTAssertEqual(base?.absoluteString, "https://example.com/immich")
    }

    func testWellKnownAbsoluteEndpointMayChangeHost() {
        let base = ImmichServerProbe.baseURL(forAPIEndpoint: "https://api.example.com/api",
                                             relativeTo: URL(string: "https://example.com")!)
        XCTAssertEqual(base?.absoluteString, "https://api.example.com")
    }

    // MARK: - Probe

    private func stubHealthyServer(_ recorder: RequestRecorder, major: Int = 3,
                                   oauth: Bool = false, passwordLogin: Bool = true) async {
        await recorder.stub(path: "/api/server/ping", json: #"{"res":"pong"}"#)
        await recorder.stub(path: "/api/server/version",
                            json: #"{"major":\#(major),"minor":1,"patch":0,"prerelease":null}"#)
        await recorder.stub(path: "/api/server/features", json: """
            {"smartSearch":true,"facialRecognition":true,"duplicateDetection":true,"map":false,
             "reverseGeocoding":true,"importFaces":false,"sidecar":true,"search":true,"trash":true,
             "oauth":\(oauth),"oauthAutoLaunch":false,"ocr":true,"passwordLogin":\(passwordLogin),
             "configFile":false,"email":false,"realtimeTranscoding":false}
            """)
        await recorder.stub(path: "/api/server/config", json: """
            {"loginPageMessage":"","trashDays":30,"userDeleteDelay":7,
             "oauthButtonText":"Login with OAuth","isInitialized":true,"isOnboarded":true,
             "externalDomain":"","publicUsers":true,"maintenanceMode":false,"minFaces":3}
            """)
    }

    func testProbeReportsVersionAndSignInMethods() async throws {
        let recorder = RequestRecorder()
        let session = StubURLProtocol.makeSession(recorder)
        await stubHealthyServer(recorder, oauth: true, passwordLogin: false)

        let info = try await ImmichServerProbe.probe(candidate: URL(string: "https://s.example.com")!,
                                                     session: session)
        XCTAssertEqual(info.version.description, "v3.1.0")
        XCTAssertTrue(info.features.oauth)
        XCTAssertFalse(info.features.passwordLogin)
        XCTAssertEqual(info.config.oauthButtonText, "Login with OAuth")

        // Nothing before sign-in may carry a credential.
        let request = await recorder.lastRequest
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request?.value(forHTTPHeaderField: "x-api-key"))
    }

    func testProbeRejectsOldServerBeforeAnyCredentialsAreAsked() async {
        let recorder = RequestRecorder()
        let session = StubURLProtocol.makeSession(recorder)
        await stubHealthyServer(recorder, major: 2)

        do {
            _ = try await ImmichServerProbe.probe(candidate: URL(string: "https://s.example.com")!,
                                                  session: session)
            XCTFail("Expected serverTooOld")
        } catch {
            XCTAssertEqual(error as? ImmichError, .serverTooOld(found: "v2.1.0", required: "v3.0"))
        }
    }

    func testProbeRecognisesSomethingThatIsNotImmich() async {
        let recorder = RequestRecorder()
        let session = StubURLProtocol.makeSession(recorder)
        // Every path 404s, like a web server with no Immich behind it.

        do {
            _ = try await ImmichServerProbe.probe(candidate: URL(string: "https://s.example.com")!,
                                                  session: session)
            XCTFail("Expected notImmich")
        } catch {
            XCTAssertEqual(error as? ImmichError, .notImmich)
        }
    }

    func testMostInformativeErrorPrefersProofOfTheRightAddress() {
        let error = ImmichServerProbe.mostInformative([
            ImmichError.unreachable,
            ImmichError.serverTooOld(found: "v2.0.0", required: "v3.0"),
            ImmichError.notImmich
        ])
        XCTAssertEqual(error as? ImmichError, .serverTooOld(found: "v2.0.0", required: "v3.0"))
    }

    func testFeaturesFromAnOlderServerDefaultToPasswordLogin() throws {
        let features = try JSONDecoder().decode(Immich.ServerFeatures.self,
                                                from: Data(#"{"oauth":false}"#.utf8))
        XCTAssertTrue(features.passwordLogin)
    }

    // MARK: - Credentials

    func testAPIKeyTravelsInItsOwnHeader() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  credentialProvider: { .apiKey("k3y") })
        await recorder.stub(path: "/api/users/me", json: #"{"id":"u1","email":"a@b.c","name":"A"}"#)

        _ = try await client.me()

        let request = await recorder.lastRequest
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-api-key"), "k3y")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
    }

    func testPlaybackHeadersFollowTheCredentialKind() async {
        let keyed = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                 credentialProvider: { .apiKey("k") })
        let keyedHeaders = await keyed.playbackHeaders()
        XCTAssertEqual(keyedHeaders, ["x-api-key": "k"])

        let tokened = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                   tokenProvider: { "t" })
        let tokenedHeaders = await tokened.playbackHeaders()
        XCTAssertEqual(tokenedHeaders, ["Authorization": "Bearer t"])
    }

    func testBadRequestCarriesTheServersExplanation() async {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  credentialProvider: { nil })
        // Verbatim from a v3.1.0 server with OAuth switched off.
        await recorder.stub(path: "/api/oauth/authorize",
                            json: #"{"message":"OAuth is not enabled"}"#, status: 400)

        do {
            _ = try await client.oauthAuthorize(redirectURI: OAuthAttempt.redirectURI,
                                                state: "s", codeChallenge: "c")
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? ImmichError, .rejected("OAuth is not enabled"))
        }
    }

    // MARK: - OAuth

    func testOAuthAuthorizeSendsStateAndChallengeWithoutCredentials() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  credentialProvider: { nil })
        await recorder.stub(path: "/api/oauth/authorize",
                            json: #"{"url":"https://idp.example.com/authorize?x=1"}"#, status: 201)

        let response = try await client.oauthAuthorize(redirectURI: OAuthAttempt.redirectURI,
                                                       state: "st", codeChallenge: "ch")

        XCTAssertEqual(response.url, "https://idp.example.com/authorize?x=1")
        let captured = await recorder.lastBody
        let body = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(captured))
        XCTAssertEqual(body, ["redirectUri": "app.immich:///oauth-callback",
                              "state": "st", "codeChallenge": "ch"])
    }

    func testOAuthCallbackPostsRedirectStateAndVerifier() async throws {
        let recorder = RequestRecorder()
        let client = ImmichClient(baseURL: URL(string: "https://s.example.com")!,
                                  session: StubURLProtocol.makeSession(recorder),
                                  credentialProvider: { nil })
        await recorder.stub(path: "/api/oauth/callback", json: """
            {"accessToken":"tok","userId":"u","userEmail":"a@b.c","name":"A",
             "profileImagePath":"","isAdmin":false,"shouldChangePassword":false,"isOnboarded":true}
            """, status: 201)

        let callback = URL(string: "app.immich:///oauth-callback?code=abc&state=st")!
        let login = try await client.oauthCallback(url: callback, state: "st", codeVerifier: "ver")

        XCTAssertEqual(login.accessToken, "tok")
        let captured = await recorder.lastBody
        let body = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(captured))
        XCTAssertEqual(body, ["url": callback.absoluteString, "state": "st", "codeVerifier": "ver"])
    }

    func testOAuthRedirectQueryIsFormDecoded() {
        // A provider's error redirect, with `+` for spaces and an escaped literal plus.
        let url = URL(string: "app.immich:///oauth-callback?error=access_denied"
                      + "&error_description=User+declined+%2B+left&state=s%2F1")!
        let parameters = ImmichAuthSession.formDecodedQuery(of: url)
        XCTAssertEqual(parameters["error_description"], "User declined + left")
        XCTAssertEqual(parameters["state"], "s/1")
    }

    func testPKCEChallengeIsUnpaddedBase64URLOfSHA256() {
        // Expected value computed independently:
        // base64.urlsafe_b64encode(hashlib.sha256(verifier).digest()).rstrip(b"=")
        XCTAssertEqual(OAuthPKCE.challenge(for: "dBjftJeZ4CVP-mJ92Ks9Ys3y5yzNeCnF-JnHx5HpxFY"),
                       "Crifa65ezSnA8P0-L6uMzdX6PgR_c9UwN-sKyzOga4Y")
    }

    func testPKCEValuesAreFreshAndURLSafe() {
        let first = OAuthPKCE(), second = OAuthPKCE()
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.codeVerifier, second.codeVerifier)
        // RFC 7636 §4.1: 43–128 unreserved characters.
        XCTAssertGreaterThanOrEqual(first.codeVerifier.count, 43)
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(first.codeVerifier.unicodeScalars.allSatisfy(unreserved.contains))
    }
}

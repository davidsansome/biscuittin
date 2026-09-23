import Foundation

/// What an Immich server says about itself before anyone signs in: enough to choose which
/// sign-in methods to offer, and to reject an unsupported version before asking for a password.
struct ImmichServerInfo: Equatable, Sendable {
    let baseURL: URL
    let version: Immich.ServerVersion
    let features: Immich.ServerFeatures
    let config: Immich.ServerConfig

    var displayHost: String { Self.displayHost(for: baseURL) }

    /// The server as a person would name it: host, port and any proxy path, without a scheme.
    static func displayHost(for url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if let port = url.port { host += ":\(port)" }
        if !url.path.isEmpty, url.path != "/" { host += url.path }
        return host
    }

    var isInsecureNonLocal: Bool { ImmichAuthSession.isInsecureNonLocal(baseURL) }
}

/// Turns whatever the user typed into a verified Immich base URL, using only endpoints that
/// need no authentication (`server/about` is not one of them — see `ImmichAuthSession.signIn`).
enum ImmichServerProbe {

    /// Immich's documented default port, tried when the user gives a bare host.
    static let defaultPort = 2283

    /// The URLs worth trying for `input`, most preferred first.
    ///
    /// An explicit scheme is taken at its word. A bare host tries HTTPS first, because a server
    /// that offers it should get it, then plain HTTP, then HTTP on Immich's default port — the
    /// shape of a fresh Docker install reached by IP.
    static func candidates(for input: String) -> [URL] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if text.contains("://") {
            return ImmichAuthSession.normalizeServerURL(text).map { [$0] } ?? []
        }

        var urls: [URL] = []
        for candidate in ["https://" + text, "http://" + text] {
            if let url = ImmichAuthSession.normalizeServerURL(candidate) { urls.append(url) }
        }
        if let http = urls.last, http.port == nil,
           var components = URLComponents(url: http, resolvingAgainstBaseURL: false) {
            components.port = defaultPort
            if let url = components.url { urls.append(url) }
        }
        return urls
    }

    /// Probes every candidate concurrently and returns the most preferred one that is a
    /// supported Immich server. Waiting on a preferred candidate only lasts until it fails, so a
    /// firewalled HTTPS port cannot hide a working HTTP server for longer than one timeout.
    static func probe(_ input: String, session: URLSession = .shared) async throws -> ImmichServerInfo {
        let candidates = candidates(for: input)
        guard !candidates.isEmpty else { throw ImmichError.invalidURL }

        let results = await withTaskGroup(of: (Int, Result<ImmichServerInfo, Error>).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    do { return (index, .success(try await probe(candidate: url, session: session))) }
                    catch { return (index, .failure(error)) }
                }
            }

            var results = [Result<ImmichServerInfo, Error>?](repeating: nil, count: candidates.count)
            for await (index, result) in group {
                results[index] = result
                if case .success = preferred(results) {
                    group.cancelAll()
                    break
                }
            }
            return results
        }

        try Task.checkCancellation()
        switch preferred(results) {
        case let .success(info): return info
        default: throw mostInformative(results.compactMap { result in
            if case let .failure(error) = result { return error }
            return nil
        })
        }
    }

    /// The first success with no undecided candidate ranked above it.
    private static func preferred(_ results: [Result<ImmichServerInfo, Error>?]) -> Result<ImmichServerInfo, Error>? {
        for result in results {
            guard let result else { return nil }
            if case .success = result { return result }
        }
        return nil
    }

    /// When every candidate fails, the error that tells the user the most. "Server too old"
    /// from one candidate beats "unreachable" from the others: it proves the address was right.
    static func mostInformative(_ errors: [Error]) -> Error {
        func rank(_ error: Error) -> Int {
            switch error as? ImmichError {
            case .serverTooOld: return 0
            case .notImmich: return 1
            case .rejected, .http, .decoding: return 2
            default: return 3
            }
        }
        return errors.min { rank($0) < rank($1) } ?? ImmichError.unreachable
    }

    static func probe(candidate: URL, session: URLSession = .shared) async throws -> ImmichServerInfo {
        let base = await resolveWellKnown(candidate, session: session) ?? candidate
        let client = ImmichClient(baseURL: base, session: session, credentialProvider: { nil })

        do {
            let ping = try await client.ping()
            guard ping.res == "pong" else { throw ImmichError.notImmich }
        } catch ImmichError.unreachable {
            throw ImmichError.unreachable
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Anything that answered but not with Immich's ping: a router page, a different app
            // behind the proxy, a 404.
            throw ImmichError.notImmich
        }

        let version = try await client.serverVersion()
        guard version.major >= ImmichAuthSession.minimumServerMajor else {
            throw ImmichError.serverTooOld(found: version.description,
                                           required: "v\(ImmichAuthSession.minimumServerMajor).0")
        }
        async let features = client.serverFeatures()
        async let config = client.serverConfig()
        return ImmichServerInfo(baseURL: base, version: version,
                                features: try await features, config: try await config)
    }

    /// Follows `/.well-known/immich` when the server publishes it. Absence is normal — it is
    /// served by Immich's web frontend, which not every deployment exposes at the root.
    static func resolveWellKnown(_ candidate: URL, session: URLSession) async -> URL? {
        var request = URLRequest(url: candidate.appendingPathComponent(".well-known/immich"),
                                 timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let wellKnown = try? JSONDecoder().decode(Immich.WellKnown.self, from: data) else {
            return nil
        }
        return baseURL(forAPIEndpoint: wellKnown.api.endpoint, relativeTo: candidate)
    }

    /// The well-known endpoint names the API root (`/api`, or a full URL on another host);
    /// the client wants the base that `/api` hangs off.
    static func baseURL(forAPIEndpoint endpoint: String, relativeTo candidate: URL) -> URL? {
        let absolute: URL?
        if endpoint.contains("://") {
            absolute = URL(string: endpoint)
        } else if endpoint.hasPrefix("/") {
            var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false)
            components?.path = endpoint
            components?.query = nil
            absolute = components?.url
        } else {
            absolute = candidate.appendingPathComponent(endpoint)
        }
        return absolute.flatMap { ImmichAuthSession.normalizeServerURL($0.absoluteString) }
    }
}

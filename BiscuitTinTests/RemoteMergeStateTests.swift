import XCTest
@testable import BiscuitTin

/// `RemoteMergeState.patch` applies a server change to the timeline without a rebuild, so it must
/// land on exactly what a rebuild would have built (D20).
final class RemoteMergeStateTests: XCTestCase {

    /// Small deterministic generator, so a failure reproduces.
    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        mutating func chance(_ percent: Int) -> Bool { next(100) < percent }
    }

    /// A stand-in for the server cache in SQLite.
    private struct Server {
        var rows: [String: AssetStub] = [:]
        var links: [String: String] = [:]

        var state: RemoteMergeState {
            RemoteMergeState(stubs: rows.values.sorted { $0.captureDate > $1.captureDate }, links: links)
        }
    }

    private var nextDate = 0.0

    /// Every stub gets a distinct date, so the expected order has no ties to break arbitrarily.
    private func freshDate() -> Date {
        nextDate += 1
        return Date(timeIntervalSince1970: 1_700_000_000 + nextDate * 60)
    }

    private func stub(_ id: AssetID) -> AssetStub {
        AssetStub(id: id, captureDate: freshDate(),
                  hasLocal: id.localIdentifier != nil, hasRemote: id.immichID != nil,
                  kind: .image, durationSeconds: 0, pixelWidth: 100, pixelHeight: 100,
                  latitude: .nan, longitude: .nan)
    }

    func testPatchedTimelineMatchesAFullMerge() {
        for seed in 1...40 {
            var random = Generator(state: UInt64(seed))
            let locals = (0..<12).map { stub(.local("L\($0)")) }
            // Some linked local assets are not on the device: Free Up Space removed them (D18).
            let present = locals.filter { _ in random.chance(70) }
            let presentDates = Dictionary(uniqueKeysWithValues: present.map { ($0.id.localIdentifier!, $0.captureDate) })

            var server = Server()
            for n in 0..<20 where random.chance(70) {
                server.rows["R\(n)"] = stub(.remote("R\(n)"))
                if random.chance(50) { server.links["R\(n)"] = "L\(random.next(12))" }
            }
            var state = server.state
            var index = state.mergeData.merged(withLocal: present)

            for step in 0..<25 {
                var touched = Set<String>()
                for _ in 0..<(1 + random.next(3)) {
                    let immichID = "R\(random.next(20))"
                    touched.insert(immichID)
                    switch random.next(5) {
                    case 0: server.rows[immichID] = stub(.remote(immichID))   // new, or re-dated
                    case 1: server.rows[immichID] = nil                        // deleted or trashed
                    case 2: server.links[immichID] = "L\(random.next(12))"     // linked or retargeted
                    case 3: server.links[immichID] = nil                       // unlinked
                    default: break                                             // reported, unchanged
                    }
                }

                let transition = state.update(stubsFor: touched,
                                              stubs: touched.compactMap { server.rows[$0] },
                                              linksFor: touched,
                                              links: server.links.filter { touched.contains($0.key) })
                let dates = presentDates.filter { transition.localIdentifiers.contains($0.key) }
                _ = state.patch(&index, for: transition, localCaptureDates: dates)

                let expected = server.state.mergeData.merged(withLocal: present)
                XCTAssertEqual(index.stubs, expected.stubs, "seed \(seed), step \(step)")
                XCTAssertEqual(state.stubs.stubs, server.state.stubs.stubs, "seed \(seed), step \(step)")
                guard index.stubs == expected.stubs else { return }
            }
        }
    }

    /// The store can patch after a rebuild has already merged the same state, so a second
    /// application must change nothing.
    func testPatchIsIdempotent() {
        let local = stub(.local("L1"))
        var server = Server()
        server.rows = ["R1": stub(.remote("R1")), "R2": stub(.remote("R2"))]
        var state = server.state
        var index = state.mergeData.merged(withLocal: [local])

        server.links["R1"] = "L1"
        server.rows["R2"] = stub(.remote("R2"))
        let transition = state.update(stubsFor: ["R1", "R2"], stubs: Array(server.rows.values),
                                      linksFor: ["R1", "R2"], links: server.links)
        let dates = ["L1": local.captureDate]

        XCTAssertTrue(state.patch(&index, for: transition, localCaptureDates: dates))
        let once = index
        XCTAssertFalse(state.patch(&index, for: transition, localCaptureDates: dates))
        XCTAssertEqual(index, once)

        var rebuilt = server.state.mergeData.merged(withLocal: [local])
        XCTAssertFalse(state.patch(&rebuilt, for: transition, localCaptureDates: dates))
        XCTAssertEqual(rebuilt, once)
    }

    /// Past the splice threshold the state switches to the bulk index operations, which must
    /// agree with the splices.
    func testLargeUpdateMatchesAFreshState() {
        var server = Server()
        for n in 0..<300 { server.rows["R\(n)"] = stub(.remote("R\(n)")) }
        var state = server.state

        var touched = Set<String>()
        for n in stride(from: 0, to: 300, by: 2) {
            touched.insert("R\(n)")
            server.rows["R\(n)"] = n % 4 == 0 ? nil : stub(.remote("R\(n)"))
        }
        _ = state.update(stubsFor: touched, stubs: touched.compactMap { server.rows[$0] },
                         linksFor: [], links: [:])

        XCTAssertEqual(state.stubs.stubs, server.state.stubs.stubs)
    }

    func testPositionLooksOnlyAtTheGivenDate() {
        let a = stub(.local("a"))
        let b = stub(.local("b"))
        let index = TimelineIndex([b, a])

        XCTAssertEqual(index.position(of: a.id, capturedAt: a.captureDate), 1)
        XCTAssertNil(index.position(of: a.id, capturedAt: b.captureDate))
        XCTAssertNil(index.position(of: .local("absent"), capturedAt: a.captureDate))
    }
}

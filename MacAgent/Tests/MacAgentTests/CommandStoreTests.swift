import XCTest
import YoutumuKit
@testable import MacAgentCore

final class CommandStoreTests: XCTestCase {
    func testFirstSeenReturnsNil() {
        XCTAssertNil(CommandStore().cached("A"))
    }
    func testDuplicateReturnsRecordedResponseWithDuplicateFlag() {
        let s = CommandStore()
        s.record("A", CommandResponse(stateVersion: 3, duplicate: false))
        XCTAssertEqual(s.cached("A"), CommandResponse(stateVersion: 3, duplicate: true))
    }
    func testEvictionDropsOldestOnly() {
        let s = CommandStore(capacity: 2)
        s.record("A", CommandResponse(stateVersion: 1, duplicate: false))
        s.record("B", CommandResponse(stateVersion: 2, duplicate: false))
        s.record("C", CommandResponse(stateVersion: 3, duplicate: false))
        XCTAssertNil(s.cached("A"))
        XCTAssertNotNil(s.cached("B"))
        XCTAssertNotNil(s.cached("C"))
    }
    func testPlayerStateRoundTrip() throws {
        let st = PlayerState(stateVersion: 7, playback: .playing, trackId: "abc",
                             title: "t", artist: "a", positionSec: 1.5, durationSec: 200)
        let decoded = try JSONDecoder().decode(PlayerState.self, from: JSONEncoder().encode(st))
        XCTAssertEqual(decoded, st)
    }
}

import XCTest
import YoutumuKit
@testable import MacAgentCore

final class PlayerStateServiceTests: XCTestCase {
    private func snap(id: String, paused: Bool = false, hasVideo: Bool = true) -> YTMSnapshot {
        YTMSnapshot(videoId: id, title: "T-\(id)", byline: "A • Al", paused: paused,
                    position: 0, duration: 100, hasVideo: hasVideo)
    }

    func testIngestBumpsVersionOnChange() {
        let s = PlayerStateService()
        let v0 = s.state().stateVersion
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        XCTAssertGreaterThan(s.state().stateVersion, v0)
        XCTAssertEqual(s.state().trackId, "a")
        XCTAssertEqual(s.state().playback, .playing)
    }

    func testIngestIdenticalSnapshotNoBump() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        let v = s.state().stateVersion
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(s.state().stateVersion, v)   // position은 상태 비교에서 제외
    }

    func testTrackChangeAfterCommandIsCommandCause() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        s.noteCommand(now: Date(timeIntervalSince1970: 10))
        let m = s.ingest(snap(id: "b"), now: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(m?.cause, .command)
        XCTAssertEqual(m?.trackId, "b")
    }

    func testTrackChangeWithoutCommandIsNatural() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        let m = s.ingest(snap(id: "b"), now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(m?.cause, .natural)
    }

    func testMarkerSeqIncreases() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        let m1 = s.ingest(snap(id: "b"), now: Date(timeIntervalSince1970: 1))
        let m2 = s.ingest(snap(id: "c"), now: Date(timeIntervalSince1970: 2))
        XCTAssertLessThan(m1!.seq, m2!.seq)
    }

    func testFirstSnapshotEmitsNoMarker() {
        // 서버 기동 직후 "이미 재생 중이던 곡"은 전환이 아니다
        let s = PlayerStateService()
        XCTAssertNil(s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0)))
    }

    func testNoVideoMapsToStopped() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "", hasVideo: false), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(s.state().playback, .stopped)
    }

    func testPausedMapsToPaused() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a", paused: true), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(s.state().playback, .paused)
    }
}

import XCTest
@testable import YoutumuKit

final class WatchPlaybackTests: XCTestCase {
    private func state(_ sv: UInt64, _ playback: PlaybackState = .playing,
                       title: String = "Song A", artist: String = "Artist A") -> PlayerState {
        PlayerState(stateVersion: sv, playback: playback, trackId: "t1",
                    title: title, artist: artist, positionSec: 0, durationSec: 100)
    }

    // §15 시작 라우트
    func testStartRoutePlayingGoesNowPlaying() {
        XCTAssertEqual(StartRoute.decide(state(1, .playing)), .nowPlaying)
    }
    func testStartRouteOtherwisePlaylists() {
        XCTAssertEqual(StartRoute.decide(state(1, .paused)), .playlists)
        XCTAssertEqual(StartRoute.decide(state(1, .stopped)), .playlists)
        XCTAssertEqual(StartRoute.decide(nil), .playlists)
    }

    // §21 overlay 우선 표시
    func testOverlayWinsWhileActive() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let ov = OptimisticOverlay(playback: .playing, title: "Next Song", artist: "B",
                                   baseStateVersion: 10, appliedAt: t0)
        let r = Reconcile.resolve(server: state(10), overlay: ov, now: t0.addingTimeInterval(1))
        XCTAssertEqual(r.display.title, "Next Song")
        XCTAssertEqual(r.display.playback, .playing)
        XCTAssertNotNil(r.overlay)
    }

    // §22 서버가 따라잡으면 해제 (stateVersion 증가)
    func testOverlayClearedWhenServerCatchesUp() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let ov = OptimisticOverlay(playback: nil, title: "Next Song", artist: "B",
                                   baseStateVersion: 10, appliedAt: t0)
        let r = Reconcile.resolve(server: state(11, .playing, title: "Next Song", artist: "B"),
                                  overlay: ov, now: t0.addingTimeInterval(1))
        XCTAssertNil(r.overlay)
        XCTAssertEqual(r.display.title, "Next Song")   // 이제 서버 값
    }

    // §21 rollback: timeout 시 마지막 확인된 서버 상태로
    func testOverlayTimeoutRollsBackToServer() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let ov = OptimisticOverlay(playback: .playing, title: "Next Song", artist: "B",
                                   baseStateVersion: 10, appliedAt: t0)
        let r = Reconcile.resolve(server: state(10, .paused), overlay: ov,
                                  now: t0.addingTimeInterval(5.1))
        XCTAssertNil(r.overlay)
        XCTAssertEqual(r.display.title, "Song A")
        XCTAssertEqual(r.display.playback, .paused)
    }

    // overlay 일부 필드만 있는 경우 나머지는 서버 값
    func testPartialOverlayFallsThroughToServer() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let ov = OptimisticOverlay(playback: .paused, title: nil, artist: nil,
                                   baseStateVersion: 10, appliedAt: t0)
        let r = Reconcile.resolve(server: state(10, .playing), overlay: ov, now: t0)
        XCTAssertEqual(r.display.title, "Song A")
        XCTAssertEqual(r.display.playback, .paused)
    }

    // 서버 nil (첫 폴링 전): overlay 없으면 빈 표시
    func testNilServerShowsEmptyStopped() {
        let r = Reconcile.resolve(server: nil, overlay: nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r.display, Reconcile.Display(title: "", artist: "", playback: .stopped))
    }

    // §22 링크 상태 판정
    func testLinkStateThresholds() {
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 0), .ok)
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 1), .degraded)
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 2), .degraded)
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 3), .down)
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 9), .down)
    }
}

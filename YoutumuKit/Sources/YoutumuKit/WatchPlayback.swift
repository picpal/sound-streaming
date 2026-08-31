import Foundation

/// Watch 클라이언트 상태 로직 (spec §15·§21·§22). 서버와 무관한 순수 함수 — Watch 앱에 테스트
/// 타깃이 없어 여기서 XCTest로 검증한다.

public enum ControlLinkState: Equatable { case ok, degraded, down }          // §22 REST 연결 축
public enum AudioStreamState: Equatable { case disconnected, connecting, streaming, stalled }

/// §15 앱 시작 라우트: 재생 중이면 Now Playing 직행, 아니면 Playlists.
public enum StartRoute: Equatable {
    case nowPlaying, playlists
    public static func decide(_ state: PlayerState?) -> StartRoute {
        state?.playback == .playing ? .nowPlaying : .playlists
    }
}

/// §21 optimistic 전환의 화면 오버레이. 서버가 따라잡거나 timeout이면 해제된다.
public struct OptimisticOverlay: Equatable {
    public var playback: PlaybackState?
    public var title: String?
    public var artist: String?
    public var trackId: String?              // §21 — artwork도 optimistic 전환 (nil이면 서버값 유지)
    public var baseStateVersion: UInt64      // 적용 시점의 서버 stateVersion
    public var appliedAt: Date
    public init(playback: PlaybackState?, title: String?, artist: String?,
                baseStateVersion: UInt64, appliedAt: Date, trackId: String? = nil) {
        self.playback = playback; self.title = title; self.artist = artist
        self.baseStateVersion = baseStateVersion; self.appliedAt = appliedAt
        self.trackId = trackId
    }
}

public enum Reconcile {
    public struct Display: Equatable {
        public let title: String
        public let artist: String
        public let playback: PlaybackState
        public let trackId: String                       // artwork 표시용 — overlay 우선 (§21)
        public init(title: String, artist: String, playback: PlaybackState, trackId: String = "") {
            self.title = title; self.artist = artist; self.playback = playback; self.trackId = trackId
        }
    }

    static let overlayTimeout: TimeInterval = 5   // §21: 이 시간 내 서버 미반영이면 rollback

    /// 실제 Player State가 최종 Source of Truth (§21) — overlay는 표시용 임시 상태일 뿐이다.
    public static func resolve(server: PlayerState?, overlay: OptimisticOverlay?, now: Date)
        -> (display: Display, overlay: OptimisticOverlay?) {
        let base = Display(title: server?.title ?? "", artist: server?.artist ?? "",
                           playback: server?.playback ?? .stopped, trackId: server?.trackId ?? "")
        guard let ov = overlay else { return (base, nil) }
        let caughtUp = (server?.stateVersion ?? 0) > ov.baseStateVersion
        let timedOut = now.timeIntervalSince(ov.appliedAt) > overlayTimeout
        if caughtUp || timedOut { return (base, nil) }   // 해제 — timeout이면 결과적으로 rollback
        return (Display(title: ov.title ?? base.title,
                        artist: ov.artist ?? base.artist,
                        playback: ov.playback ?? base.playback,
                        trackId: ov.trackId ?? base.trackId), ov)
    }

    /// §22 ControlLinkState: 폴링 연속 실패 0회 ok / 1–2회 degraded / 3회+ down.
    public static func linkState(consecutiveFailures: Int) -> ControlLinkState {
        switch consecutiveFailures {
        case 0: return .ok
        case 1, 2: return .degraded
        default: return .down
        }
    }
}

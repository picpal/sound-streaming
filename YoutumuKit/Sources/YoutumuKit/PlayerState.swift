import Foundation

public enum PlaybackState: String, Codable { case stopped, playing, paused }

public struct PlayerState: Codable, Equatable {
    public var stateVersion: UInt64          // 단조 증가 — polling 응답 역전 방지 (spec §5·§22)
    public var playback: PlaybackState
    public var trackId: String
    public var title: String
    public var artist: String
    public var positionSec: Double
    public var durationSec: Double
    /// Agent→Watch 전용: CDP 폴링이 살아 있는지 (§20 정직한 오류 — Chrome/YTM 탭 다운 구분).
    /// 구버전 Agent 응답에는 없을 수 있어 optional. stateVersion과 무관 (변해도 버전 증가 없음).
    public var browserOk: Bool?
    public init(stateVersion: UInt64, playback: PlaybackState, trackId: String,
                title: String, artist: String, positionSec: Double, durationSec: Double,
                browserOk: Bool? = nil) {
        self.stateVersion = stateVersion; self.playback = playback; self.trackId = trackId
        self.title = title; self.artist = artist
        self.positionSec = positionSec; self.durationSec = durationSec
        self.browserOk = browserOk
    }
}

public struct CommandResponse: Codable, Equatable {
    public let stateVersion: UInt64
    public let duplicate: Bool
    public init(stateVersion: UInt64, duplicate: Bool) {
        self.stateVersion = stateVersion; self.duplicate = duplicate
    }
}

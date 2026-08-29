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
    public init(stateVersion: UInt64, playback: PlaybackState, trackId: String,
                title: String, artist: String, positionSec: Double, durationSec: Double) {
        self.stateVersion = stateVersion; self.playback = playback; self.trackId = trackId
        self.title = title; self.artist = artist
        self.positionSec = positionSec; self.durationSec = durationSec
    }
}

public struct CommandResponse: Codable, Equatable {
    public let stateVersion: UInt64
    public let duplicate: Bool
    public init(stateVersion: UInt64, duplicate: Bool) {
        self.stateVersion = stateVersion; self.duplicate = duplicate
    }
}

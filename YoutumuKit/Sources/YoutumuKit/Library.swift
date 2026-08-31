import Foundation

// Phase 2 wire 모델 (spec §5·§9·§19). Watch(Phase 5)와 공유하므로 YoutumuKit에 둔다.

public struct PlaylistSummary: Codable, Equatable, Hashable {
    public let playlistId: String
    public let title: String
    public let trackCount: Int
    public init(playlistId: String, title: String, trackCount: Int) {
        self.playlistId = playlistId; self.title = title; self.trackCount = trackCount
    }
}

public struct TrackSummary: Codable, Equatable {
    public let trackId: String
    public let title: String
    public let artist: String
    public let durationSec: Int
    public let unavailable: Bool          // 삭제·재생 불가 곡 (spec §9)
    public init(trackId: String, title: String, artist: String, durationSec: Int, unavailable: Bool) {
        self.trackId = trackId; self.title = title; self.artist = artist
        self.durationSec = durationSec; self.unavailable = unavailable
    }
}

public struct PlaylistPage: Codable, Equatable {
    public let items: [TrackSummary]
    public let total: Int                 // 페이지와 무관한 전체 곡 수
    public let offset: Int
    public init(items: [TrackSummary], total: Int, offset: Int) {
        self.items = items; self.total = total; self.offset = offset
    }
}

public struct QueueItem: Codable, Equatable {
    public let position: Int              // Queue 이동은 position 기준 — 중복 곡 대응 (spec §5)
    public let title: String
    public let artist: String
    public let current: Bool
    public init(position: Int, title: String, artist: String, current: Bool) {
        self.position = position; self.title = title; self.artist = artist; self.current = current
    }
}

public struct QueueSnapshot: Codable, Equatable {
    public let stateVersion: UInt64       // queue jump의 기대 stateVersion 출처 (spec §5 409)
    public let items: [QueueItem]
    public init(stateVersion: UInt64, items: [QueueItem]) {
        self.stateVersion = stateVersion; self.items = items
    }
}

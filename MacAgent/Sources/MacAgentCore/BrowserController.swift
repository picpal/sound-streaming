import Foundation
import YoutumuKit

public struct YTMSnapshot: Decodable, Equatable {
    public let videoId: String
    public let title: String
    public let byline: String
    public let paused: Bool
    public let position: Double
    public let duration: Double
    public let hasVideo: Bool

    /// byline("Artist • Album • Year")에서 artist만 추출
    public static func artist(fromByline byline: String) -> String {
        byline.components(separatedBy: "•").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

public protocol PlayerControlling {
    func play() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func playTrack(videoId: String, playlistId: String?) async throws
}

public final class BrowserController: PlayerControlling, LibraryProviding {
    private let cdp: CDPClient
    public init(cdp: CDPClient) { self.cdp = cdp }

    /// 연결이 죽어 있으면 1회 재연결 후 재시도 (Chrome 재시작·탭 리로드 대응)
    private func eval(_ js: String, awaitPromise: Bool = false) async throws -> String? {
        do { return try await cdp.evaluate(js, awaitPromise: awaitPromise) }
        catch { try await cdp.connect(); return try await cdp.evaluate(js, awaitPromise: awaitPromise) }
    }

    public func play() async throws { _ = try await eval(YTM.play) }
    public func pause() async throws { _ = try await eval(YTM.pause) }
    public func next() async throws { _ = try await eval(YTM.next) }
    public func previous() async throws { _ = try await eval(YTM.previous) }
    public func playTrack(videoId: String, playlistId: String?) async throws {
        _ = try await eval(YTM.playTrack(videoId: videoId, playlistId: playlistId))
    }

    public func snapshot() async throws -> YTMSnapshot {
        guard let json = try await eval(YTM.snapshot),
              let snap = try? JSONDecoder().decode(YTMSnapshot.self, from: Data(json.utf8))
        else { throw CDPError.badResponse }
        return snap
    }

    @discardableResult
    public func dismissYouTherePopup() async throws -> Bool {
        try await eval(YTM.dismissYouThere) == "true"
    }

    public func listPlaylists() async throws -> [PlaylistInfo] {
        guard let json = try await eval(YTM.listPlaylists, awaitPromise: true),
              let env = try? JSONDecoder().decode(PlaylistListEnvelope.self, from: Data(json.utf8))
        else { throw CDPError.badResponse }
        return env.playlists
    }

    public func playlistTracks(playlistId: String) async throws -> [TrackSummary] {
        guard let json = try await eval(YTM.playlistTracks(playlistId: playlistId), awaitPromise: true),
              let env = try? JSONDecoder().decode(TrackListEnvelope.self, from: Data(json.utf8))
        else { throw CDPError.badResponse }
        return env.tracks
    }

    public func queueItems() async throws -> [QueueItemInfo] {
        guard let json = try await eval(YTM.queueSnapshot),
              let env = try? JSONDecoder().decode(QueueListEnvelope.self, from: Data(json.utf8))
        else { throw CDPError.badResponse }
        return env.queue.map {
            QueueItemInfo(item: QueueItem(position: $0.position, title: $0.title, artist: $0.artist,
                                          current: $0.current, trackId: $0.trackId),
                          thumbnailUrl: $0.thumb)
        }
    }

    public func jumpQueue(position: Int) async throws -> Bool {
        try await eval(YTM.jumpQueue(position: position)) == "true"
    }

    public func playPlaylist(playlistId: String) async throws {
        _ = try await eval(YTM.playPlaylist(playlistId: playlistId))
    }
}

public struct PlaylistInfo: Decodable, Equatable {
    public let playlistId: String
    public let title: String
    public let trackCount: Int
    public let thumbnailUrl: String      // Watch에 직접 노출하지 않는다 — ArtworkService 등록용 (spec §9 단일 origin)
    public init(playlistId: String, title: String, trackCount: Int, thumbnailUrl: String) {
        self.playlistId = playlistId; self.title = title
        self.trackCount = trackCount; self.thumbnailUrl = thumbnailUrl
    }
}

public protocol LibraryProviding {
    func listPlaylists() async throws -> [PlaylistInfo]
    func playlistTracks(playlistId: String) async throws -> [TrackSummary]
    func queueItems() async throws -> [QueueItemInfo]
    func jumpQueue(position: Int) async throws -> Bool      // false = 해당 position 없음 (경합)
    func playPlaylist(playlistId: String) async throws
}

struct PlaylistListEnvelope: Decodable { let playlists: [PlaylistInfo] }
struct TrackListEnvelope: Decodable { let tracks: [TrackSummary] }
struct QueueListEnvelope: Decodable { let queue: [RawQueueItem] }
struct RawQueueItem: Decodable {
    let position: Int; let title: String; let artist: String; let current: Bool
    let trackId: String?; let thumb: String?
}

/// Queue 항목 + Agent 내부 전용 썸네일 URL — Watch 응답에는 item만 나간다 (spec §9 단일 origin)
public struct QueueItemInfo {
    public let item: QueueItem
    public let thumbnailUrl: String?
    public init(item: QueueItem, thumbnailUrl: String?) {
        self.item = item; self.thumbnailUrl = thumbnailUrl
    }
}

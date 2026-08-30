import Foundation
import YoutumuKit

/// Watch가 화면을 열 때마다 브라우저를 scraping하지 않기 위한 TTL 캐시 (spec §9). 메모리 전용.
/// fill은 lock 밖에서 실행 — 동시 요청이 겹치면 중복 fetch가 날 수 있으나(개인용 단일 Watch) 무해.
public final class MetadataCache {
    private let lock = NSLock()
    private var playlistsEntry: (value: [PlaylistInfo], at: Date)?
    private var tracksEntries: [String: (value: [TrackSummary], at: Date)] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 300) { self.ttl = ttl }

    private func cachedPlaylists(now: Date) -> [PlaylistInfo]? {
        lock.lock()
        defer { lock.unlock() }
        if let e = playlistsEntry, now.timeIntervalSince(e.at) < ttl {
            return e.value
        }
        return nil
    }

    private func storePlaylists(_ value: [PlaylistInfo], at: Date) {
        lock.lock()
        defer { lock.unlock() }
        playlistsEntry = (value, at)
    }

    public func playlists(now: Date = Date(),
                          fill: () async throws -> [PlaylistInfo]) async throws -> [PlaylistInfo] {
        if let cached = cachedPlaylists(now: now) {
            return cached
        }
        let v = try await fill()
        storePlaylists(v, at: now)
        return v
    }

    private func cachedTracks(playlistId: String, now: Date) -> [TrackSummary]? {
        lock.lock()
        defer { lock.unlock() }
        if let e = tracksEntries[playlistId], now.timeIntervalSince(e.at) < ttl {
            return e.value
        }
        return nil
    }

    private func storeTracks(_ value: [TrackSummary], forPlaylistId playlistId: String, at: Date) {
        lock.lock()
        defer { lock.unlock() }
        tracksEntries[playlistId] = (value, at)
    }

    public func tracks(playlistId: String, now: Date = Date(),
                       fill: () async throws -> [TrackSummary]) async throws -> [TrackSummary] {
        if let cached = cachedTracks(playlistId: playlistId, now: now) {
            return cached
        }
        let v = try await fill()
        storeTracks(v, forPlaylistId: playlistId, at: now)
        return v
    }
}

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

    public func playlists(now: Date = Date(),
                          fill: () async throws -> [PlaylistInfo]) async throws -> [PlaylistInfo] {
        lock.lock()
        if let e = playlistsEntry, now.timeIntervalSince(e.at) < ttl {
            let v = e.value; lock.unlock(); return v
        }
        lock.unlock()
        let v = try await fill()
        lock.lock(); playlistsEntry = (v, now); lock.unlock()
        return v
    }

    public func tracks(playlistId: String, now: Date = Date(),
                       fill: () async throws -> [TrackSummary]) async throws -> [TrackSummary] {
        lock.lock()
        if let e = tracksEntries[playlistId], now.timeIntervalSince(e.at) < ttl {
            let v = e.value; lock.unlock(); return v
        }
        lock.unlock()
        let v = try await fill()
        lock.lock(); tracksEntries[playlistId] = (v, now); lock.unlock()
        return v
    }
}

import XCTest
@testable import MacAgentCore
import YoutumuKit

final class MetadataCacheTests: XCTestCase {
    private let p1 = PlaylistInfo(playlistId: "PL1", title: "A", trackCount: 1, thumbnailUrl: "")
    private let t1 = TrackSummary(trackId: "v1", title: "T", artist: "A", durationSec: 10, unavailable: false)

    func testFillsOnceWithinTTL() async throws {
        let cache = MetadataCache(ttl: 300)
        var calls = 0
        let base = Date()
        _ = try await cache.playlists(now: base) { calls += 1; return [self.p1] }
        let second = try await cache.playlists(now: base.addingTimeInterval(299)) { calls += 1; return [] }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(second, [p1])              // 캐시 히트 — fill 미호출
    }

    func testRefetchesAfterTTL() async throws {
        let cache = MetadataCache(ttl: 300)
        var calls = 0
        let base = Date()
        _ = try await cache.playlists(now: base) { calls += 1; return [self.p1] }
        _ = try await cache.playlists(now: base.addingTimeInterval(301)) { calls += 1; return [] }
        XCTAssertEqual(calls, 2)
    }

    func testTracksCachedPerPlaylist() async throws {
        let cache = MetadataCache(ttl: 300)
        var calls = 0
        let base = Date()
        _ = try await cache.tracks(playlistId: "PL1", now: base) { calls += 1; return [self.t1] }
        _ = try await cache.tracks(playlistId: "PL2", now: base) { calls += 1; return [] }
        let hit = try await cache.tracks(playlistId: "PL1", now: base) { calls += 1; return [] }
        XCTAssertEqual(calls, 2)                   // PL1은 히트, PL2만 추가 fill
        XCTAssertEqual(hit, [t1])
    }

    func testFillErrorPropagatesAndNothingCached() async {
        struct E: Error {}
        let cache = MetadataCache(ttl: 300)
        do {
            _ = try await cache.playlists(now: Date()) { throw E() }
            XCTFail("expected throw")
        } catch {}
        var calls = 0
        _ = try? await cache.playlists(now: Date()) { calls += 1; return [] }
        XCTAssertEqual(calls, 1)                   // 실패는 캐시되지 않는다
    }
}

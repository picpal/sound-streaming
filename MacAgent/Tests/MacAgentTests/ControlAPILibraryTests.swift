import XCTest
@testable import MacAgentCore
import YoutumuKit

/// LibraryProviding mock — 호출 기록 + 조작 가능 응답
private final class MockLibrary: LibraryProviding {
    var playlists: [PlaylistInfo] = []
    var tracks: [TrackSummary] = []
    var queue: [QueueItemInfo] = []
    var jumpResult = true
    var playlistCalls: [String] = []
    var jumpCalls: [Int] = []
    var listCalls = 0
    var shouldThrow = false
    struct E: Error {}
    func listPlaylists() async throws -> [PlaylistInfo] {
        if shouldThrow { throw E() }; listCalls += 1; return playlists
    }
    func playlistTracks(playlistId: String) async throws -> [TrackSummary] {
        if shouldThrow { throw E() }; return tracks
    }
    func queueItems() async throws -> [QueueItemInfo] {
        if shouldThrow { throw E() }; return queue
    }
    func jumpQueue(position: Int) async throws -> Bool {
        if shouldThrow { throw E() }; jumpCalls.append(position); return jumpResult
    }
    func playPlaylist(playlistId: String) async throws {
        if shouldThrow { throw E() }; playlistCalls.append(playlistId)
    }
}

/// PlayerControlling mock (기존 라우트 유지 확인용 최소)
private final class NoopController: PlayerControlling {
    func play() async throws {}
    func pause() async throws {}
    func next() async throws {}
    func previous() async throws {}
    func playTrack(videoId: String, playlistId: String?) async throws {}
}

final class ControlAPILibraryTests: XCTestCase {
    private var lib: MockLibrary!
    private var svc: PlayerStateService!
    private var api: ControlAPI!
    private var artwork: ArtworkService!

    override func setUp() {
        lib = MockLibrary()
        svc = PlayerStateService()
        artwork = ArtworkService()
        api = ControlAPI(store: CommandStore(), svc: svc, controller: NoopController(),
                         library: lib, cache: MetadataCache(ttl: 300), artwork: artwork)
    }

    private func get(_ path: String, query: [String: String] = [:]) async -> ApiResponse {
        await api.handle(ApiRequest(method: "GET", path: path, body: Data(), query: query))
    }
    private func post(_ path: String, body: String) async -> ApiResponse {
        await api.handle(ApiRequest(method: "POST", path: path, body: Data(body.utf8)))
    }
    private func cmdBody(_ extra: String = "") -> String {
        #"{"commandId": "\#(UUID().uuidString)"\#(extra)}"#
    }

    func testListPlaylistsMapsToWireModel() async throws {
        lib.playlists = [PlaylistInfo(playlistId: "PL1", title: "Run", trackCount: 3, thumbnailUrl: "https://x/y.jpg")]
        let resp = await get("/api/playlists")
        XCTAssertEqual(resp.status, 200)
        let out = try JSONDecoder().decode([PlaylistSummary].self, from: resp.body)
        XCTAssertEqual(out, [PlaylistSummary(playlistId: "PL1", title: "Run", trackCount: 3)])
    }

    func testListPlaylistsUsesCache() async {
        lib.playlists = []
        _ = await get("/api/playlists")
        _ = await get("/api/playlists")
        XCTAssertEqual(lib.listCalls, 1)
    }

    func testListPlaylistsFetchFailureIs502() async {
        lib.shouldThrow = true
        let resp = await get("/api/playlists")
        XCTAssertEqual(resp.status, 502)
    }

    func testPlaylistDetailPagination() async throws {
        lib.tracks = (0..<10).map { TrackSummary(trackId: "v\($0)", title: "T\($0)", artist: "A", durationSec: 60, unavailable: false) }
        let resp = await get("/api/playlists/PL1", query: ["offset": "8", "limit": "5"])
        let page = try JSONDecoder().decode(PlaylistPage.self, from: resp.body)
        XCTAssertEqual(page.items.map(\.trackId), ["v8", "v9"])
        XCTAssertEqual(page.total, 10)
        XCTAssertEqual(page.offset, 8)
    }

    func testPlaylistDetailBadIdIs400() async {
        let resp = await get("/api/playlists/bad$id")
        XCTAssertEqual(resp.status, 400)
    }

    func testQueueSnapshotCarriesStateVersion() async throws {
        lib.queue = [QueueItemInfo(item: QueueItem(position: 0, title: "A", artist: "B", current: true), thumbnailUrl: nil)]
        let resp = await get("/api/queue")
        let snap = try JSONDecoder().decode(QueueSnapshot.self, from: resp.body)
        XCTAssertEqual(snap.stateVersion, svc.state().stateVersion)
        XCTAssertEqual(snap.items.count, 1)
    }

    func testPlayPlaylistCommand() async {
        let resp = await post("/api/player/playlists/PL1", body: cmdBody())
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(lib.playlistCalls, ["PL1"])
    }

    func testQueueJumpHappyPath() async {
        let sv = svc.state().stateVersion
        let resp = await post("/api/queue/2", body: cmdBody(#", "stateVersion": \#(sv)"#))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(lib.jumpCalls, [2])
    }

    func testQueueJumpStaleStateVersionIs409NoExec() async {
        let sv = svc.state().stateVersion &- 1
        let resp = await post("/api/queue/2", body: cmdBody(#", "stateVersion": \#(sv)"#))
        XCTAssertEqual(resp.status, 409)
        XCTAssertEqual(lib.jumpCalls, [])          // 실행되지 않아야 한다 (spec §5)
    }

    func testQueueJumpPositionGoneIs409() async {
        lib.jumpResult = false
        let sv = svc.state().stateVersion
        let resp = await post("/api/queue/2", body: cmdBody(#", "stateVersion": \#(sv)"#))
        XCTAssertEqual(resp.status, 409)
    }

    func testQueueJumpMissingStateVersionIs400() async {
        let resp = await post("/api/queue/2", body: cmdBody())
        XCTAssertEqual(resp.status, 400)
    }

    func testQueueJumpExtraFieldIs400() async {
        let sv = svc.state().stateVersion
        let resp = await post("/api/queue/2", body: cmdBody(#", "stateVersion": \#(sv), "x": 1"#))
        XCTAssertEqual(resp.status, 400)
    }

    func testQueueJumpDuplicateCommandIdNotReexecuted() async {
        let id = UUID().uuidString
        let sv = svc.state().stateVersion
        let body = #"{"commandId": "\#(id)", "stateVersion": \#(sv)}"#
        _ = await post("/api/queue/1", body: body)
        let dup = await post("/api/queue/1", body: body)
        XCTAssertEqual(dup.status, 200)
        XCTAssertEqual(lib.jumpCalls, [1])         // 1회만 실행
    }

    func testQueueJumpBadPositionIs400() async {
        let resp = await post("/api/queue/abc", body: cmdBody())
        XCTAssertEqual(resp.status, 400)
    }

    func testArtworkUnknownIdIs404() async {
        let resp = await get("/api/artwork/unknownid")
        XCTAssertEqual(resp.status, 404)
    }

    func testArtworkBadIdIs400() async {
        let resp = await get("/api/artwork/bad$id")
        XCTAssertEqual(resp.status, 400)
    }

    func testUnknownEndpointStill404() async {
        let resp = await get("/api/library")
        XCTAssertEqual(resp.status, 404)
    }

    func testPlayerStateRegistersCurrentTrackArtwork() async throws {
        let tid = "v1"
        _ = svc.ingest(YTMSnapshot(videoId: tid, title: "T", byline: "A • Al", paused: false,
                                   position: 0, duration: 100, hasVideo: true), now: Date())
        _ = await api.handle(ApiRequest(method: "GET", path: "/api/player", body: Data()))
        XCTAssertTrue(artwork.isRegistered(id: tid))
    }
}

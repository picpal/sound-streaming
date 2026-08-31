import XCTest
import YoutumuKit
@testable import MacAgentCore

private final class FakeController: PlayerControlling, LibraryProviding {
    var calls: [String] = []
    var shouldThrow = false
    private func rec(_ s: String) throws { calls.append(s); if shouldThrow { throw CDPError.disconnected } }
    func play() async throws { try rec("play") }
    func pause() async throws { try rec("pause") }
    func next() async throws { try rec("next") }
    func previous() async throws { try rec("previous") }
    func playTrack(videoId: String, playlistId: String?) async throws {
        try rec("track:\(videoId)" + (playlistId.map { "@\($0)" } ?? ""))
    }
    // 이 파일의 테스트는 library 라우트를 다루지 않는다 — ControlAPI init 시그니처 충족용 no-op (ControlAPILibraryTests.swift가 실동작 검증)
    func listPlaylists() async throws -> [PlaylistInfo] { [] }
    func playlistTracks(playlistId: String) async throws -> [TrackSummary] { [] }
    func queueItems() async throws -> [QueueItem] { [] }
    func jumpQueue(position: Int) async throws -> Bool { true }
    func playPlaylist(playlistId: String) async throws {}
}

final class ControlAPITests: XCTestCase {
    private var fake: FakeController!
    private var api: ControlAPI!

    override func setUp() {
        fake = FakeController()
        api = ControlAPI(store: CommandStore(), svc: PlayerStateService(), controller: fake,
                         library: fake, cache: MetadataCache(), artwork: ArtworkService())
    }

    private func post(_ path: String, _ body: String) async -> ApiResponse {
        await api.handle(ApiRequest(method: "POST", path: path, body: Data(body.utf8)))
    }
    private var okBody: String { #"{"commandId":"\#(UUID().uuidString)"}"# }

    func testGetPlayerReturnsStateJSON() async throws {
        let r = await api.handle(ApiRequest(method: "GET", path: "/api/player", body: Data()))
        XCTAssertEqual(r.status, 200)
        _ = try JSONDecoder().decode(PlayerState.self, from: r.body)
    }

    func testNextExecutesAndReturnsCommandResponse() async throws {
        let r = await post("/api/player/next", okBody)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(fake.calls, ["next"])
        let cr = try JSONDecoder().decode(CommandResponse.self, from: r.body)
        XCTAssertFalse(cr.duplicate)
    }

    func testDuplicateCommandIdNotReExecuted() async throws {
        let id = UUID().uuidString
        let body = #"{"commandId":"\#(id)"}"#
        _ = await post("/api/player/next", body)
        let r2 = await post("/api/player/next", body)
        XCTAssertEqual(fake.calls, ["next"])          // 1회만 실행 (spec §5)
        let cr = try JSONDecoder().decode(CommandResponse.self, from: r2.body)
        XCTAssertTrue(cr.duplicate)
    }

    func testMissingCommandIdRejected400() async {
        let r = await post("/api/player/play", "{}")
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testNonUUIDCommandIdRejected400() async {
        let r = await post("/api/player/play", #"{"commandId":"nope"}"#)
        XCTAssertEqual(r.status, 400)
    }

    func testUnknownFieldRejected400() async {
        // 정의되지 않은 필드는 무시가 아니라 거부 (spec §11)
        let r = await post("/api/player/play", #"{"commandId":"\#(UUID().uuidString)","js":"x"}"#)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testValidTrackIdExecutes() async {
        let r = await post("/api/player/tracks/dQw4w9WgXcQ", okBody)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(fake.calls, ["track:dQw4w9WgXcQ"])
    }

    func testTrackInPlaylistContextExecutes() async {
        let r = await post("/api/player/playlists/PLabc-123/tracks/dQw4w9WgXcQ", okBody)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(fake.calls, ["track:dQw4w9WgXcQ@PLabc-123"])
    }

    func testTrackInPlaylistInvalidIdsRejected400() async {
        let r1 = await post("/api/player/playlists/bad%2Fid/tracks/dQw4w9WgXcQ", okBody)
        XCTAssertEqual(r1.status, 400)
        let r2 = await post("/api/player/playlists/PLabc/tracks/bad!id", okBody)
        XCTAssertEqual(r2.status, 400)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testInvalidTrackIdRejected400() async {
        let r = await post("/api/player/tracks/bad%2Fid!", okBody)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testUnknownPathRejected404() async {
        let r = await post("/api/execute", okBody)
        XCTAssertEqual(r.status, 404)
    }

    func testControllerFailureReturns502AndNotCached() async {
        fake.shouldThrow = true
        let id = UUID().uuidString
        let body = #"{"commandId":"\#(id)"}"#
        let r1 = await post("/api/player/next", body)
        XCTAssertEqual(r1.status, 502)               // 실행 여부 불명 → reconcile (spec §5)
        fake.shouldThrow = false
        let r2 = await post("/api/player/next", body)
        XCTAssertEqual(r2.status, 200)               // 실패는 캐시되지 않아 재시도 가능
        XCTAssertEqual(fake.calls, ["next", "next"])
    }
}

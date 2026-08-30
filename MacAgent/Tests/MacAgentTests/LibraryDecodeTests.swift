import XCTest
@testable import MacAgentCore
import YoutumuKit

final class LibraryDecodeTests: XCTestCase {
    func testDecodePlaylistList() throws {
        let json = #"{"playlists":[{"playlistId":"PLabc","title":"Running","trackCount":42,"thumbnailUrl":"https://lh3.example/x.jpg"}]}"#
        let list = try JSONDecoder().decode(PlaylistListEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(list.playlists, [PlaylistInfo(playlistId: "PLabc", title: "Running", trackCount: 42,
                                                     thumbnailUrl: "https://lh3.example/x.jpg")])
    }

    func testDecodeTrackList() throws {
        let json = #"{"tracks":[{"trackId":"dQw4w9WgXcQ","title":"Song","artist":"Artist","durationSec":222,"unavailable":false},{"trackId":"","title":"Deleted","artist":"","durationSec":0,"unavailable":true}]}"#
        let list = try JSONDecoder().decode(TrackListEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(list.tracks.count, 2)
        XCTAssertTrue(list.tracks[1].unavailable)
    }

    func testSnippetsInterpolatePlaylistId() {
        // playlistId는 호출 전 정규식 검증 완료 전제 (spec §11) — 여기서는 삽입 위치만 확인
        XCTAssertTrue(YTM.playlistTracks(playlistId: "PLabc").contains("'VLPLabc'"))
        XCTAssertTrue(YTM.playPlaylist(playlistId: "PLabc").contains("list=PLabc"))
    }

    func testDecodeQueueList() throws {
        let json = #"{"queue":[{"position":0,"title":"A","artist":"X","current":true},{"position":1,"title":"B","artist":"Y","current":false}]}"#
        let env = try JSONDecoder().decode(QueueListEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.queue[0].current, true)
        XCTAssertEqual(env.queue[1].position, 1)
    }

    func testJumpQueueSnippetInterpolatesPosition() {
        XCTAssertTrue(YTM.jumpQueue(position: 3).contains("[3]"))
    }
}

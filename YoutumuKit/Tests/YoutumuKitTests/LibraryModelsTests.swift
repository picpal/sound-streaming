import XCTest
@testable import YoutumuKit

final class LibraryModelsTests: XCTestCase {
    func testPlaylistPageRoundTrip() throws {
        let page = PlaylistPage(
            items: [TrackSummary(trackId: "dQw4w9WgXcQ", title: "Song", artist: "Artist", durationSec: 222, unavailable: false)],
            total: 42, offset: 0)
        let data = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(PlaylistPage.self, from: data), page)
    }

    func testQueueSnapshotRoundTrip() throws {
        let snap = QueueSnapshot(stateVersion: 7,
                                 items: [QueueItem(position: 0, title: "A", artist: "B", current: true)])
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(QueueSnapshot.self, from: data), snap)
    }

    func testPlaylistSummaryDecodesFromWireJSON() throws {
        let json = #"{"playlistId":"PLabc_-123","title":"Running","trackCount":42}"#
        let p = try JSONDecoder().decode(PlaylistSummary.self, from: Data(json.utf8))
        XCTAssertEqual(p.playlistId, "PLabc_-123")
        XCTAssertEqual(p.trackCount, 42)
    }
}

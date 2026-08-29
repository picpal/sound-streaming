import XCTest
@testable import MacAgentCore

final class BrowserControllerTests: XCTestCase {
    func testSnapshotDecodesFromPageJSON() throws {
        let fixture = #"{"videoId":"dQw4w9WgXcQ","title":"Song","byline":"Artist • Album • 2024","paused":false,"position":42.5,"duration":212.0,"hasVideo":true}"#
        let s = try JSONDecoder().decode(YTMSnapshot.self, from: Data(fixture.utf8))
        XCTAssertEqual(s.videoId, "dQw4w9WgXcQ")
        XCTAssertFalse(s.paused)
        XCTAssertTrue(s.hasVideo)
    }
    func testSnapshotEmptyPlayer() throws {
        let fixture = #"{"videoId":"","title":"","byline":"","paused":true,"position":0,"duration":0,"hasVideo":false}"#
        let s = try JSONDecoder().decode(YTMSnapshot.self, from: Data(fixture.utf8))
        XCTAssertFalse(s.hasVideo)
    }
    func testArtistExtractedFromByline() {
        // byline은 "Artist • Album • Year" 형태 — 첫 세그먼트만 artist로 쓴다
        XCTAssertEqual(YTMSnapshot.artist(fromByline: "Artist • Album • 2024"), "Artist")
        XCTAssertEqual(YTMSnapshot.artist(fromByline: ""), "")
    }
}

import XCTest
@testable import YoutumuKit

final class EnvelopeTests: XCTestCase {
    func testRoundtrip() {
        let m = Marker(seq: 7, trackId: "abc", cause: .command)
        var audio: [Data] = []; var markers: [Marker] = []
        let p = EnvelopeParser()
        p.onAudio = { audio.append($0) }; p.onMarker = { markers.append($0) }
        let stream = Envelope.encode(type: .audio, payload: Data([1,2,3])) + Envelope.encodeMarker(m)
        p.feed(stream)
        XCTAssertEqual(audio, [Data([1,2,3])]); XCTAssertEqual(markers, [m])
    }
    func testByteAtATimeFeed() {  // TCP 경계 분할 대응
        let stream = Envelope.encode(type: .audio, payload: Data(repeating: 9, count: 300))
        let p = EnvelopeParser(); var got: [Data] = []
        p.onAudio = { got.append($0) }
        for b in stream { p.feed(Data([b])) }
        XCTAssertEqual(got.count, 1); XCTAssertEqual(got[0].count, 300)
    }
    func testADTSHeader() {
        let h = adtsHeader(payloadLength: 100)
        XCTAssertEqual(h.count, 7)
        XCTAssertEqual(h[0], 0xFF); XCTAssertEqual(h[1] & 0xF6, 0xF0)  // syncword + MPEG-4
        let len = (Int(h[3] & 0x03) << 11) | (Int(h[4]) << 3) | (Int(h[5]) >> 5)
        XCTAssertEqual(len, 107)  // payload + 7
    }
}

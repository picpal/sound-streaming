import XCTest
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import MacAgentCore

final class StreamServerHandlerTests: XCTestCase {
    private func makeChannel(_ server: StreamServer) -> EmbeddedChannel {
        let ch = EmbeddedChannel(handler: StreamServer.Handler(server: server))
        try! ch.connect(to: .init(ipAddress: "127.0.0.1", port: 8080)).wait()
        return ch
    }
    private func head(_ method: HTTPMethod, _ uri: String) -> HTTPServerRequestPart {
        .head(.init(version: .http1_1, method: method, uri: uri))
    }
    private func readHead(_ ch: EmbeddedChannel) throws -> HTTPResponseHead? {
        ch.embeddedEventLoop.run()
        guard case .some(.head(let h)) = try ch.readOutbound(as: HTTPServerResponsePart.self) else { return nil }
        return h
    }
    private func readBodyData(_ ch: EmbeddedChannel) throws -> Data? {
        ch.embeddedEventLoop.run()
        guard case .some(.body(.byteBuffer(var buf))) = try ch.readOutbound(as: HTTPServerResponsePart.self) else { return nil }
        return buf.readBytes(length: buf.readableBytes).map { Data($0) }
    }

    func testHealthz() throws {
        let ch = makeChannel(StreamServer(port: 0))
        try ch.writeInbound(head(.GET, "/healthz"))
        try ch.writeInbound(HTTPServerRequestPart.end(nil))
        XCTAssertEqual(try readHead(ch)?.status, .ok)
        XCTAssertEqual(try readBodyData(ch), Data(#"{"ok":true}"#.utf8))
    }

    func testOversizedBodyIs413() throws {
        let ch = makeChannel(StreamServer(port: 0))
        try ch.writeInbound(head(.POST, "/api/player/play"))
        var big = ch.allocator.buffer(capacity: 5000)
        big.writeBytes([UInt8](repeating: 0x41, count: 5000))    // maxBody 4096 초과
        try ch.writeInbound(HTTPServerRequestPart.body(big))
        XCTAssertEqual(try readHead(ch)?.status, .payloadTooLarge)
    }

    func testAudioLiveRegistersReceiverAndStreams() throws {
        let server = StreamServer(port: 0)
        let ch = makeChannel(server)
        try ch.writeInbound(head(.GET, "/audio/live"))
        let h = try readHead(ch)
        XCTAssertEqual(h?.status, .ok)
        XCTAssertEqual(h?.headers.first(name: "Content-Type"), "application/octet-stream")
        server.broadcast(Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(try readBodyData(ch), Data([0x01, 0x02, 0x03]))
    }

    func testSecondReceiverDisplacesFirst() throws {
        let server = StreamServer(port: 0)
        let ch1 = makeChannel(server)
        try ch1.writeInbound(head(.GET, "/audio/live"))
        _ = try readHead(ch1)
        let ch2 = makeChannel(server)
        try ch2.writeInbound(head(.GET, "/audio/live"))
        _ = try readHead(ch2)
        ch1.embeddedEventLoop.run(); ch2.embeddedEventLoop.run()
        XCTAssertFalse(ch1.isActive)               // 단일 수신자 (spec §6) — 이전 연결 종료
        server.broadcast(Data([0x09]))
        // readBodyData will pump the loop
        XCTAssertEqual(try readBodyData(ch2), Data([0x09]))
        XCTAssertNil(try? ch1.readOutbound(as: HTTPServerResponsePart.self) as Any?)
    }

    func testSplitURIPlain() {
        let r = StreamServer.Handler.splitURI("/api/playlists")
        XCTAssertEqual(r.path, "/api/playlists")
        XCTAssertTrue(r.query.isEmpty)
    }

    func testSplitURIWithQuery() {
        let r = StreamServer.Handler.splitURI("/api/playlists/PL1?offset=1&limit=2")
        XCTAssertEqual(r.path, "/api/playlists/PL1")
        XCTAssertEqual(r.query["offset"], "1")
        XCTAssertEqual(r.query["limit"], "2")
    }

    func testSplitURIDegenerateDoesNotCrash() {
        XCTAssertEqual(StreamServer.Handler.splitURI("?").path, "?")
        XCTAssertEqual(StreamServer.Handler.splitURI("").path, "")
    }
}

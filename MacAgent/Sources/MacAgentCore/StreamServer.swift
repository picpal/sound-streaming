import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

public final class StreamServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let port: Int
    private let lock = NSLock()
    private var receiver: Channel?          // 단일 수신자 (spec §6)
    public var api: ControlAPI?

    public init(port: Int) { self.port = port }

    public func broadcast(_ data: Data) {
        lock.lock(); let ch = receiver; lock.unlock()
        guard let ch, ch.isActive else { return }
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        ch.eventLoop.execute {
            ch.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
        }
    }

    /// 캡처 워치독용 — 살아있는 수신자가 있을 때만 자동 재시작을 허용
    public func hasReceiver() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return receiver?.isActive ?? false
    }

    private func setReceiver(_ ch: Channel) {
        lock.lock()
        receiver?.close(promise: nil)       // 이전 연결 종료
        receiver = ch
        lock.unlock()
    }

    public func run() throws {
        let server = self
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(Handler(server: server))
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
        print("StreamServer on 127.0.0.1:\(port)")
        try channel.closeFuture.wait()
    }

    final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let server: StreamServer
        private var head: HTTPRequestHead?
        private var body = Data()
        private static let maxBody = 4096     // Agent측 body 제한 (spec §11 — Caddy와 양쪽)
        init(server: StreamServer) { self.server = server }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let h):
                head = h; body.removeAll()
                if h.method == .GET, h.uri == "/audio/live" {
                    var hdr = HTTPHeaders()
                    hdr.add(name: "Content-Type", value: "application/octet-stream")
                    hdr.add(name: "Cache-Control", value: "no-store")
                    context.writeAndFlush(wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: hdr))), promise: nil)
                    server.setReceiver(context.channel)   // 이후 broadcast가 body chunk를 계속 씀
                    head = nil
                }
            case .body(var buf):
                guard head != nil else { return }         // 스트리밍 연결엔 요청 body 없음
                if body.count + buf.readableBytes > Self.maxBody {
                    writeJSON(context.channel, status: .payloadTooLarge, body: Data(#"{"error":"body too large"}"#.utf8))
                    head = nil
                    return
                }
                if let bytes = buf.readBytes(length: buf.readableBytes) { body.append(contentsOf: bytes) }
            case .end:
                guard let h = head else { return }
                head = nil
                if h.uri == "/healthz" {
                    writeJSON(context.channel, status: .ok, body: Data(#"{"ok":true}"#.utf8))
                    return
                }
                let (path, query) = Self.splitURI(h.uri)
                let req = ApiRequest(method: h.method.rawValue, path: path, body: body, query: query)
                let ch = context.channel
                let api = server.api
                Task {   // BrowserController가 async — NIO 이벤트 루프를 막지 않는다
                    let resp = await api?.handle(req) ?? ApiResponse(status: 404, body: Data(#"{"error":"unknown endpoint"}"#.utf8))
                    self.writeJSON(ch, status: .init(statusCode: resp.status), body: resp.body, contentType: resp.contentType)
                }
            }
        }

        /// uri → (path, query). 빈/이상 uri에서도 크래시하지 않는다 (llhttp lenient 모드 방어).
        static func splitURI(_ uri: String) -> (path: String, query: [String: String]) {
            let parts = uri.split(separator: "?", maxSplits: 1)
            let path = parts.first.map(String.init) ?? uri
            var query: [String: String] = [:]
            if let items = URLComponents(string: uri)?.queryItems {
                for it in items { query[it.name] = it.value ?? "" }
            }
            return (path, query)
        }

        private func writeJSON(_ ch: Channel, status: HTTPResponseStatus, body: Data,
                               contentType: String = "application/json") {
            ch.eventLoop.execute {
                var hdr = HTTPHeaders()
                hdr.add(name: "Content-Type", value: contentType)
                hdr.add(name: "Content-Length", value: "\(body.count)")
                ch.write(HTTPServerResponsePart.head(.init(version: .http1_1, status: status, headers: hdr)), promise: nil)
                var buf = ch.allocator.buffer(capacity: body.count)
                buf.writeBytes(body)
                ch.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
                ch.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            }
        }
    }
}

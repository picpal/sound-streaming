import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

final class StreamServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let port: Int
    private let lock = NSLock()
    private var receiver: Channel?          // 단일 수신자 (spec §6)

    init(port: Int) { self.port = port }

    func broadcast(_ data: Data) {
        lock.lock(); let ch = receiver; lock.unlock()
        guard let ch, ch.isActive else { return }
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        ch.eventLoop.execute {
            ch.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
        }
    }

    private func setReceiver(_ ch: Channel) {
        lock.lock()
        receiver?.close(promise: nil)       // 이전 연결 종료
        receiver = ch
        lock.unlock()
    }

    func run() throws {
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

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let server: StreamServer
        init(server: StreamServer) { self.server = server }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .head(let head) = unwrapInboundIn(data) else { return }
            switch (head.method, head.uri) {
            case (.GET, "/audio/live"):
                var h = HTTPHeaders()
                h.add(name: "Content-Type", value: "application/octet-stream")
                h.add(name: "Cache-Control", value: "no-store")
                context.writeAndFlush(wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: h))), promise: nil)
                server.setReceiver(context.channel)   // 이후 broadcast가 body chunk를 계속 씀
            case (.GET, "/healthz"):
                var h = HTTPHeaders(); h.add(name: "Content-Length", value: "2")
                context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: h))), promise: nil)
                var b = context.channel.allocator.buffer(capacity: 2); b.writeString("ok")
                context.write(wrapOutboundOut(.body(.byteBuffer(b))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            default:
                let head = HTTPResponseHead(version: .http1_1, status: .notFound)
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

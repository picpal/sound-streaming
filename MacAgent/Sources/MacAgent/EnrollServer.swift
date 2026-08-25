import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

final class EnrollServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let code: String
    private var attempts = 0
    private var issued = false

    init(code: String) { self.code = code }

    func run() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(Handler(server: self))
                }
            }
        let ch = try bootstrap.bind(host: "127.0.0.1", port: 8081).wait()
        print("EnrollServer on 127.0.0.1:8081 (Caddy :8444 경유), code=\(code), TTL 5분")
        ch.eventLoop.scheduleTask(in: .minutes(5)) { ch.close(promise: nil) }  // TTL
        try ch.closeFuture.wait()
    }

    /// 코드 검증 + 발급. 5회 실패 또는 1회 발급 후 종료 (spec §10.5)
    func issue(code reqCode: String, pubkeyPem: String) -> Data? {
        guard !issued, reqCode == code else {
            attempts += 1
            if attempts >= 5 { print("too many attempts — exiting"); exit(1) }
            return nil
        }
        let pub = FileManager.default.temporaryDirectory.appendingPathComponent("watch-pub.pem")
        let crt = FileManager.default.temporaryDirectory.appendingPathComponent("watch.crt")
        try? pubkeyPem.write(to: pub, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["scripts/ca/issue-client-from-pubkey.sh", pub.path, crt.path]
        p.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/..")
        try? p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, let der = pemToDer(try? String(contentsOf: crt)) else { return nil }
        issued = true
        return der
    }

    private func pemToDer(_ pem: String?) -> Data? {
        guard let pem else { return nil }
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: b64)
    }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let server: EnrollServer
        var body = Data()
        init(server: EnrollServer) { self.server = server }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head: body.removeAll()
            case .body(var buf): body.append(Data(buf.readBytes(length: buf.readableBytes) ?? []))
            case .end:
                struct Req: Codable { let code: String; let pubkeyPem: String }
                var status = HTTPResponseStatus.forbidden
                var payload = Data()
                if let req = try? JSONDecoder().decode(Req.self, from: body),
                   let der = server.issue(code: req.code, pubkeyPem: req.pubkeyPem) {
                    status = .ok
                    payload = try! JSONEncoder().encode(["certDer": der.base64EncodedString()])
                }
                var h = HTTPHeaders()
                h.add(name: "Content-Type", value: "application/json")
                h.add(name: "Content-Length", value: "\(payload.count)")
                context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: h))), promise: nil)
                var b = context.channel.allocator.buffer(capacity: payload.count); b.writeBytes(payload)
                context.write(wrapOutboundOut(.body(.byteBuffer(b))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

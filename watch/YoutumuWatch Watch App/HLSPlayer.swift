import AVFoundation
import Foundation
import MediaPlayer
import Network

enum RemoteCommand { case play, pause, next, previous }

/// HLS 라이브 + AVPlayer — 시스템 관리 재생이라 앱 서스펜드에도 지속 (Phase 6 핵심).
/// watchOS에는 AVAssetResourceLoader가 없어(API_UNAVAILABLE) AVPlayer가 mTLS를 직접 못 탄다.
/// 대신 로컬 루프백 HTTP 릴레이(HLSLoopbackRelay)를 띄워 AVPlayer는 127.0.0.1 평문 HTTP로 접속하고,
/// 릴레이가 실제 요청을 PinnedSessionDelegate 세션(mTLS)으로 대리 수행한다.
/// @MainActor — KVO/NotificationCenter/MPRemoteCommandCenter 콜백은 off-main에서 도착할 수 있어
/// 각 콜백 내부에서 `Task { @MainActor in ... }`로 명시적으로 홉한다 (Task 4 리뷰에서 지적된 데이터 레이스 수정).
@MainActor
final class HLSPlayer: NSObject {
    private let tlsDelegate = PinnedSessionDelegate()
    private lazy var session = URLSession(configuration: .default, delegate: tlsDelegate, delegateQueue: nil)
    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var timeObs: NSKeyValueObservation?
    private var statusObs: NSKeyValueObservation?
    private var remoteCommandsRegistered = false
    private var relay: HLSLoopbackRelay?
    var onStreaming: (() -> Void)?
    var onEnded: ((String) -> Void)?
    var onRemoteCommand: ((RemoteCommand) -> Void)?
    var volume: Float {
        get { player?.volume ?? 0.7 }
        set { player?.volume = max(0, min(1, newValue)) }
    }

    func start(host: String) async throws {
        stop()
        let av = AVAudioSession.sharedInstance()
        #if os(watchOS)
        try av.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try await av.activate()
        #else
        try av.setCategory(.playback)
        try av.setActive(true)
        #endif
        registerRemoteCommands()
        updateNowPlaying(title: "Youtumu", artist: "")

        let r = HLSLoopbackRelay(upstreamHost: host, session: session)
        relay = r
        let port: UInt16
        do {
            port = try await r.start()
        } catch {
            // 릴레이 시작 실패 시 남겨두지 않고 확실히 정리한 뒤 던진다.
            r.stop()
            relay = nil
            throw error
        }

        let url = URL(string: "http://127.0.0.1:\(port)/\(r.token)/audio/hls/live.m3u8")!
        let asset = AVURLAsset(url: url)
        let it = AVPlayerItem(asset: asset)
        it.preferredForwardBufferDuration = 1                // 지연 목표 (Global Constraints)
        let p = AVPlayer(playerItem: it)

        statusObs = it.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error.map { "\($0)" } ?? "item failed"
            Task { @MainActor [weak self] in self?.onEnded?(message) }
        }
        timeObs = p.observe(\.timeControlStatus) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor [weak self] in self?.onStreaming?() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(stalled),
                                               name: .AVPlayerItemPlaybackStalled, object: it)
        player = p; item = it
        p.play()
    }

    // NotificationCenter의 selector 콜백은 게시 스레드에서 그대로 호출되어 off-main일 수 있다 —
    // nonisolated로 받아 MainActor로 명시적으로 홉한다.
    @objc private nonisolated func stalled() {
        Task { @MainActor [weak self] in
            // 라이브 윈도우 이탈 등 — 라이브 엣지로 복귀 시도, 실패는 status 옵저버가 잡는다
            self?.seekToLiveEdge()
            self?.player?.play()
        }
    }

    /// 명령 직후 이전 곡 소리를 줄이는 헬퍼 — seekable 끝(-1s)으로 점프 (Task 4에서 사용)
    func seekToLiveEdge() {
        guard let item, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let target = CMTimeSubtract(CMTimeRangeGetEnd(range), CMTime(seconds: 1, preferredTimescale: 600))
        item.seek(to: target, completionHandler: nil)
    }

    func stop() {
        player?.pause()
        if let item { NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: item) }
        timeObs = nil; statusObs = nil
        player = nil; item = nil
        relay?.stop()
        relay = nil
    }

    private func registerRemoteCommands() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true
        let cc = MPRemoteCommandCenter.shared()
        // MPRemoteCommandCenter 타깃 클로저는 off-main에서 호출될 수 있다 — MainActor로 홉한 뒤
        // onRemoteCommand를 실행하고, 응답 자체는 즉시(비동기 완료를 기다리지 않고) .success로 반환한다.
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onRemoteCommand?(.play) }; return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onRemoteCommand?(.pause) }; return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onRemoteCommand?(.next) }; return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onRemoteCommand?(.previous) }; return .success
        }
    }

    func updateNowPlaying(title: String, artist: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Youtumu" : title,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// `NWListener.stateUpdateHandler`(`@Sendable`)에서 `CheckedContinuation`을 정확히 한 번만
/// resume하기 위한 락 보호 박스. 로컬 함수 클로저는 `@Sendable` 캡처가 안 되어 클래스로 분리.
private final class ContinuationResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<UInt16, Error>

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    /// 반환값 true = 이 호출이 경쟁에서 승리해 실제로 continuation을 resume시켰다.
    /// (ready와 3초 타임아웃이 동시에 도착할 수 있어, 진 쪽은 리스너를 취소하면 안 된다 — 호출부가 이 값으로 판단.)
    @discardableResult
    func resume(_ result: Result<UInt16, Error>) -> Bool {
        lock.lock()
        let already = resumed
        resumed = true
        lock.unlock()
        guard !already else { return false }
        switch result {
        case .success(let port): continuation.resume(returning: port)
        case .failure(let err): continuation.resume(throwing: err)
        }
        return true
    }
}

/// 로컬 루프백(127.0.0.1) HTTP 릴레이 — 요청 라인만 파싱해 `/<token>/audio/hls/...` 를
/// `https://<host>:8443/audio/hls/...` 로 mTLS 세션을 통해 대리 요청하고 응답을 그대로 돌려준다.
/// 모든 가변 상태(connections/resumed 플래그)는 전용 시리얼 큐 위에서만 손댄다 — 그 불변식 하에
/// @unchecked Sendable로 표시해 Network 프레임워크의 @Sendable 핸들러 클로저 캡처를 허용한다.
private final class HLSLoopbackRelay: @unchecked Sendable {
    let token: String = HLSLoopbackRelay.randomToken()
    private let upstreamHost: String
    private let session: URLSession
    private let queue = DispatchQueue(label: "hls.relay")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(upstreamHost: String, session: URLSession) {
        self.upstreamHost = upstreamHost
        self.session = session
    }

    private static func randomToken() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(8)
        for _ in 0..<8 { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 업스트림에 존재하는 리소스는 정확히 이 세 형태뿐이다: `live.m3u8`, `init.mp4`, `seg<digits>.m4s`.
    /// 일치하면 (경로 탐색 없는) 정규화된 이름을 그대로 반환, 아니면 nil.
    private static func allowlistedResourceName(_ rest: String) -> String? {
        if rest == "live.m3u8" || rest == "init.mp4" { return rest }
        if rest.hasPrefix("seg"), rest.hasSuffix(".m4s") {
            let digits = rest.dropFirst("seg".count).dropLast(".m4s".count)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                return rest
            }
        }
        return nil
    }

    /// 리스너를 127.0.0.1 임시 포트에 띄우고 준비될 때까지 대기 후 포트 번호를 반환한다.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let box = ContinuationResumeBox(cont)
            // [weak l] — l을 강하게 캡처하면 handler가 l을 붙잡고 l이 handler를 붙잡아
            // 이 리스너가 절대 deinit되지 않는 순환 참조가 생긴다.
            l.stateUpdateHandler = { [weak l] state in
                switch state {
                case .ready:
                    if let port = l?.port?.rawValue {
                        box.resume(.success(port))
                    } else {
                        box.resume(.failure(URLError(.cannotConnectToHost)))
                        l?.cancel()
                        l?.stateUpdateHandler = nil
                    }
                case .failed(let err):
                    box.resume(.failure(err))
                    l?.cancel()
                    l?.stateUpdateHandler = nil
                case .cancelled:
                    l?.stateUpdateHandler = nil
                default:
                    break
                }
            }
            l.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { [weak l] in
                // 타임아웃이 ready와 경쟁에서 이겼을 때만(즉 우리가 실제로 resume시켰을 때만)
                // 리스너를 취소한다 — 진 경우엔 이미 정상적으로 떠 있는 리스너를 건드리면 안 된다.
                if box.resume(.failure(URLError(.timedOut))) {
                    l?.cancel()
                    l?.stateUpdateHandler = nil
                }
            }
        }
    }

    func stop() {
        // self를 강하게 캡처한다 — HLSPlayer.stop()이 relay 프로퍼티를 즉시 nil로 덮어써도
        // (릴레이 인스턴스가 곧바로 deinit되어도) 이 정리 작업은 큐에서 끝까지 실행되어야
        // listener.cancel()이 실제로 호출된다. weak self였다면 deinit 후 guard가 즉시 반환해
        // 리스너가 영원히 살아남아 mTLS 업스트림으로 계속 포워딩하는 리크가 생긴다.
        queue.async {
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel()
            self.listener = nil
            for (_, c) in self.connections { c.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: - 연결/요청 처리 (모두 `queue` 위에서만 실행)

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receiveRequestLine(conn, buffer: Data())
    }

    private func receiveRequestLine(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                var buf = buffer
                if let data { buf.append(data) }
                if let range = buf.range(of: Data([0x0D, 0x0A])) {
                    let line = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                    self.handleRequestLine(line, on: conn)
                    return
                }
                if isComplete || error != nil || buf.count > 8192 {
                    self.respond(conn, status: 400, contentType: nil, body: nil)
                    return
                }
                self.receiveRequestLine(conn, buffer: buf)
            }
        }
    }

    private func handleRequestLine(_ line: String, on conn: NWConnection) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(conn, status: 404, contentType: nil, body: nil)
            return
        }
        let path = String(parts[1])
        let prefix = "/\(token)/audio/hls/"
        guard path.hasPrefix(prefix) else {
            respond(conn, status: 404, contentType: nil, body: nil)
            return
        }
        let rest = String(path.dropFirst(prefix.count))
        // 방어적 차단 — 인코딩된 문자·쿼리·프래그먼트·상위 디렉터리 이동 시도는 화이트리스트
        // 검사 이전에 거른다 (URLSession이 ".."를 그대로 업스트림에 전달하는 것을 확인함).
        guard !rest.contains("%"), !rest.contains("?"), !rest.contains("#"), !rest.contains("..") else {
            respond(conn, status: 404, contentType: nil, body: nil)
            return
        }
        // 존재하는 리소스는 정확히 세 가지 형태뿐 — 화이트리스트로 매칭된 이름만 사용하고,
        // 클라이언트가 보낸 원본 경로 문자열은 업스트림 URL 조립에 절대 쓰지 않는다.
        guard let matchedName = Self.allowlistedResourceName(rest) else {
            respond(conn, status: 404, contentType: nil, body: nil)
            return
        }
        guard let url = URL(string: "https://\(upstreamHost):8443/audio/hls/\(matchedName)") else {
            respond(conn, status: 404, contentType: nil, body: nil)
            return
        }
        let session = self.session
        Task { [weak self] in
            do {
                var r = URLRequest(url: url)
                r.timeoutInterval = 5
                let (data, resp) = try await session.data(for: r)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")
                self?.queue.async {
                    self?.respond(conn, status: 200, contentType: contentType, body: data)
                }
            } catch {
                self?.queue.async {
                    self?.respond(conn, status: 502, contentType: nil, body: nil)
                }
            }
        }
    }

    /// 반드시 `queue` 위에서 호출한다.
    private func respond(_ conn: NWConnection, status: Int, contentType: String?, body: Data?) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Bad Gateway"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Connection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        let id = ObjectIdentifier(conn)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            conn.cancel()
            self?.queue.async { self?.connections.removeValue(forKey: id) }
        })
    }
}

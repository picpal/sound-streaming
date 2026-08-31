import AVFAudio
import Foundation
import MediaPlayer
import YoutumuKit

enum RemoteCommand { case play, pause, next, previous }

final class StreamPlayer: NSObject, URLSessionDataDelegate {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let decoder = AACDecoder()
    private let parser = EnvelopeParser()
    private let tlsDelegate = PinnedSessionDelegate()
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var bufferedFrames: AVAudioFrameCount = 0
    private var started = false
    private let preBufferFrames: AVAudioFrameCount = 48_000     // 1초 (spec §6 지연 모델)
    var onMarker: ((Marker) -> Void)?
    var onEnded: ((String) -> Void)?
    var onRemoteCommand: ((RemoteCommand) -> Void)?
    var onStreaming: (() -> Void)?    // 첫 오디오 프레임 재생 시작 — 실제 연결 성립 신호
    /// Crown 볼륨 (§18·§22 — Watch 로컬 출력, 서버 상태 아님)
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }
    /// 스트림 연결 시도 이후 stop 전이면 true — `task`는 stop()·연결 종료 시 nil로 정리된다 (§22 AudioStreamState 참고용)
    var isConnected: Bool { task != nil }
    private var remoteCommandsRegistered = false
    private(set) var bytesReceived: Int = 0
    private(set) var startedAt: Date?
    func stats() -> (seconds: Int, mb: Double) {
        (Int(-(startedAt?.timeIntervalSinceNow ?? 0)), Double(bytesReceived) / 1_048_576)
    }

    override init() {
        super.init()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: decoder.outFormat)
        parser.onAudio = { [weak self] frame in self?.handleAudio(frame) }
        parser.onMarker = { [weak self] m in
            if m.cause == .command { self?.flush() }             // command만 flush (spec §6)
            self?.onMarker?(m)
        }
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        // 라우트 전환(AirPods 연결 등) 시 엔진이 정지된다 — 복구하지 않으면 첫 재생이 무음 (T9 실측)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: nil) { [weak self] _ in
            guard let self, self.task != nil else { return }   // 스트림 사용 중일 때만
            if !self.engine.isRunning {
                try? self.engine.start()
                if self.started { self.node.play() }
            }
        }
    }

    func start(url: URL) async throws {
        bytesReceived = 0
        startedAt = Date()
        let av = AVAudioSession.sharedInstance()
        #if os(watchOS)
        try av.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try await av.activate()                                  // 출력 라우트 선택 UI (AirPods)
        #else
        // iOS: .longFormAudio route sharing policy requires an AirPlay entitlement path;
        // keep it simple with the default policy. AVAudioSession.activate() async is
        // watchOS-oriented here — use the synchronous setActive(_:) on iOS instead.
        try av.setCategory(.playback)
        try av.setActive(true)
        #endif
        try engine.start()
        // Now Playing 세션 등록 — frontmost를 잃어도(손바닥 덮기, 2분 timeout) suspend되지 않으려면
        // 시스템이 이 앱을 "재생 중인 오디오 앱"으로 인식해야 한다. WKBackgroundModes: audio만으로는 부족.
        registerRemoteCommands()
        updateNowPlaying(title: "Youtumu", artist: "")
        task?.cancel()                                           // 이전 연결 정리 (취소 오류는 아래에서 필터됨)
        task = session.dataTask(with: url)
        task?.resume()
    }

    private func registerRemoteCommands() {
        guard !remoteCommandsRegistered else { return }
        remoteCommandsRegistered = true
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.onRemoteCommand?(.play); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.onRemoteCommand?(.pause); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.onRemoteCommand?(.next); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.onRemoteCommand?(.previous); return .success }
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

    func stop() {
        task?.cancel()
        task = nil
        parser.reset()
        flush()                                              // 남은 부분 envelope/버퍼 정리 — 다음 start()에 새로 시작
        node.stop()
        engine.stop()
    }

    private func handleAudio(_ adtsFrame: Data) {
        guard let pcm = decoder.decode(adtsFrame: adtsFrame) else { return }
        node.scheduleBuffer(pcm, completionHandler: nil)
        bufferedFrames += pcm.frameLength
        if !started && bufferedFrames >= preBufferFrames {       // 1초 pre-buffer 후 재생
            node.play(); started = true
            onStreaming?()
        }
    }

    private func flush() {
        node.stop()                                              // 스케줄된 버퍼 폐기
        decoder.reset()
        bufferedFrames = 0
        started = false                                          // 다시 pre-buffer부터
    }

    // MARK: URLSessionDataDelegate
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }                  // 교체된 이전 태스크의 잔여 데이터 무시
        bytesReceived += data.count
        parser.feed(data)
    }
    func urlSession(_ s: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        tlsDelegate.urlSession(s, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }                 // 이전 연결의 뒤늦은 종료가 현재 스트림 상태를 깨지 않게
        self.task = nil                                          // 연결 종료 → isConnected false
        // PoC: 재접속은 수동 (Play 버튼 재탭 = live edge 복귀). 자동 재접속은 Phase 6
        parser.reset(); flush()
        if let e = error as NSError?, e.code == NSURLErrorCancelled { return }   // Stop 버튼에 의한 정상 취소
        onEnded?(error.map { ($0 as NSError).domain + " \(($0 as NSError).code): " + $0.localizedDescription } ?? "stream closed")
    }
}

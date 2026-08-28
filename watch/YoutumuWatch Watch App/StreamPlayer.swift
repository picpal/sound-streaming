import AVFAudio
import Foundation
import YoutumuKit

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
    }

    func start(url: URL) async throws {
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
        task = session.dataTask(with: url)
        task?.resume()
    }

    func stop() { task?.cancel(); node.stop(); engine.stop() }

    private func handleAudio(_ adtsFrame: Data) {
        guard let pcm = decoder.decode(adtsFrame: adtsFrame) else { return }
        node.scheduleBuffer(pcm, completionHandler: nil)
        bufferedFrames += pcm.frameLength
        if !started && bufferedFrames >= preBufferFrames {       // 1초 pre-buffer 후 재생
            node.play(); started = true
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
        parser.feed(data)
    }
    func urlSession(_ s: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        tlsDelegate.urlSession(s, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // PoC: 재접속은 수동 (Play 버튼 재탭 = live edge 복귀). 자동 재접속은 Phase 6
        parser.reset(); flush()
        if let e = error as NSError?, e.code == NSURLErrorCancelled { return }   // Stop 버튼에 의한 정상 취소
        onEnded?(error.map { ($0 as NSError).domain + " \(($0 as NSError).code): " + $0.localizedDescription } ?? "stream closed")
    }
}

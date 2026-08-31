import Foundation
import AVFoundation
import YoutumuKit
import MacAgentCore

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "capture-wav":
    let seconds = args.count > 2 ? Int(args[2]) ?? 10 : 10
    let sem = DispatchSemaphore(value: 0)
    Task {
        let cap = ChromeAudioCapture()
        var file: AVAudioFile?
        cap.onPCM = { pcm in
            if file == nil {
                file = try? AVAudioFile(forWriting: URL(fileURLWithPath: "/tmp/capture.wav"),
                                        settings: pcm.format.settings)
            }
            try? file?.write(from: pcm)
        }
        try await cap.start()
        print("capturing \(seconds)s... (Chrome에서 소리 재생 중이어야 함)")
        try await Task.sleep(for: .seconds(seconds))
        await cap.stop()
        sem.signal()
    }
    sem.wait()
    print("saved /tmp/capture.wav")
case "record-aac":
    let seconds = args.count > 2 ? Int(args[2]) ?? 10 : 10
    let sem = DispatchSemaphore(value: 0)
    Task {
        let cap = ChromeAudioCapture()
        var enc: AACEncoder?
        FileManager.default.createFile(atPath: "/tmp/capture.aac", contents: nil)
        let fh = FileHandle(forWritingAtPath: "/tmp/capture.aac")!
        cap.onPCM = { pcm in
            if enc == nil { enc = AACEncoder(inputFormat: pcm.format) }
            for frame in enc?.encode(pcm) ?? [] { fh.write(frame) }
        }
        try await cap.start()
        try await Task.sleep(for: .seconds(seconds))
        await cap.stop(); try? fh.close(); sem.signal()
    }
    sem.wait()
    print("saved /tmp/capture.aac")
case "serve":
    let server = StreamServer(port: 8080)
    let cap = ChromeAudioCapture()
    let watchdog = CaptureWatchdog()
    var enc: AACEncoder?
    cap.onPCM = { pcm in
        watchdog.notePCM()
        if enc == nil { enc = AACEncoder(inputFormat: pcm.format) }
        for frame in enc?.encode(pcm) ?? [] {
            server.broadcast(Envelope.encode(type: .audio, payload: frame))
        }
    }
    let hls = HLSSegmenter()
    server.hls = hls
    cap.onSampleBuffer = { sb in hls.append(sb) }
    // SCStream 무증상 사망 자동 복구 — 수신자가 듣고 있는데 PCM이 끊기면 재시작
    watchdog.start(hasReceiver: { server.hasReceiver() },
                   restart: {
                       BrowserRecovery.wakeDisplay()
                       hls.stop()
                       await cap.stop()
                       do { try await cap.start() } catch { print("CaptureWatchdog: 재시작 실패 \(error)") }
                   })
    let cdp = CDPClient()
    let controller = BrowserController(cdp: cdp)
    let svc = PlayerStateService()
    server.api = ControlAPI(store: CommandStore(), svc: svc, controller: controller,
                             library: controller, cache: MetadataCache(), artwork: ArtworkService(),
                             recovery: {
                                 await BrowserRecovery.recover(browserHealthy: svc.browserHealthy())
                                 // SCK 캡처 필터는 캡처 시작 시점의 Chrome 프로세스에 고정된다 —
                                 // Chrome 재기동 후엔 재생 중이어도 무음 프레임만 나온다 (실측 확인).
                                 // Chrome 기동을 기다렸다가 캡처를 재바인딩 (HTTP 응답은 지연시키지 않는다).
                                 Task {
                                     try? await Task.sleep(for: .seconds(6))
                                     BrowserRecovery.wakeDisplay()
                                     hls.stop()
                                     await cap.stop()
                                     do { try await cap.start(); print("BrowserRecovery: 오디오 캡처 재시작") }
                                     catch { print("BrowserRecovery: 캡처 재시작 실패 \(error)") }
                                 }
                             })
    svc.onTrackChange = { m in
        server.broadcast(Envelope.encodeMarker(m))    // 실제 곡 전환 → 스트림 MARKER (spec §6)
        print("MARKER seq=\(m.seq) cause=\(m.cause.rawValue) track=\(m.trackId)")
    }
    Task {
        try await cap.start()
        try? await cdp.connect()                      // Chrome 미기동이면 폴링 루프가 재시도
        svc.startPolling(controller: controller)
        // NOTE: brief의 print에 `try? await` 문자열 보간이 있어 컴파일이 안 되어 로컬 변수로 분리(동작 동일)
        let cdpConnected = (try? await controller.snapshot()) != nil
        print("streaming + control API ready (CDP \(cdpConnected ? "connected" : "retrying"))")
    }
    try server.run()
case "enroll":
    guard args.count > 2 else {
        print("usage: MacAgent enroll <code>")
        exit(1)
    }
    try EnrollServer(code: args[2]).run()
default:
    print("usage: MacAgent capture-wav <sec> | record-aac <sec> | serve | enroll <code>")
    exit(1)
}

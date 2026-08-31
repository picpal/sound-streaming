# Phase 6: HLS 백그라운드 오디오 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Watch가 크라운으로 앱을 떠나도 재생이 계속되도록 오디오 전송을 HLS 라이브 + AVPlayer(시스템 관리 재생)로 교체하고, end-to-end 지연 2–3초를 달성한다.

**Architecture:** Mac Agent가 SCK 캡처의 CMSampleBuffer를 AVAssetWriter(`.mpeg4AppleHLS`, 1초 세그먼트)에 넣어 fMP4 세그먼트·라이브 m3u8을 메모리에서 서빙한다. Watch는 커스텀 스킴 AVURLAsset + AVAssetResourceLoaderDelegate로 기존 mTLS(PinnedSessionDelegate) 세션을 통해 플레이리스트/세그먼트를 가져와 AVPlayer로 재생한다 — 앱이 서스펜드돼도 시스템 미디어 데몬이 재생을 지속한다. 지연은 1초 세그먼트 + `EXT-X-START:TIME-OFFSET=-2.0`으로 2–3초에 고정한다.

**Tech Stack:** AVAssetWriter fragmented-MP4 delegate API(macOS 11+), SwiftNIO(StreamServer), AVPlayer + AVAssetResourceLoaderDelegate(watchOS), 기존 Caddy mTLS(변경 없음 — catch-all `reverse_proxy 127.0.0.1:8080`이 `/audio/hls/*`를 커버).

**Spec:** `apple_watch_youtube_music_remote_player_design.md` §6(지연 모델)·§22(AudioStreamState).
**스펙 편차(승인 근거):** 스펙의 커스텀 envelope 스트림은 watchOS에서 백그라운드 재생 불가가 실기기 진단으로 확정됨(T9 렛저 2026-08-31: 세션 정상(playback/longFormAudio/BT)에도 크라운 이탈 즉시 프로세스 서스펜드 — watchOS는 AVPlayer/AVAudioPlayer의 시스템 관리 재생만 백그라운드 허용). 본 계획은 §6의 "지연 ~1s"를 "2–3s"로 개정하고 전송 계층을 교체한다. 제어 평면(§5·§21)은 불변.

## Global Constraints

- CA 개인키(`scripts/ca/out/`)는 커밋·로그 금지. DuckDNS 토큰은 `~/.youtumu-duckdns`(chmod 600)에만.
- Enrollment 8444는 LAN 전용(포트포워딩 금지). Agent(8080)·CDP(9222)는 127.0.0.1 바인드만.
- 클라이언트 개인키는 Secure Enclave 비추출(시뮬레이터 fallback 유지). JS 스니펫은 Agent 고정 문자열만 — Watch는 URL/JS를 전송하지 않는다.
- trackId/playlistId/artwork id는 ControlAPI 경계에서 `^[A-Za-z0-9_-]{1,64}$` 검증(`try! Regex(#"..."#)`).
- watchOS deploymentTarget 9.0, SWIFT_VERSION 6.0. watch 신규 파일은 `cd watch && xcodegen generate` 필요(양 타깃 공유 소스 — iOS 쪽은 `#if os(watchOS)` 가드).
- serve는 사용자의 Terminal.app에서 실행(TCC), 시작 전 디스플레이 깨어 있어야 함(`caffeinate -u -t 3`).
- **지연 목표: Mac 소리 → Watch 소리 2–3초.** 고정값: 세그먼트 1.0초, 라이브 윈도우 8개, `EXT-X-START:TIME-OFFSET=-2.0,PRECISE=YES`, Watch `preferredForwardBufferDuration = 1`.
- HLS 경로는 인증 로직 추가 없음 — Caddy mTLS(8443)가 전 경로를 이미 보호한다. Agent는 127.0.0.1:8080 평문 그대로.
- 기존 `/audio/live` envelope 경로는 **서버에서 유지**(curl 진단·롤백용). Watch만 HLS로 전환한다.

---

### Task 1: HLSSegmenter (MacAgentCore)

**Files:**
- Create: `MacAgent/Sources/MacAgentCore/HLSSegmenter.swift`
- Test: `MacAgent/Tests/MacAgentTests/HLSSegmenterTests.swift`

**Interfaces:**
- Consumes: 없음 (신규 리프 모듈).
- Produces (Task 2·3이 사용):
  - `public final class HLSSegmenter: NSObject, AVAssetWriterDelegate`
  - `public func append(_ sb: CMSampleBuffer)` — SCK 오디오 CMSampleBuffer(PCM) 투입. 내부에서 AVAssetWriter가 AAC 인코딩.
  - `public func playlist() -> String?` — 현재 라이브 m3u8 (init 세그먼트 수신 전엔 nil).
  - `public func initSegment() -> Data?`
  - `public func segment(seq: UInt64) -> Data?` — 윈도우 밖이면 nil.
  - `public func stop()` — writer 종료·상태 리셋(재시작 가능: 다음 append가 새 writer 생성).
  - `public var onSegment: (() -> Void)?` — 세그먼트 산출 알림(리스너 추적·테스트용).

- [ ] **Step 1: 실패하는 테스트 작성**

테스트 헬퍼: 48kHz 스테레오 PCM CMSampleBuffer 생성(무음이어도 인코딩엔 충분).

```swift
import XCTest
import AVFoundation
@testable import MacAgentCore

final class HLSSegmenterTests: XCTestCase {
    /// 48kHz 스테레오 float PCM CMSampleBuffer (frames 프레임, pts초 시작)
    private func pcmSample(frames: Int, pts: Double) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fmt)
        let byteCount = frames * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: byteCount, flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: fmt!,
            sampleCount: frames, presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sb)
        return sb!
    }

    /// 4초 분량 투입 → init + 미디어 세그먼트 ≥3, 플레이리스트 형식 검증
    func testProducesSegmentsAndPlaylist() {
        let seg = HLSSegmenter()
        let exp = expectation(description: "segments")
        exp.expectedFulfillmentCount = 3
        exp.assertForOverFulfill = false
        seg.onSegment = { exp.fulfill() }
        // 0.1초(4800프레임) 단위로 4초 투입 — 실시간 아님, writer는 PTS 기준으로 세그먼트를 자른다
        for i in 0..<40 { seg.append(pcmSample(frames: 4_800, pts: Double(i) * 0.1)) }
        wait(for: [exp], timeout: 10)

        XCTAssertNotNil(seg.initSegment())
        let pl = try! XCTUnwrap(seg.playlist())
        XCTAssertTrue(pl.contains("#EXT-X-VERSION:7"))
        XCTAssertTrue(pl.contains("#EXT-X-TARGETDURATION:1"))
        XCTAssertTrue(pl.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(pl.contains("#EXT-X-START:TIME-OFFSET=-2.0,PRECISE=YES"))
        XCTAssertTrue(pl.contains("seg0.m4s"))
        XCTAssertFalse(pl.contains("#EXT-X-ENDLIST"))       // 라이브
        XCTAssertNotNil(seg.segment(seq: 0))
    }

    /// 윈도우(8개) 초과 시 오래된 세그먼트 퇴출 + MEDIA-SEQUENCE 전진
    func testWindowEviction() {
        let seg = HLSSegmenter()
        let exp = expectation(description: "many segments")
        exp.expectedFulfillmentCount = 11
        exp.assertForOverFulfill = false
        seg.onSegment = { exp.fulfill() }
        for i in 0..<130 { seg.append(pcmSample(frames: 4_800, pts: Double(i) * 0.1)) }   // 13초
        wait(for: [exp], timeout: 15)

        XCTAssertNil(seg.segment(seq: 0))                    // 퇴출됨
        let pl = try! XCTUnwrap(seg.playlist())
        let seqLine = pl.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }!
        let firstSeq = UInt64(seqLine.split(separator: ":")[1])!
        XCTAssertGreaterThan(firstSeq, 0)
        XCTAssertNotNil(seg.segment(seq: firstSeq))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd MacAgent && swift test --filter HLSSegmenterTests 2>&1 | tail -5`
Expected: 컴파일 실패 (`HLSSegmenter` 미정의)

- [ ] **Step 3: 구현**

```swift
import AVFoundation
import Foundation

/// SCK 오디오 CMSampleBuffer(PCM) → fMP4 HLS 라이브 세그먼트 (메모리 서빙).
/// AVAssetWriter(.mpeg4AppleHLS)가 AAC 인코딩과 세그먼트 분할을 담당한다 (지연 목표: Global Constraints).
public final class HLSSegmenter: NSObject, AVAssetWriterDelegate {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var initData: Data?
    private var segments: [(seq: UInt64, data: Data, duration: Double)] = []
    private var nextSeq: UInt64 = 0
    static let window = 8                                    // 라이브 윈도우 (Global Constraints)
    public var onSegment: (() -> Void)?

    /// writer 생성은 첫 샘플에서 — sourceFormatHint와 initialSegmentStartTime에 실제 값이 필요
    public func append(_ sb: CMSampleBuffer) {
        if writer == nil { startWriter(firstSample: sb) }
        guard let input, input.isReadyForMoreMediaData else { return }   // 실시간 인코딩이 밀리면 드랍 (라이브)
        input.append(sb)
    }

    private func startWriter(firstSample: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(firstSample) else { return }
        let w = try! AVAssetWriter(contentType: .mpeg4Movie)
        w.outputFileTypeProfile = .mpeg4AppleHLS
        w.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        w.initialSegmentStartTime = CMSampleBufferGetPresentationTimeStamp(firstSample)
        w.delegate = self
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: desc)
        inp.expectsMediaDataInRealTime = true
        w.add(inp)
        w.startWriting()
        w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(firstSample))
        writer = w; input = inp
    }

    public func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                            segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock()
        switch segmentType {
        case .initialization:
            initData = segmentData
        case .separable:
            let dur = segmentReport?.trackReports.first?.duration.seconds ?? 1.0
            segments.append((nextSeq, segmentData, dur))
            nextSeq += 1
            if segments.count > Self.window { segments.removeFirst() }
        @unknown default: break
        }
        lock.unlock()
        onSegment?()
    }

    public func playlist() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard initData != nil, let first = segments.first else { return nil }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:1",
            "#EXT-X-MEDIA-SEQUENCE:\(first.seq)",
            "#EXT-X-START:TIME-OFFSET=-2.0,PRECISE=YES",     // 라이브 엣지 -2초에서 시작 (지연 목표)
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for s in segments {
            lines.append(String(format: "#EXTINF:%.5f,", s.duration))
            lines.append("seg\(s.seq).m4s")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func initSegment() -> Data? { lock.lock(); defer { lock.unlock() }; return initData }
    public func segment(seq: UInt64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return segments.first { $0.seq == seq }?.data
    }
    public func stop() {
        input?.markAsFinished()
        writer?.finishWriting {}
        lock.lock(); writer = nil; input = nil; initData = nil; segments = []; nextSeq = 0; lock.unlock()
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd MacAgent && swift test --filter HLSSegmenterTests 2>&1 | grep -E "Executed|error"`
Expected: 2 tests, 0 failures. (AVAssetWriter가 PTS 간격으로 didOutputSegmentData를 부르지 않고 실제 경과에 묶이면 — 즉 비실시간 투입에서 세그먼트가 안 나오면 — 테스트를 `expectsMediaDataInRealTime = false` 경로로 조정하지 말고, 투입 루프에 `usleep(20_000)`을 넣어 준실시간화한다. 그래도 실패하면 BLOCKED 보고.)

- [ ] **Step 5: Commit**

```bash
git add MacAgent/Sources/MacAgentCore/HLSSegmenter.swift MacAgent/Tests/MacAgentTests/HLSSegmenterTests.swift
git commit -m "feat: HLS live segmenter (fMP4, 1s segments, 8-seg window)"
```

---

### Task 2: 캡처 탭 + StreamServer HLS 라우트 + serve 배선

**Files:**
- Modify: `MacAgent/Sources/MacAgentCore/ChromeAudioCapture.swift` (onSampleBuffer 추가)
- Modify: `MacAgent/Sources/MacAgentCore/StreamServer.swift` (HLS 라우트 + HLS 리스너 추적)
- Modify: `MacAgent/Sources/MacAgent/main.swift` (segmenter 배선 + watchdog 게이트 갱신)

**Interfaces:**
- Consumes: Task 1의 `HLSSegmenter` 전체 API.
- Produces:
  - `ChromeAudioCapture.onSampleBuffer: ((CMSampleBuffer) -> Void)?` — PCM 변환 전 원본 탭.
  - `StreamServer.hls: HLSSegmenter?` — 핸들러가 조회.
  - `StreamServer.hasReceiver()` 의미 확장: envelope 수신자 활성 **또는** 최근 10초 내 HLS 플레이리스트 요청.
  - HTTP: `GET /audio/hls/live.m3u8`(`application/vnd.apple.mpegurl`), `GET /audio/hls/init.mp4`(`video/mp4`), `GET /audio/hls/seg{n}.m4s`(`video/iso.segment`). 미준비/윈도우 밖은 404.

- [ ] **Step 1: ChromeAudioCapture 탭 추가**

`stream(_:didOutputSampleBuffer:of:)` 진입부(기존 guard 위)에:

```swift
    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?   // HLS 세그먼터용 원본 탭
```

기존 메서드 첫 줄에 `onSampleBuffer?(sb)` 추가 (audio 타입 guard 뒤, PCM 변환 앞).
주의: 기존 guard가 `type == .audio` 확인을 포함하면 그 뒤에, 아니면 `guard type == .audio else { return }`를 먼저 확인하고 배치.

- [ ] **Step 2: StreamServer HLS 라우트**

`StreamServer`에 프로퍼티·리스너 추적 추가:

```swift
    public var hls: HLSSegmenter?
    private var lastHLSRequest: Date? = nil
```

`hasReceiver()`를 다음으로 교체:

```swift
    /// 캡처 워치독용 — envelope 수신자 활성 또는 최근 10초 내 HLS 플레이리스트 요청
    public func hasReceiver() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if receiver?.isActive == true { return true }
        if let t = lastHLSRequest, Date().timeIntervalSince(t) < 10 { return true }
        return false
    }
    fileprivate func noteHLSRequest() { lock.lock(); lastHLSRequest = Date(); lock.unlock() }
```

`Handler.channelRead`의 `.head` 케이스, `/audio/live` 분기 **앞**에:

```swift
                if h.method == .GET, h.uri.hasPrefix("/audio/hls/") {
                    let name = String(h.uri.dropFirst("/audio/hls/".count))
                    var body: Data?
                    var ct = "application/octet-stream"
                    switch name {
                    case "live.m3u8":
                        server.noteHLSRequest()
                        body = server.hls?.playlist().map { Data($0.utf8) }
                        ct = "application/vnd.apple.mpegurl"
                    case "init.mp4":
                        body = server.hls?.initSegment()
                        ct = "video/mp4"
                    default:
                        if name.hasPrefix("seg"), name.hasSuffix(".m4s"),
                           let seq = UInt64(name.dropFirst(3).dropLast(4)) {
                            body = server.hls?.segment(seq: seq)
                            ct = "video/iso.segment"
                        }
                    }
                    if let body {
                        writeJSON(context.channel, status: .ok, body: body, contentType: ct)
                    } else {
                        writeJSON(context.channel, status: .notFound, body: Data(#"{"error":"not ready"}"#.utf8))
                    }
                    head = nil
                    return
                }
```

(`writeJSON`은 이름과 달리 contentType 인자를 받는 범용 write 헬퍼 — 기존 시그니처 확인 후 그대로 사용. Cache-Control 불필요: 플레이리스트는 매 요청 재생성이고 AVPlayer는 라이브 m3u8을 조건 없이 재요청한다.)

- [ ] **Step 3: main.swift serve 배선**

`case "serve":` 블록에서 `cap.onPCM` 정의 근처에:

```swift
    let hls = HLSSegmenter()
    server.hls = hls
    cap.onSampleBuffer = { sb in hls.append(sb) }
```

캡처 재시작 지점 2곳(BrowserRecovery Task, CaptureWatchdog restart 클로저)의 `await cap.stop()` 앞에 `hls.stop()` 추가 — writer를 리셋해 재시작 후 PTS 불연속으로 세그먼트가 멈추지 않게 한다.

- [ ] **Step 4: 빌드·기존 테스트**

Run: `cd MacAgent && swift build 2>&1 | tail -1 && swift test 2>&1 | grep -E "Executed.*failures" | tail -1`
Expected: Build complete, 기존+신규 전체 0 failures

- [ ] **Step 5: 라이브 확인 (serve 재기동 — 사용자 Terminal, 디스플레이 웨이크 선행)**

```bash
caffeinate -u -t 3; pkill -f "MacAgent serve"; sleep 1; osascript -e 'tell application "Terminal" to do script "cd /Users/picpal/Desktop/workspace/youtumu-player/MacAgent; swift run MacAgent serve"'
```

YT Music 재생 중 상태에서 (O=scripts/ca/out):

```bash
curl -sk --cert $O/test-client.crt --key $O/test-client.key --resolve youtumu.duckdns.org:8443:127.0.0.1 https://youtumu.duckdns.org:8443/audio/hls/live.m3u8
```

Expected: m3u8 텍스트(EXTINF ~1.0 항목들). 5초 후 재요청 시 MEDIA-SEQUENCE 전진. `init.mp4`·최신 `seg{n}.m4s`가 200 + 바이트 >0.
검증 보너스: `ffprobe`(있으면) 또는 Mac에서 `curl … seg{n}.m4s -o /tmp/s.m4s && open /tmp/s.m4s` 대신 **Safari로 `https://youtumu.duckdns.org:8443/audio/hls/live.m3u8` 열기(클라이언트 인증서 없어 실패해야 정상 — mTLS 확인)**.

- [ ] **Step 6: Commit**

```bash
git add MacAgent
git commit -m "feat: serve HLS live playlist/segments from StreamServer"
```

---

### Task 3: Watch HLSPlayer (AVPlayer + mTLS ResourceLoader)

**Files:**
- Create: `watch/YoutumuWatch Watch App/HLSPlayer.swift`
- Modify: 없음 (PlayerModel 전환은 Task 4)
- 신규 파일이므로: `cd watch && xcodegen generate`

**Interfaces:**
- Consumes: `PinnedSessionDelegate` (`watch/YoutumuWatch Watch App/EnrollClient.swift` — mTLS 서버 핀닝+클라이언트 identity), `RemoteCommand` enum(현 StreamPlayer.swift 정의 — Task 5에서 이 파일로 이동하기 전까지 중복 정의 금지: HLSPlayer는 기존 enum을 그대로 사용).
- Produces (Task 4가 사용 — StreamPlayer와 동일한 표면):
  - `final class HLSPlayer: NSObject` —
    `var onStreaming: (() -> Void)?` (재생 실제 시작), `var onEnded: ((String) -> Void)?`,
    `var onRemoteCommand: ((RemoteCommand) -> Void)?`, `var volume: Float`,
    `func start(host: String) async throws`, `func stop()`,
    `func updateNowPlaying(title: String, artist: String)`, `func seekToLiveEdge()`.

- [ ] **Step 1: 구현**

```swift
import AVFoundation
import Foundation
import MediaPlayer

/// HLS 라이브 + AVPlayer — 시스템 관리 재생이라 앱 서스펜드에도 지속 (Phase 6 핵심).
/// mTLS는 AVPlayer가 직접 못 하므로 커스텀 스킴 + ResourceLoader로 PinnedSessionDelegate 세션을 경유한다.
final class HLSPlayer: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "ytmuhls"                            // https로 재작성됨
    private let tlsDelegate = PinnedSessionDelegate()
    private lazy var session = URLSession(configuration: .default, delegate: tlsDelegate, delegateQueue: nil)
    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var timeObs: NSKeyValueObservation?
    private var statusObs: NSKeyValueObservation?
    private var remoteCommandsRegistered = false
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

        let url = URL(string: "\(Self.scheme)://\(host):8443/audio/hls/live.m3u8")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "hls.loader"))
        let it = AVPlayerItem(asset: asset)
        it.preferredForwardBufferDuration = 1                // 지연 목표 (Global Constraints)
        let p = AVPlayer(playerItem: it)

        statusObs = it.observe(\.status) { [weak self] item, _ in
            if item.status == .failed {
                self?.onEnded?(item.error.map { "\($0)" } ?? "item failed")
            }
        }
        timeObs = p.observe(\.timeControlStatus) { [weak self] player, _ in
            if player.timeControlStatus == .playing { self?.onStreaming?() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(stalled),
                                               name: .AVPlayerItemPlaybackStalled, object: it)
        player = p; item = it
        p.play()
    }

    @objc private func stalled() {
        // 라이브 윈도우 이탈 등 — 라이브 엣지로 복귀 시도, 실패는 status 옵저버가 잡는다
        seekToLiveEdge()
        player?.play()
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

    // MARK: AVAssetResourceLoaderDelegate — ytmuhls:// → https:// 를 mTLS 세션으로 대리 요청
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard var comps = req.request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              comps.scheme == Self.scheme else { return false }
        comps.scheme = "https"
        let target = comps.url!
        Task {
            do {
                var r = URLRequest(url: target)
                r.timeoutInterval = 5
                let (data, resp) = try await session.data(for: r)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                if let info = req.contentInformationRequest {
                    info.contentType = http.value(forHTTPHeaderField: "Content-Type")
                    info.contentLength = Int64(data.count)
                    info.isByteRangeAccessSupported = false
                }
                req.dataRequest?.respond(with: data)
                req.finishLoading()
            } catch {
                req.finishLoading(with: error)
            }
        }
        return true
    }
}
```

- [ ] **Step 2: xcodegen + 양 타깃 빌드**

```bash
cd watch && xcodegen generate
xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "platform=watchOS Simulator,name=Apple Watch Series 11 (42mm)" build 2>&1 | tail -2
```

Expected: BUILD SUCCEEDED (iOS 타깃도 같은 소스라 컴파일됨 — `#if os(watchOS)`는 세션 활성화 분기만).

- [ ] **Step 3: Commit**

```bash
git add watch
git commit -m "feat: HLSPlayer — AVPlayer live HLS with mTLS resource loader"
```

---

### Task 4: PlayerModel 전환 + 명령 직후 라이브 엣지 점프

**Files:**
- Modify: `watch/YoutumuWatch Watch App/PlayerModel.swift`

**Interfaces:**
- Consumes: Task 3 `HLSPlayer` 전체 표면.
- Produces: `PlayerModel.player: HLSPlayer` (뷰가 쓰는 표면 유지 — `player.volume`, `player.updateNowPlaying`). 나머지 공개 API 불변(뷰 수정 없음).

- [ ] **Step 1: 교체**

`PlayerModel.swift`에서:

1. `let player = StreamPlayer()` → `let player = HLSPlayer()`
2. `init()`의 콜백 배선은 그대로 (onStreaming/onEnded/onRemoteCommand 이름 동일). `player.onMarker` 배선이 있으면 삭제 — HLSPlayer에 없음.
3. `ensureStream()`의 `try await player.start(url: URL(string: "https://\(host):8443/audio/live")!)` →
   `try await player.start(host: host)`
4. 명령 직후 이전 곡 소리 구간 단축 — `send(_:)` 성공 경로와 `playTrack`/`playPlaylist`/`jumpQueue` 성공 경로에서 트랙 전환 명령일 때:

```swift
    /// 트랙 전환 명령 성공 후: 새 곡 오디오가 세그먼트로 나올 시간을 준 뒤 라이브 엣지로 점프
    private func nudgeToLiveEdgeSoon() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            player.seekToLiveEdge()
        }
    }
```

호출 지점: `next()`·`previous()`의 `send(...)` 다음 줄, `playTrack`·`playPlaylist`·`jumpQueue`의 성공 분기(`_ = try await ...` 다음). play/pause에는 넣지 않는다(전환 아님).

- [ ] **Step 2: 시뮬레이터 검증**

```bash
cd watch && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "platform=watchOS Simulator,name=Apple Watch Series 11 (42mm)" build 2>&1 | tail -1
xcrun simctl install booted "/Users/picpal/Library/Developer/Xcode/DerivedData/YoutumuWatch-bgamrzqmrusovgfxehwgbtzhdykz/Build/Products/Debug-watchsimulator/YoutumuWatch Watch App.app"
xcrun simctl launch booted com.picpal.YoutumuWatch
```

serve 가동 상태에서 트랙 탭 → NowPlaying 블러 해제(= onStreaming 도달, HLS 경로 성립)까지 확인. **소리 자체는 시뮬레이터에서도 나와야 한다** (Mac 스피커).

- [ ] **Step 3: Commit**

```bash
git add watch
git commit -m "feat: switch watch playback to HLS player + live-edge nudge after track commands"
```

---

### Task 5: 구 스트림 경로 정리 (Watch)

**Files:**
- Delete: `watch/YoutumuWatch Watch App/StreamPlayer.swift`, `watch/YoutumuWatch Watch App/AACDecoder.swift`
- Modify: `watch/YoutumuWatch Watch App/HLSPlayer.swift` (RemoteCommand enum 이동)
- 파일 삭제이므로: `cd watch && xcodegen generate`

**Interfaces:**
- Consumes: Task 4 완료 상태(어떤 코드도 StreamPlayer를 참조하지 않아야 함).
- Produces: `enum RemoteCommand { case play, pause, next, previous }` 가 HLSPlayer.swift 상단으로 이동.

- [ ] **Step 1: RemoteCommand 이동 후 삭제**

StreamPlayer.swift 상단의 `enum RemoteCommand ...` 한 줄을 HLSPlayer.swift의 import 아래로 옮기고, 두 파일 삭제:

```bash
rm "watch/YoutumuWatch Watch App/StreamPlayer.swift" "watch/YoutumuWatch Watch App/AACDecoder.swift"
cd watch && xcodegen generate
```

주의: `EnvelopeParser`는 YoutumuKit 소속(Mac Agent 테스트가 사용)이므로 **삭제하지 않는다**. Watch가 참조하지 않게만 된다.

- [ ] **Step 2: 양 타깃 빌드 + 잔존 참조 검색**

```bash
grep -rn "StreamPlayer\|AACDecoder\|EnvelopeParser" "watch/YoutumuWatch Watch App/" ; echo "exit $?"
cd watch && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build 2>&1 | tail -1
```

Expected: grep 무결과(exit 1), BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add -A watch
git commit -m "chore: remove legacy envelope stream player from watch"
```

---

### Task 6: 실기기 체크포인트 — 백그라운드 재생 + 지연 실측 (사용자 협조)

**Files:** 없음 (검증 태스크). 결과는 렛저와 `docs/poc-results.md`에 기록.

**Interfaces:**
- Consumes: Task 1–5 전부 + serve 재기동(신 바이너리) + Watch 설치.

- [ ] **Step 1: 배포**

```bash
caffeinate -u -t 3; pkill -f "MacAgent serve"; sleep 1; osascript -e 'tell application "Terminal" to do script "cd /Users/picpal/Desktop/workspace/youtumu-player/MacAgent; swift run MacAgent serve"'
cd watch && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build
xcrun devicectl device install app --device C9DE6B2F-62EE-57C8-8AF1-045BFB812831 "/Users/picpal/Library/Developer/Xcode/DerivedData/YoutumuWatch-bgamrzqmrusovgfxehwgbtzhdykz/Build/Products/Debug-watchos/YoutumuWatch Watch App.app"
```

- [ ] **Step 2: 사용자 체크리스트 (AirPods 연결 상태)**

1. 재생 시작 → 소리 도달까지 체감 시간 (목표 ≤3s)
2. **크라운으로 시계 화면 이탈 → 재생 지속** (Phase 6 핵심 판정)
3. 백그라운드 1분 후 Now Playing에서 다음 곡 → 동작 여부(서스펜드 앱의 remote command 웨이크)
4. 다음 곡 탭 → 이전 곡 소리 잔류 시간 (nudge 적용, 목표 ≤3s)
5. Mac에서 소리와 Watch 소리 시차 스톱워치 실측 (목표 2–3s)
6. 큐 점프·재생/일시정지·Crown 볼륨 회귀 확인
7. LTE(Wi-Fi 끔) 재생 60초 — 끊김/스톨 관찰

- [ ] **Step 3: 튜닝 판정 (컨트롤러 ruling)**

- 시차 >3s → `EXT-X-START:TIME-OFFSET`을 -1.5로 조정 후 재측정.
- LTE 스톨 → 윈도우 8→12, `preferredForwardBufferDuration` 1→2 (지연과 트레이드).
- remote command 미동작 → 렛저에 기록하고 Phase 7 백로그(제어 불가는 수용, 재생 지속이 우선 가치).
- 결과 수치를 렛저 + `docs/poc-results.md`에 기록.

- [ ] **Step 4: Commit (문서)**

```bash
git add docs/poc-results.md
git commit -m "docs: Phase 6 HLS background-audio device measurements"
```

---

## 리스크 (실행자 참고)

- **AVAssetWriter 비실시간 테스트**: Task 1 Step 4의 준실시간 fallback 명시 — 그래도 실패 시 BLOCKED 보고(테스트 무력화 금지).
- **ResourceLoader가 세그먼트 요청에 호출되지 않는 경우**(AVPlayer가 상대 URL을 https로 절대화해버리는 회귀): 플레이리스트 응답을 loader에서 반환하기 전에 세그먼트 URI를 `ytmuhls://` 절대 URL로 재작성하는 fallback을 Task 3에 추가한다(문자열 치환: `seg` → `\(Self.scheme)://\(host):8443/audio/hls/seg`, `init.mp4` 동일).
- **AVPlayer.volume watchOS 미지원 판명 시**: Crown 배선은 no-op이 되고 시스템 볼륨(Now Playing 크라운)이 대신한다 — Task 6에서 확인, 렛저 기록.
- **서스펜드 중 Now Playing 메타 동결**: 폴링이 멈추므로 백그라운드 중 곡 전환 시 제목이 낡는다 — 수용(포그라운드 복귀 시 갱신), Task 6 체크리스트에서 확인만.

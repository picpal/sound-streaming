# Phase 0 — Kill-Risk PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **진행 상태 관리:** 모든 태스크는 시작 시 `python3 scripts/update_status.py <task_id> in_progress`, 완료 시 `python3 scripts/update_status.py <task_id> done`을 실행하고 `status.json`을 함께 커밋한다. 실패로 중단하면 `failed`로 기록한다.

**Goal:** 설계 문서의 아키텍처를 폐기시킬 수 있는 가정들(Watch 백그라운드 셀룰러 스트리밍 + Secure Enclave mTLS + Mac Chrome 오디오 캡처)을 실기기에서 하나의 묶음으로 검증한다.

**Architecture:** Mac에서 ScreenCaptureKit으로 Chrome 오디오를 캡처 → AAC-LC 인코딩 → TLV envelope로 감싼 continuous stream을 SwiftNIO HTTP 서버가 제공 → Caddy가 TLS1.3+mTLS 종단 → Watch가 URLSession(SE 기반 SecIdentity)으로 수신해 AVAudioEngine으로 재생. 전부 버릴 각오의 최소 프로토타입.

**Tech Stack:** Swift 단일 (macOS: SwiftPM + SwiftNIO + ScreenCaptureKit + AudioToolbox / watchOS: SwiftUI + Security + AVFAudio), Caddy 2, OpenSSL 3 (CA 스크립트), Python 3 (보조 스크립트).

**Spec:** `apple_watch_youtube_music_remote_player_design.md` — 이 계획은 spec §6(스트림 프로토콜·지연 모델), §10(보안), §23 Phase 0, §24(성공 기준)를 구현·검증한다.

## Global Constraints

- 언어: Swift 단일 (Mac Agent + Watch 앱). 외부 의존성은 SwiftNIO만 허용
- 포트: Agent `127.0.0.1:8080`, Caddy 서비스 `:8443`, Caddy Enrollment `LAN:8444` (WAN 비노출)
- TLS: 1.3 only, mTLS `require_and_verify`, 신뢰 앵커는 자체 CA(`scripts/ca/out/ca.crt`)만
- 오디오: AAC-LC, 48kHz stereo, 96kbps, ADTS 프레이밍
- Envelope wire format (spec §6 그대로): `[ type(1B) | length(2B, big-endian) | payload ]`, type `0x01`=AUDIO, `0x02`=MARKER(JSON `{seq, trackId, cause}`, cause ∈ `command|natural|encoder`)
- 지연 모델: flush/재접속 직후 ~1초 pre-buffer 후 재생 시작
- Watch: **게이트 판정은 Series 7 실기기 필수** (Simulator는 SE·셀룰러·백그라운드 수명주기·AirPods·배터리 검증 불가), 무료 계정 7일 재서명. 단 **개발 루프에서는 watchOS Simulator 사용 가능** — Task 8·9의 로직(enrollment 플로우, mTLS URLSession, 디코더, 플레이어)은 Simulator에서 1차 디버깅 후 실기기로 넘어간다. KeyStore는 `#if targetEnvironment(simulator)`로 SE를 생략한 일반 keychain 키를 쓴다
- PoC 한정 단순화(spec과의 의도된 차이): CSR 대신 raw 공개키 전송(`openssl x509 -force_pubkey`로 발급, PoP 생략), Enrollment TLS는 Caddy :8444 site로 처리, YouTube Music 제어 없음(아무 소리나 재생 중인 Chrome이면 충분)

---

### Task 1: 리포 스캐폴드 + 상태 관리

**Files:**
- Create: `.gitignore`, `scripts/update_status.py`
- Modify: `status.json` (기존 파일 커밋)

**Interfaces:**
- Produces: `scripts/update_status.py <task_id> <pending|in_progress|done|failed>` — 이후 모든 태스크가 사용

- [ ] **Step 1: git init + .gitignore**

```bash
cd /Users/picpal/Desktop/workspace/youtumu-player
git init -b main
cat > .gitignore <<'EOF'
.DS_Store
.build/
*.xcuserdata/
xcuserdata/
scripts/ca/out/
*.wav
*.aac
stream.bin
.context/
EOF
```

`scripts/ca/out/`(CA 개인키 포함)은 절대 커밋하지 않는다 (spec §10.4 금지 목록).

- [ ] **Step 2: update_status.py 작성**

```python
#!/usr/bin/env python3
"""usage: update_status.py <task_id> <pending|in_progress|done|failed> [note]"""
import json, sys, datetime

PATH = "status.json"
tid, st = sys.argv[1], sys.argv[2]
note = sys.argv[3] if len(sys.argv) > 3 else None
assert st in ("pending", "in_progress", "done", "failed"), f"invalid status: {st}"

d = json.load(open(PATH))
hit = False
for t in d["phases"]["phase0"]["tasks"]:
    if str(t["id"]) == tid:
        t["status"] = st
        if note: t["note"] = note
        hit = True
assert hit, f"task {tid} not found"
d["updated"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
running = [t["id"] for t in d["phases"]["phase0"]["tasks"] if t["status"] == "in_progress"]
d["current"]["task"] = running[0] if running else None
done = all(t["status"] == "done" for t in d["phases"]["phase0"]["tasks"])
d["phases"]["phase0"]["status"] = "done" if done else "in_progress"
json.dump(d, open(PATH, "w"), ensure_ascii=False, indent=2)
print(f"task {tid} -> {st}")
```

- [ ] **Step 3: 동작 확인**

```bash
python3 scripts/update_status.py 1 in_progress && python3 -c "import json; print(json.load(open('status.json'))['current'])"
```

Expected: `{'phase': 'phase0', 'task': 1}`

- [ ] **Step 4: Commit**

```bash
python3 scripts/update_status.py 1 done
git add -A && git commit -m "chore: scaffold repo, status tracking"
```

---

### Task 2: YoutumuKit — Envelope/Marker/ADTS 공유 라이브러리

**Files:**
- Create: `YoutumuKit/Package.swift`, `YoutumuKit/Sources/YoutumuKit/Envelope.swift`, `YoutumuKit/Sources/YoutumuKit/ADTS.swift`
- Test: `YoutumuKit/Tests/YoutumuKitTests/EnvelopeTests.swift`

**Interfaces:**
- Produces (Mac Agent와 Watch 앱이 공유):
  - `enum FrameType: UInt8 { case audio = 0x01, marker = 0x02 }`
  - `struct Marker: Codable, Equatable { let seq: UInt64; let trackId: String; let cause: MarkerCause }` / `enum MarkerCause: String, Codable { case command, natural, encoder }`
  - `enum Envelope { static func encode(type: FrameType, payload: Data) -> Data; static func encodeMarker(_ m: Marker) -> Data }`
  - `final class EnvelopeParser { var onAudio: ((Data) -> Void)?; var onMarker: ((Marker) -> Void)?; func feed(_ data: Data) }`
  - `func adtsHeader(payloadLength: Int) -> Data` (48kHz stereo AAC-LC 고정)

- [ ] **Step 1: 패키지 생성**

```bash
mkdir -p YoutumuKit && cd YoutumuKit && swift package init --type library --name YoutumuKit
```

- [ ] **Step 2: 실패하는 테스트 작성** (`EnvelopeTests.swift`)

```swift
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
```

- [ ] **Step 3: 실패 확인** — Run: `cd YoutumuKit && swift test` / Expected: 컴파일 실패 (타입 미정의)

- [ ] **Step 4: 구현** (`Envelope.swift`)

```swift
import Foundation

public enum FrameType: UInt8 { case audio = 0x01, marker = 0x02 }
public enum MarkerCause: String, Codable { case command, natural, encoder }
public struct Marker: Codable, Equatable {
    public let seq: UInt64; public let trackId: String; public let cause: MarkerCause
    public init(seq: UInt64, trackId: String, cause: MarkerCause) {
        self.seq = seq; self.trackId = trackId; self.cause = cause
    }
}

public enum Envelope {
    public static func encode(type: FrameType, payload: Data) -> Data {
        precondition(payload.count <= 0xFFFF)
        var d = Data(capacity: payload.count + 3)
        d.append(type.rawValue)
        d.append(UInt8(payload.count >> 8)); d.append(UInt8(payload.count & 0xFF))
        d.append(payload)
        return d
    }
    public static func encodeMarker(_ m: Marker) -> Data {
        encode(type: .marker, payload: try! JSONEncoder().encode(m))
    }
}

public final class EnvelopeParser {
    private var buf = Data()
    public var onAudio: ((Data) -> Void)?
    public var onMarker: ((Marker) -> Void)?
    public init() {}
    public func feed(_ data: Data) {
        buf.append(data)
        while buf.count >= 3 {
            let type = buf[buf.startIndex]
            let len = Int(buf[buf.startIndex + 1]) << 8 | Int(buf[buf.startIndex + 2])
            guard buf.count >= 3 + len else { return }
            let payload = buf.subdata(in: buf.startIndex + 3 ..< buf.startIndex + 3 + len)
            buf.removeFirst(3 + len)
            switch type {
            case FrameType.audio.rawValue: onAudio?(payload)
            case FrameType.marker.rawValue:
                if let m = try? JSONDecoder().decode(Marker.self, from: payload) { onMarker?(m) }
            default: break  // PoC: TLS 위 신뢰 스트림이므로 resync 없이 무시
            }
        }
    }
    public func reset() { buf.removeAll() }
}
```

(`ADTS.swift`)

```swift
import Foundation

/// AAC-LC, 48kHz(index 3), stereo 고정
public func adtsHeader(payloadLength: Int) -> Data {
    let len = payloadLength + 7
    var h = [UInt8](repeating: 0, count: 7)
    h[0] = 0xFF
    h[1] = 0xF1                                    // MPEG-4, no CRC
    h[2] = UInt8((0b01 << 6) | (3 << 2))           // profile AAC-LC(2)-1=1, sr index 3, ch 상위비트 0
    h[3] = UInt8((2 << 6) | ((len >> 11) & 0x03))  // channels 2
    h[4] = UInt8((len >> 3) & 0xFF)
    h[5] = UInt8(((len & 0x07) << 5) | 0x1F)
    h[6] = 0xFC
    return Data(h)
}
```

- [ ] **Step 5: 테스트 통과 확인** — Run: `swift test` / Expected: 3 tests PASS

- [ ] **Step 6: Commit**

```bash
python3 scripts/update_status.py 2 done
git add -A && git commit -m "feat: YoutumuKit envelope codec + ADTS header"
```

---

### Task 3: Throwaway CA 스크립트

**Files:**
- Create: `scripts/ca/make-ca.sh`, `scripts/ca/issue-server.sh`, `scripts/ca/issue-client-from-pubkey.sh`, `scripts/ca/make-test-client.sh`

**Interfaces:**
- Produces: `scripts/ca/out/{ca.crt,ca.key,server.crt,server.key}`, `issue-client-from-pubkey.sh <spki.pem> <out.crt>` (Task 8 Enrollment 서버가 호출), `out/test-client.{crt,key}` (Task 7 자가 점검용)

- [ ] **Step 1: make-ca.sh**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p out
openssl ecparam -name prime256v1 -genkey -noout -out out/ca.key
openssl req -new -x509 -key out/ca.key -sha256 -days 3650 \
  -subj "/CN=Youtumu Home Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign" \
  -out out/ca.crt
echo "CA created: out/ca.crt"
```

- [ ] **Step 2: issue-server.sh** — usage: `issue-server.sh <ddns-hostname> <lan-name> <lan-ip>`

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DDNS="$1"; LAN_NAME="$2"; LAN_IP="$3"
openssl ecparam -name prime256v1 -genkey -noout -out out/server.key
openssl req -new -key out/server.key -subj "/CN=${DDNS}" -out out/server.csr
cat > out/server.ext <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:${DDNS},DNS:${LAN_NAME},IP:${LAN_IP}
EOF
openssl x509 -req -in out/server.csr -CA out/ca.crt -CAkey out/ca.key -CAcreateserial \
  -days 1095 -sha256 -extfile out/server.ext -out out/server.crt
openssl verify -CAfile out/ca.crt out/server.crt
```

- [ ] **Step 3: issue-client-from-pubkey.sh** — usage: `issue-client-from-pubkey.sh <spki.pem> <out.crt>` (Watch가 보낸 SPKI 공개키에 대해 더미 CSR + `-force_pubkey`로 발급 — PoC에서 CSR/PoP 생략의 구현부)

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
PUB="$1"; OUT="$2"; TMP=$(mktemp -d)
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/dummy.key"
openssl req -new -key "$TMP/dummy.key" -subj "/CN=watch-s7" -out "$TMP/dummy.csr"
cat > "$TMP/client.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF
openssl x509 -req -in "$TMP/dummy.csr" -force_pubkey "$PUB" -CA out/ca.crt -CAkey out/ca.key \
  -CAcreateserial -days 1095 -sha256 -extfile "$TMP/client.ext" -out "$OUT"
rm -rf "$TMP"
openssl verify -CAfile out/ca.crt "$OUT"
```

- [ ] **Step 4: make-test-client.sh** (curl 자가 점검용 — 키 추출 가능한 테스트 인증서)

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
openssl ecparam -name prime256v1 -genkey -noout -out out/test-client.key
openssl req -new -key out/test-client.key -subj "/CN=test-client" -out out/test-client.csr
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n" > out/tc.ext
openssl x509 -req -in out/test-client.csr -CA out/ca.crt -CAkey out/ca.key -CAcreateserial \
  -days 365 -sha256 -extfile out/tc.ext -out out/test-client.crt
```

- [ ] **Step 5: 실행 검증**

```bash
chmod +x scripts/ca/*.sh
scripts/ca/make-ca.sh
scripts/ca/issue-server.sh xxxx.iptime.org $(hostname).local $(ipconfig getifaddr en0)
scripts/ca/make-test-client.sh
openssl x509 -in scripts/ca/out/server.crt -noout -ext subjectAltName,extendedKeyUsage
```

Expected: SAN에 DDNS+LAN 이름+IP, EKU `TLS Web Server Authentication`. (실제 DDNS hostname은 실행 시 치환)

- [ ] **Step 6: Commit** — `python3 scripts/update_status.py 3 done && git add -A && git commit -m "feat: throwaway CA scripts"` (out/은 gitignore로 제외 확인)

---

### Task 4: MacAgent 캡처 CLI — Chrome 오디오 → WAV

**Files:**
- Create: `MacAgent/Package.swift`, `MacAgent/Sources/MacAgent/main.swift`, `MacAgent/Sources/MacAgent/ChromeAudioCapture.swift`

**Interfaces:**
- Produces: `ChromeAudioCapture` — `func start() async throws`, `var onPCM: ((AVAudioPCMBuffer) -> Void)?`, `func stop() async` (Task 5·6이 사용)
- CLI: `swift run MacAgent capture-wav <초>` → `/tmp/capture.wav`

- [ ] **Step 1: 패키지 생성** (`MacAgent/Package.swift`)

```swift
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MacAgent",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../YoutumuKit"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
    ],
    targets: [.executableTarget(name: "MacAgent", dependencies: [
        "YoutumuKit",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
    ])]
)
```

- [ ] **Step 2: ChromeAudioCapture.swift**

```swift
import ScreenCaptureKit
import AVFoundation

enum CaptureError: Error { case chromeNotFound, noDisplay }

final class ChromeAudioCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    var onPCM: ((AVAudioPCMBuffer) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let app = content.applications.first(where: { $0.bundleIdentifier == "com.google.Chrome" })
        else { throw CaptureError.chromeNotFound }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2                       // 영상은 버림
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "cap.audio"))
        try await s.startCapture()
        stream = s
    }

    func stop() async { try? await stream?.stopCapture(); stream = nil }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let fmt = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                     into: buf.mutableAudioBufferList)
        onPCM?(buf)
    }
}
```

- [ ] **Step 3: main.swift — capture-wav 서브커맨드**

```swift
import Foundation
import AVFoundation

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
default:
    print("usage: MacAgent capture-wav <sec> | record-aac <sec> | serve | enroll <code>")
    exit(1)
}
```

- [ ] **Step 4: 수동 검증** — Chrome에서 아무 음악 재생 후:

```bash
cd MacAgent && swift run MacAgent capture-wav 10 && afplay /tmp/capture.wav
```

Expected: 최초 실행 시 화면 기록(TCC) 권한 프롬프트 → 허용 후 재실행 → 녹음된 Chrome 오디오가 들림. **화면 잠금 검증**: 화면 잠금 상태에서도 캡처가 지속되는지 30초 캡처로 확인 (spec §23 Phase 0 항목). 실패 시 Core Audio process tap(macOS 14.4+)으로 전환 검토 후 status.json에 `note` 기록.

- [ ] **Step 5: Commit** — `python3 scripts/update_status.py 4 done && git add -A && git commit -m "feat: Chrome audio capture via ScreenCaptureKit"`

---

### Task 5: AAC 인코더 + record-aac

**Files:**
- Create: `MacAgent/Sources/MacAgent/AACEncoder.swift`
- Modify: `MacAgent/Sources/MacAgent/main.swift` (record-aac 추가)

**Interfaces:**
- Produces: `AACEncoder` — `init?(inputFormat: AVAudioFormat)`, `func encode(_ pcm: AVAudioPCMBuffer) -> [Data]` (ADTS 프레임 배열 반환; Task 6이 사용)

- [ ] **Step 1: AACEncoder.swift**

```swift
import AVFoundation
import YoutumuKit

final class AACEncoder {
    private let converter: AVAudioConverter
    private let aacFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat) {
        var desc = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let f = AVAudioFormat(streamDescription: &desc),
              let c = AVAudioConverter(from: inputFormat, to: f) else { return nil }
        c.bitRate = 96_000
        aacFormat = f; converter = c
    }

    /// PCM 버퍼 하나를 ADTS AAC 프레임들로 인코딩
    func encode(_ pcm: AVAudioPCMBuffer) -> [Data] {
        var out: [Data] = []
        var fed = false
        while true {
            let comp = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 8, maximumPacketSize: 1536)
            var err: NSError?
            let st = converter.convert(to: comp, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return pcm
            }
            guard st != .error, comp.packetCount > 0 else { break }
            for i in 0 ..< Int(comp.packetCount) {
                let d = comp.packetDescriptions![i]
                let pkt = Data(bytes: comp.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
                out.append(adtsHeader(payloadLength: pkt.count) + pkt)
            }
            if st != .haveData { break }
        }
        return out
    }
}
```

- [ ] **Step 2: main.swift에 record-aac 추가** (capture-wav와 동일 골격, onPCM에서 lazy로 `AACEncoder(inputFormat: pcm.format)` 생성 → `encode()` 결과를 `/tmp/capture.aac`에 append)

```swift
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
```

- [ ] **Step 3: 검증** — Chrome 재생 중:

```bash
cd MacAgent && swift run MacAgent record-aac 10 && afplay /tmp/capture.aac
```

Expected: ADTS raw 스트림이 정상 재생됨 (afplay는 ADTS 직접 재생 가능). 음질·글리치 청취 확인.

- [ ] **Step 4: Commit** — `python3 scripts/update_status.py 5 done && git add -A && git commit -m "feat: AAC-LC encoder with ADTS framing"`

---

### Task 6: /audio/live 스트림 서버 + 마커 주입

**Files:**
- Create: `MacAgent/Sources/MacAgent/StreamServer.swift`, `scripts/strip_envelope.py`
- Modify: `MacAgent/Sources/MacAgent/main.swift` (serve 추가)

**Interfaces:**
- Produces: `StreamServer` — `init(port: Int)`, `func run() throws`, `func broadcast(_ data: Data)` (단일 수신자, 새 연결이 이전 연결 대체), `GET /audio/live`, `GET /healthz`
- CLI: `swift run MacAgent serve` — 캡처→인코딩→envelope 파이프라인 + stdin `m`+Enter로 `cause=command` MARKER 주입 (곡 전환 시뮬레이션)

- [ ] **Step 1: StreamServer.swift**

```swift
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
```

- [ ] **Step 2: main.swift에 serve 추가**

```swift
case "serve":
    let server = StreamServer(port: 8080)
    var seq: UInt64 = 0
    Task {
        let cap = ChromeAudioCapture()
        var enc: AACEncoder?
        cap.onPCM = { pcm in
            if enc == nil { enc = AACEncoder(inputFormat: pcm.format) }
            for frame in enc?.encode(pcm) ?? [] {
                server.broadcast(Envelope.encode(type: .audio, payload: frame))
            }
        }
        try await cap.start()
        print("streaming. 'm'+Enter = command 마커 주입(곡 전환 시뮬레이션)")
    }
    Task {  // stdin 마커 주입
        while let line = readLine() {
            if line == "m" {
                seq += 1
                server.broadcast(Envelope.encodeMarker(Marker(seq: seq, trackId: "sim-\(seq)", cause: .command)))
                print("MARKER seq=\(seq) sent")
            }
        }
    }
    try server.run()
```

(파일 상단에 `import YoutumuKit` 추가)

- [ ] **Step 3: strip_envelope.py** (수신 검증용 — envelope 스트림에서 AUDIO만 추출)

```python
#!/usr/bin/env python3
"""usage: strip_envelope.py stream.bin out.aac — MARKER는 stderr에 출력"""
import sys, json
data = open(sys.argv[1], "rb").read()
out = open(sys.argv[2], "wb"); i = 0
while i + 3 <= len(data):
    t, ln = data[i], int.from_bytes(data[i+1:i+3], "big")
    payload = data[i+3:i+3+ln]; i += 3 + ln
    if t == 0x01: out.write(payload)
    elif t == 0x02: print("MARKER:", json.loads(payload), file=sys.stderr)
print(f"audio bytes: {out.tell()}", file=sys.stderr)
```

- [ ] **Step 4: 검증** — Chrome 재생 중, 터미널 2개:

```bash
cd MacAgent && swift run MacAgent serve
```

```bash
curl -s --max-time 15 http://127.0.0.1:8080/audio/live -o /tmp/stream.bin
python3 scripts/strip_envelope.py /tmp/stream.bin /tmp/stream.aac && afplay /tmp/stream.aac
```

Expected: 15초 분량 오디오 재생. serve 터미널에서 `m` 입력 후 다시 curl → stderr에 `MARKER: {'seq': ...}` 출력. 두 번째 curl 연결 시 첫 연결이 끊기는지(단일 수신자) 확인.

- [ ] **Step 5: Commit** — `python3 scripts/update_status.py 6 done && git add -A && git commit -m "feat: /audio/live stream server with marker injection"`

---

### Task 7: Caddy mTLS 종단 + 자가 점검

**Files:**
- Create: `infra/Caddyfile`, `scripts/selftest.sh`

**Interfaces:**
- Produces: `:8443` mTLS 서비스 (→127.0.0.1:8080), `LAN:8444` Enrollment site (client_auth 없음, Task 8이 사용). `scripts/selftest.sh` = spec §10.8 구현

- [ ] **Step 1: Caddy 설치** — `brew install caddy`

- [ ] **Step 2: infra/Caddyfile** (`{LAN_IP}`는 실행 전 실제 값으로 치환)

```
{
    auto_https off
}

# 서비스: mTLS 필수
https://:8443 {
    tls ../scripts/ca/out/server.crt ../scripts/ca/out/server.key {
        protocols tls1.3
        client_auth {
            mode require_and_verify
            trust_pool file ../scripts/ca/out/ca.crt
        }
    }
    reverse_proxy /audio/live 127.0.0.1:8080 {
        flush_interval -1
        transport http {
            response_header_timeout 0
        }
    }
    reverse_proxy 127.0.0.1:8080
}

# Enrollment: LAN 전용, client_auth 없음 (포트포워딩 비대상 → WAN 비노출)
https://{LAN_IP}:8444 {
    bind {LAN_IP}
    tls ../scripts/ca/out/server.crt ../scripts/ca/out/server.key {
        protocols tls1.3
    }
    reverse_proxy 127.0.0.1:8081
}
```

- [ ] **Step 3: scripts/selftest.sh** (spec §10.8 — fail-closed 검증)

```bash
#!/bin/bash
set -u
CA=scripts/ca/out/ca.crt; C=scripts/ca/out/test-client
pass=0; fail=0
chk() { local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then echo "PASS: $name"; pass=$((pass+1));
  else echo "FAIL: $name (want=$want got=$got)"; fail=$((fail+1)); fi }

# 1. 인증서 없는 접속 → TLS 단계 실패
curl -s --cacert "$CA" https://localhost:8443/healthz -o /dev/null 2>/dev/null
chk "no-client-cert rejected" "1" "$([ $? -ne 0 ] && echo 1 || echo 0)"

# 2. 다른 CA의 client cert → 거부
TMP=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$TMP/k.pem" -out "$TMP/c.pem" -days 1 -subj "/CN=rogue" 2>/dev/null
curl -s --cacert "$CA" --cert "$TMP/c.pem" --key "$TMP/k.pem" https://localhost:8443/healthz -o /dev/null 2>/dev/null
chk "rogue-cert rejected" "1" "$([ $? -ne 0 ] && echo 1 || echo 0)"

# 3. 정상 인증서 → 200
code=$(curl -s --cacert "$CA" --cert "$C.crt" --key "$C.key" -o /dev/null -w "%{http_code}" https://localhost:8443/healthz 2>/dev/null)
chk "valid-cert 200" "200" "$code"

echo "---- pass=$pass fail=$fail"; [ $fail -eq 0 ]
```

- [ ] **Step 4: 검증** — 터미널1 `cd MacAgent && swift run MacAgent serve`, 터미널2 `cd infra && caddy run`, 터미널3:

```bash
chmod +x scripts/selftest.sh && scripts/selftest.sh
```

Expected: `pass=3 fail=0`. (`localhost` 검증이 실패하면 server cert SAN에 localhost가 없기 때문 — selftest는 `--resolve xxxx.iptime.org:8443:127.0.0.1`로 DDNS 이름을 로컬로 강제하는 방식으로 바꿔 실행)

- [ ] **Step 5: Commit** — `python3 scripts/update_status.py 7 done && git add -A && git commit -m "feat: Caddy mTLS termination + security selftest"`

---

### Task 8: Watch 앱 — SE 키 + Enrollment

**Files:**
- Create: `watch/YoutumuWatch.xcodeproj` (Xcode 생성), `watch/YoutumuWatch Watch App/KeyStore.swift`, `watch/YoutumuWatch Watch App/EnrollClient.swift`, `watch/YoutumuWatch Watch App/ContentView.swift`
- Modify: `MacAgent/Sources/MacAgent/main.swift` + Create: `MacAgent/Sources/MacAgent/EnrollServer.swift`

**Interfaces:**
- Consumes: `scripts/ca/issue-client-from-pubkey.sh` (Task 3)
- Produces: Watch Keychain의 `SecIdentity` (tag `com.youtumu.watch.key`) — Task 9가 사용. Mac: `swift run MacAgent enroll <6자리코드>` → 127.0.0.1:8081 (Caddy :8444 뒤)

- [ ] **Step 1: Xcode 프로젝트 생성** — Xcode → New Project → watchOS → App, Product Name `YoutumuWatch`, 위치 `watch/`. Signing: Personal Team. **Frameworks, Libraries에 로컬 패키지 `YoutumuKit` 추가** (File → Add Package Dependencies → Add Local). Info의 Background Modes에 `audio` 추가 (Signing & Capabilities → +Capability → Background Modes → Audio). 리소스로 `scripts/ca/out/ca.crt`를 번들에 추가 (파일명 `ca.crt`).

- [ ] **Step 2: EnrollServer.swift (Mac 측)** — Task 6의 NIO 골격 재사용, 127.0.0.1:8081에 bind, `POST /enroll` body JSON `{"code": "...", "pubkeyPem": "..."}`:

```swift
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
```

main.swift에 `case "enroll": try EnrollServer(code: args[2]).run()` 추가.

- [ ] **Step 3: KeyStore.swift (Watch 측)** — SE 키 생성 + SPKI PEM 추출 + 인증서 저장 + SecIdentity 조회

```swift
import Foundation
import Security

enum KeyStore {
    static let tag = "com.youtumu.watch.key".data(using: .utf8)!

    /// Secure Enclave P-256 키 (없으면 생성). SE 미지원 판명 시 kSecAttrTokenID 제거가 fallback (결과를 status.json note에 기록할 것)
    static func privateKey() throws -> SecKey {
        let q: [String: Any] = [kSecClass as String: kSecClassKey,
                                kSecAttrApplicationTag as String: tag,
                                kSecReturnRef as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess { return item as! SecKey }
        let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                     [.privateKeyUsage], nil)!
        var attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                                            kSecAttrApplicationTag as String: tag,
                                            kSecAttrAccessControl as String: access]]
        #if !targetEnvironment(simulator)
        attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave   // Simulator에는 SE 없음
        #endif
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw err!.takeRetainedValue() as Error
        }
        return key
    }

    /// 공개키를 SPKI PEM으로 (EC uncompressed point 앞에 P-256 SPKI 고정 헤더)
    static func publicKeyPEM() throws -> String {
        let pub = SecKeyCopyPublicKey(try privateKey())!
        var err: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }
        let spkiHeader: [UInt8] = [0x30,0x59,0x30,0x13,0x06,0x07,0x2A,0x86,0x48,0xCE,0x3D,
                                   0x02,0x01,0x06,0x08,0x2A,0x86,0x48,0xCE,0x3D,0x03,0x01,
                                   0x07,0x03,0x42,0x00]
        let der = Data(spkiHeader) + raw
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(b64)\n-----END PUBLIC KEY-----\n"
    }

    static func storeCertificate(der: Data) throws {
        let cert = SecCertificateCreateWithData(nil, der as CFData)!
        SecItemDelete([kSecClass as String: kSecClassCertificate,
                       kSecAttrLabel as String: "youtumu-client"] as CFDictionary)
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                  kSecValueRef as String: cert,
                                  kSecAttrLabel as String: "youtumu-client"]
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess || st == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(st))
        }
    }

    /// 저장된 cert + SE 키 → SecIdentity (Phase 0의 핵심 검증 지점)
    static func identity() -> SecIdentity? {
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                kSecReturnRef as String: true,
                                kSecMatchLimit as String: kSecMatchLimitFirst]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecIdentity)
    }
}
```

- [ ] **Step 4: EnrollClient.swift + ContentView.swift** — 서버 신뢰는 번들 `ca.crt`만 사용 (spec §10.3)

```swift
import Foundation
import Security

final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    static let caCert: SecCertificate = {
        let url = Bundle.main.url(forResource: "ca", withExtension: "crt")!
        let pem = try! String(contentsOf: url)
        let b64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return SecCertificateCreateWithData(nil, Data(base64Encoded: b64)! as CFData)!
    }()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            let trust = challenge.protectionSpace.serverTrust!
            SecTrustSetAnchorCertificates(trust, [Self.caCert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)          // 시스템 CA 무시
            var err: CFError?
            if SecTrustEvaluateWithError(trust, &err) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        case NSURLAuthenticationMethodClientCertificate:
            if let id = KeyStore.identity() {
                completionHandler(.useCredential, URLCredential(identity: id, certificates: nil, persistence: .forSession))
            } else { completionHandler(.performDefaultHandling, nil) }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum EnrollClient {
    /// macAddr 예: "192.168.0.10" — Caddy :8444
    static func enroll(macAddr: String, code: String) async throws -> Bool {
        let session = URLSession(configuration: .default, delegate: PinnedSessionDelegate(), delegateQueue: nil)
        var req = URLRequest(url: URL(string: "https://\(macAddr):8444/enroll")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["code": code, "pubkeyPem": KeyStore.publicKeyPEM()])
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONDecoder().decode([String: String].self, from: data),
              let der = Data(base64Encoded: obj["certDer"] ?? "") else { return false }
        try KeyStore.storeCertificate(der: der)
        return KeyStore.identity() != nil
    }
}
```

ContentView: Mac 주소·코드 입력 필드(수동 입력, spec §10.5) + "Enroll" 버튼 → 결과 텍스트("identity OK" / 오류) 표시. `.task`에서 `KeyStore.identity() != nil`이면 "enrolled" 표시.

```swift
import SwiftUI

struct ContentView: View {
    @State private var mac = "192.168.0.10"
    @State private var code = ""
    @State private var status = "not enrolled"
    var body: some View {
        ScrollView { VStack(spacing: 8) {
            TextField("Mac LAN IP", text: $mac)
            TextField("code", text: $code)
            Button("Enroll") {
                Task {
                    do { status = try await EnrollClient.enroll(macAddr: mac, code: code) ? "identity OK" : "enroll failed" }
                    catch { status = "error: \(error.localizedDescription)" }
                }
            }
            Text(status).font(.footnote)
        }}
        .task { if KeyStore.identity() != nil { status = "enrolled (identity OK)" } }
    }
}
```

- [ ] **Step 5: 검증** — Mac에서 `swift run MacAgent enroll 123456` + `caddy run`. server cert SAN에 Mac LAN IP가 포함돼 있어야 함(Task 3에서 발급 시 지정). Watch 실기기에 Xcode로 설치(iPhone 페어링 경유), 같은 Wi-Fi에서 IP·코드 입력 → Enroll.

Expected: `identity OK`. **이것이 SE 키 + 인증서 + SecIdentity 결합의 실증** (spec §23 Phase 0 두 번째 항목). 실패 시: (a) SE 키 생성 실패면 `kSecAttrTokenID` 제거한 keychain 키로 fallback 후 재시도, (b) identity 조회 실패면 인증서/키 매칭 문제 — 결과를 `python3 scripts/update_status.py 8 <status> "<원인>"`으로 기록.

- [ ] **Step 6: Commit** — `python3 scripts/update_status.py 8 done && git add -A && git commit -m "feat: watch SE key enrollment + Mac enroll server"`

---

### Task 9: Watch 스트림 수신 + 재생

**Files:**
- Create: `watch/YoutumuWatch Watch App/StreamPlayer.swift`, `watch/YoutumuWatch Watch App/AACDecoder.swift`
- Modify: `watch/YoutumuWatch Watch App/ContentView.swift` (Play 버튼 추가)

**Interfaces:**
- Consumes: `EnvelopeParser`/`Marker` (YoutumuKit), `PinnedSessionDelegate`·`KeyStore.identity()` (Task 8)
- Produces: `StreamPlayer` — `func start(url: URL) async throws`, `func stop()`; pre-buffer 1초, `cause == .command` MARKER에서 flush (spec §6 지연 모델)

- [ ] **Step 1: AACDecoder.swift**

```swift
import AVFAudio

final class AACDecoder {
    let outFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var converter: AVAudioConverter?

    func decode(adtsFrame: Data) -> AVAudioPCMBuffer? {
        let payload = Data(adtsFrame.dropFirst(7))          // ADTS 7바이트 헤더 제거 (no-CRC 고정, Task 2)
        if converter == nil {
            var desc = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            let inFmt = AVAudioFormat(streamDescription: &desc)!
            converter = AVAudioConverter(from: inFmt, to: outFormat)
        }
        guard let conv = converter else { return nil }
        let inBuf = AVAudioCompressedBuffer(format: conv.inputFormat, packetCapacity: 1,
                                            maximumPacketSize: max(payload.count, 1))
        payload.withUnsafeBytes { raw in
            inBuf.data.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
        }
        inBuf.byteLength = UInt32(payload.count)
        inBuf.packetCount = 1
        inBuf.packetDescriptions![0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1024) else { return nil }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        return out.frameLength > 0 ? out : nil
    }

    func reset() { converter?.reset() }
}
```

- [ ] **Step 2: StreamPlayer.swift**

```swift
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
        try av.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try await av.activate()                                  // 출력 라우트 선택 UI (AirPods)
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
    }
}
```

- [ ] **Step 3: ContentView에 재생 UI 추가** — `@State private var player = StreamPlayer()`, "Play" 버튼 → `try await player.start(url: URL(string: "https://\(serverHost):8443/audio/live")!)` (serverHost: 집 밖 테스트는 DDNS hostname, LAN 테스트는 NAT loopback 실패 시 Mac IP), "Stop" 버튼 → `player.stop()`. `onMarker`로 마지막 마커 seq를 화면에 표시 (latency 측정용).

- [ ] **Step 4: Wi-Fi 검증** — Mac: `serve` + `caddy run`, Chrome 재생 중. Watch(같은 Wi-Fi): Play 탭 → 출력 라우트 선택(AirPods) → 오디오 재생 확인. serve 터미널에서 `m` 입력 → **1초 내외 끊김 후 이어지면 flush + pre-buffer 동작 확인**.

Expected: AirPods에서 Chrome 오디오 청취. 실패 지점별 기록: TLS 실패(=SecIdentity/mTLS 문제), 재생 실패(=디코더/세션 문제).

- [ ] **Step 5: Commit** — `python3 scripts/update_status.py 9 done && git add -A && git commit -m "feat: watch mTLS stream player with pre-buffer and marker flush"`

---

### Task 10: 필드 테스트 + 게이트 판정

**Files:**
- Create: `docs/poc-results.md`
- Modify: `status.json` (게이트 결과 기록)

**Interfaces:**
- Consumes: 전체 스택 (Task 1~9)
- Produces: Phase 0 게이트 판정 (`status.json`의 `phases.phase0.gate`) — Phase 1~6 착수 여부 결정

- [ ] **Step 1: 사전 조건** — ipTIME: DDNS 설정 + TCP 18443 → Mac:8443 포워딩 1건 (spec §4). iPhone은 집에 두거나 전원 OFF (Watch 셀룰러 단독 강제).

- [ ] **Step 2: 게이트 항목 측정** — 각 항목을 `docs/poc-results.md`에 아래 표로 기록:

```markdown
# Phase 0 PoC Results (측정일: )

| Gate | 항목 | 기준 | 측정값 | 판정 |
|---|---|---|---|---|
| G1 | 백그라운드 재생 | 화면 OFF + 손목 내림 10분 지속 | | |
| G2 | 셀룰러 단독 | iPhone 없이 외부 LTE에서 재생 시작 성공 | | |
| G3 | SE mTLS | SecIdentity 기반 연결 성공 (LAN + LTE) | | |
| G4 | 곡 전환 latency | `m` 마커 10회, p95 ≤ 2초 (마커 전송 시각 → 오디오 변화 청취) | | |
| G5 | 60분 soak | 자동 복구 불가 disconnect 0회, stall 누적 < 30초 | | |
| G6 | Mac 캡처 | 화면 잠금 상태에서 캡처 지속 | | |
| M1 | 배터리 (기록용) | 60분 소모 % | | 판정 없음 |
| M2 | 셀룰러 데이터 (기록용) | 60분 사용량 MB | | 판정 없음 |

## 실패 항목 상세 / fallback 결정
(G 실패 시: 어떤 가정이 깨졌는지, spec §6 fallback(LL-HLS/HLS)·비-SE 키·지연 상향 중 무엇으로 가는지)
```

G4 측정 방법: serve 터미널에서 `m` 입력 시각을 `date +%s.%N`으로 기록하고, Watch 화면의 마커 seq 갱신·청취 변화 시점과 대조 (수동 스톱워치, 10회).

- [ ] **Step 3: 게이트 판정 기록**

```bash
# 전부 통과 시
python3 - <<'EOF'
import json, datetime
d = json.load(open("status.json"))
d["phases"]["phase0"]["gate"] = {"result": "PASS", "date": datetime.date.today().isoformat(),
                                 "details": "docs/poc-results.md"}
for p in ("phase1","phase2","phase3","phase4","phase5","phase6"):
    d["phases"][p]["status"] = "pending"
json.dump(d, open("status.json","w"), ensure_ascii=False, indent=2)
EOF
```

실패 시 `"result": "FAIL"` + 실패 게이트 목록을 기록하고 Phase 1~6은 `blocked` 유지 — 설계 재검토로 복귀.

- [ ] **Step 4: Commit** — `python3 scripts/update_status.py 10 done && git add -A && git commit -m "docs: phase 0 gate results"`

---

## Phase 1~6 로드맵 (게이트 통과 후 각각 상세 계획 수립)

상세 태스크는 Phase 0 결과(캡처 방식·SE 여부·실측 latency)에 의존하므로 게이트 통과 후 작성한다.

| Phase | 내용 | 핵심 산출물 | 선행 |
|---|---|---|---|
| 1 | Mac Player Control | CDP(127.0.0.1:9222) 기반 Browser Controller, REST 명령(allow-list + commandId 멱등성, spec §5·§11), YouTube Music 재생/정지/곡 전환 | Phase 0 PASS |
| 2 | Library | Metadata Sync → Playlist Cache(SQLite), `/api/playlists`·`/api/queue`, artwork 프록시 (spec §9) | 1 |
| 3 | Audio 정식화 | PoC 코드를 Agent에 통합, 실제 곡 전환 이벤트 → MARKER(cause 분기), Pause 정책(10초 무음 → 송신 중단), 단일 수신자 정리 (spec §6) | 1 |
| 4 | Security 정식화 | Enrollment ceremony 정식 절차(§10.5), CA key 오프라인 보관 운영, selftest 확장(§24 기준 10) | 3 |
| 5 | watchOS UI | Playlists/Detail/Now Playing/Queue, Crown volume, optimistic UI + stateVersion reconcile (spec §14~§22) | 2, 3 |
| 6 | Stability | 자동 재접속, LTE↔Wi-Fi handover, buffering 튜닝(time-stretch 여부 결정), 60분+ soak, §24 전 항목 판정 | 5 |

---

## Self-Review 결과

- **Spec 커버리지**: §23 Phase 0의 3개 항목 — Watch 묶음 검증(Task 9·10), SE+SecIdentity(Task 8), Mac 캡처+화면 잠금+launchd 양립(Task 4; launchd 비관리자 실행 검증은 Phase 4로 명시 이관 — PoC는 포그라운드 실행). §10.8 자가 점검(Task 7), §6 envelope/지연 모델/flush 분기(Task 2·6·9), §24 기준 7·9·10의 측정(Task 10 게이트).
- **의도된 spec 이탈** (Global Constraints에 명시): CSR/PoP 생략(`-force_pubkey`), Enrollment TLS를 Caddy가 대행, 자동 재접속 미구현(Phase 6). 모두 kill-risk 검증에 불필요한 항목.
- **타입 일관성**: `EnvelopeParser.feed/onAudio/onMarker`, `Marker(seq:trackId:cause:)`, `adtsHeader(payloadLength:)`, `KeyStore.identity()`, `PinnedSessionDelegate`가 태스크 간 동일 시그니처로 사용됨을 확인.

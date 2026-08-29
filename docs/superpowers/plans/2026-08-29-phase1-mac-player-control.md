# Phase 1 — Mac Player Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Watch(또는 curl)에서 REST 명령으로 Mac의 YouTube Music을 제어(Play/Pause/Next/Previous/특정 Track 재생)하고, 실제 플레이어 상태를 `GET /api/player`로 조회하며, 곡 전환 시 실제 MARKER가 오디오 스트림에 주입되게 한다.

**Architecture:** MacAgent에 CDP(Chrome DevTools Protocol, `ws://127.0.0.1:9222`) 기반 BrowserController를 추가한다. PlayerStateService가 1초 폴링으로 YT Music DOM 상태를 읽어 `stateVersion` 단조 증가 스냅샷을 유지하고, trackId 변화를 감지해 MARKER(cause: command/natural)를 스트림에 주입한다. 기존 StreamServer(NIO, 127.0.0.1:8080)에 `/api/*` 라우팅을 추가하며, Caddy는 이미 전 경로를 8080으로 프록시하므로 변경은 body 크기 제한 추가뿐이다.

**Tech Stack:** Swift 5.9 / macOS 14 / swift-nio 2.60+ / URLSessionWebSocketTask(CDP) / XCTest. Watch: SwiftUI + 기존 PinnedSessionDelegate.

**Spec:** `apple_watch_youtube_music_remote_player_design.md` — §5(REST·멱등성), §7(Agent 컴포넌트·bind), §8(YT Music 제어·Source of Truth), §11(allow-list·입력 검증·CDP 보안), §22(상태 모델), §23 Phase 1 범위. 백로그: `docs/poc-results.md` "YT Music 자동 일시정지 팝업 → Phase 1 CDP 제어에서 처리".

## Global Constraints

- Agent HTTP는 `127.0.0.1:8080`만 bind. CDP는 `127.0.0.1:9222`만. 인터넷 노출 프로세스는 Caddy 하나 (§7)
- Command Allow-list: `PLAY, PAUSE, NEXT, PREVIOUS, PLAY_TRACK`만. Watch로부터 임의 URL/JavaScript 수신 금지 — JS는 Agent 내부 고정 스니펫만 (§11)
- `trackId`(videoId) 형식 검증: `^[A-Za-z0-9_-]{1,64}$` 통과 후에만 사용 (§11)
- 모든 POST 명령에 클라이언트 생성 `commandId`(UUID) 필수. 중복 수신 시 재실행 없이 이전 결과 반환 (§5)
- `GET /api/player` 응답에 단조 증가 `stateVersion` 포함 (§5)
- 정의되지 않은 필드·엔드포인트는 무시가 아니라 **거부** (§11)
- request body 크기 제한은 Caddy와 Agent **양쪽** 적용 (§11) — Agent 4KB, Caddy 16KB
- 오류 규약: 4xx = 요청 거부(재시도 무의미), 5xx = 실행 여부 불명 (§5)
- Source of Truth는 실제 YT Music Player 상태 — Mac에서 직접 조작해도 polling으로 반영 (§8)
- 원격 제어 전용 Chrome 프로필 분리 (§11) — 개인 브라우징 세션과 격리
- 기존 코드 스타일 준수: 한국어 스펙-참조 주석, NSLock 기반 동기화, 작은 파일
- 커밋은 태스크 단위로 작게. main 직접 커밋 (Phase 0 룰링 계승, 단독 개인 repo)

## Out of Scope (이 계획에서 하지 않음)

- Playlist/Queue 조회·재생, metadata cache, artwork — Phase 2
- WebSocket push, optimistic UI, 자동 재접속 — Phase 5/6
- `POST /api/queue/{position}`의 stateVersion 409 검증 — Queue가 Phase 2이므로 함께
- StreamPlayer 메트릭 데이터 레이스(리뷰 관찰 사항) — Phase 0 측정용 코드, Phase 5 UI 재작성 시 actor화
- SCStream 사망 감지·자동 재시작 — Phase 3/6 (spec §24)

## File Structure

```
MacAgent/Package.swift                          # 수정: MacAgentCore 라이브러리 + 테스트 타깃 분리
MacAgent/Sources/MacAgentCore/                  # 기존 4파일 이동(+public화) + 신규 6파일
├─ ChromeAudioCapture.swift                     # 이동
├─ AACEncoder.swift                             # 이동
├─ StreamServer.swift                           # 이동 + /api 라우팅(바디 수집·dispatch) 추가
├─ EnrollServer.swift                           # 이동
├─ CommandStore.swift                           # 신규: commandId 멱등성 저장소
├─ CDPCodec.swift                               # 신규: CDP JSON 인코딩/디코딩 (순수 함수)
├─ CDPClient.swift                              # 신규: /json 타깃 발견 + WebSocket evaluate
├─ YTMSelectors.swift                           # 신규: YT Music JS 스니펫 전부 (한 곳에 격리)
├─ BrowserController.swift                      # 신규: 명령 실행 + 스냅샷 읽기 + 팝업 해제
├─ PlayerStateService.swift                     # 신규: 폴링·stateVersion·MARKER 분류
└─ ControlAPI.swift                             # 신규: REST 라우팅·검증·멱등성 결합 (순수 async)
MacAgent/Sources/MacAgent/main.swift            # 수정: serve에 CDP/API 배선
MacAgent/Tests/MacAgentTests/                   # 신규 테스트 5파일
YoutumuKit/Sources/YoutumuKit/PlayerState.swift # 신규: PlayerState·CommandResponse (Watch 공유)
scripts/launch-chrome-ytm.sh                    # 신규: 전용 프로필 Chrome 실행
infra/Caddyfile                                 # 수정: request_body max_size
watch/YoutumuWatch Watch App/ApiClient.swift    # 신규: 핀닝 세션으로 REST 호출
watch/YoutumuWatch Watch App/ContentView.swift  # 수정: 제어 버튼 + now playing
```

책임 분리 원칙: CDP 통신(CDPClient)·JS 스니펫(YTMSelectors)·상태 해석(PlayerStateService)·HTTP 검증(ControlAPI)을 분리해, 각각 (a) YT Music DOM 변경, (b) CDP 프로토콜 이슈, (c) API 규약 변경이 서로 다른 파일만 건드리게 한다. 순수 로직(코덱·멱등성·상태 분류·라우팅)은 전부 XCTest로 커버하고, 실 Chrome/실기기 검증은 Task 7·8 체크포인트에서 한다.

---

### Task 1: MacAgent 패키지 분리 (MacAgentCore + 테스트 타깃)

**Files:**
- Modify: `MacAgent/Package.swift`
- Move: `MacAgent/Sources/MacAgent/{ChromeAudioCapture,AACEncoder,StreamServer,EnrollServer}.swift` → `MacAgent/Sources/MacAgentCore/`
- Modify: 이동한 4개 파일 (public 접근자)
- Modify: `MacAgent/Sources/MacAgent/main.swift` (import 추가)
- Create: `MacAgent/Tests/MacAgentTests/SmokeTests.swift`

**Interfaces:**
- Consumes: 기존 타입들 (시그니처 불변)
- Produces: `MacAgentCore` 모듈 — 이후 모든 태스크의 코드·테스트가 이 모듈에 들어감. public 표면: `ChromeAudioCapture(init/onPCM/start/stop)`, `AACEncoder(init(inputFormat:)/encode)`, `StreamServer(init(port:)/broadcast/run)`, `EnrollServer(init(code:)/run)`

- [ ] **Step 1: Package.swift를 3-타깃 구조로 수정**

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
    targets: [
        .target(name: "MacAgentCore", dependencies: [
            "YoutumuKit",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
        .executableTarget(name: "MacAgent", dependencies: ["MacAgentCore", "YoutumuKit"]),
        .testTarget(name: "MacAgentTests", dependencies: ["MacAgentCore", "YoutumuKit"]),
    ]
)
```

- [ ] **Step 2: 4개 파일을 Sources/MacAgentCore/로 git mv 하고 public화**

```bash
cd MacAgent && mkdir -p Sources/MacAgentCore Tests/MacAgentTests
git mv Sources/MacAgent/ChromeAudioCapture.swift Sources/MacAgentCore/
git mv Sources/MacAgent/AACEncoder.swift Sources/MacAgentCore/
git mv Sources/MacAgent/StreamServer.swift Sources/MacAgentCore/
git mv Sources/MacAgent/EnrollServer.swift Sources/MacAgentCore/
```

각 파일에서 main.swift가 쓰는 표면만 `public` 추가: 클래스 선언 4개, `ChromeAudioCapture.onPCM/start()/stop()`, `AACEncoder.init(inputFormat:)/encode(_:)`, `StreamServer.init(port:)/broadcast(_:)/run()`, `EnrollServer.init(code:)/run()`. public 클래스의 designated init이 없던 곳(`ChromeAudioCapture`)은 `public init() {}` 명시. `StreamServer.Handler` 등 내부 타입은 그대로 internal.

- [ ] **Step 3: main.swift 상단에 `import MacAgentCore` 추가**

- [ ] **Step 4: 스모크 테스트 작성**

```swift
// Tests/MacAgentTests/SmokeTests.swift
import XCTest
@testable import MacAgentCore

final class SmokeTests: XCTestCase {
    func testModuleLinks() {
        _ = StreamServer(port: 0)   // 모듈 분리·링크 확인용
    }
}
```

- [ ] **Step 5: 빌드+테스트 통과 확인**

Run: `cd MacAgent && swift build && swift test`
Expected: Build complete, 1 test passed

- [ ] **Step 6: Commit**

```bash
git add -A MacAgent && git commit -m "refactor: split MacAgent into MacAgentCore library + test target"
```

---

### Task 2: PlayerState 모델(YoutumuKit) + CommandStore 멱등성

**Files:**
- Create: `YoutumuKit/Sources/YoutumuKit/PlayerState.swift`
- Create: `MacAgent/Sources/MacAgentCore/CommandStore.swift`
- Test: `MacAgent/Tests/MacAgentTests/CommandStoreTests.swift`

**Interfaces:**
- Produces:
  - `public enum PlaybackState: String, Codable { case stopped, playing, paused }`
  - `public struct PlayerState: Codable, Equatable { stateVersion: UInt64, playback: PlaybackState, trackId: String, title: String, artist: String, positionSec: Double, durationSec: Double }` + memberwise `public init`
  - `public struct CommandResponse: Codable, Equatable { stateVersion: UInt64, duplicate: Bool }` + `public init`
  - `public final class CommandStore { init(capacity: Int = 64); cached(_ commandId: String) -> CommandResponse?; record(_ commandId: String, _ r: CommandResponse) }`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Tests/MacAgentTests/CommandStoreTests.swift
import XCTest
import YoutumuKit
@testable import MacAgentCore

final class CommandStoreTests: XCTestCase {
    func testFirstSeenReturnsNil() {
        XCTAssertNil(CommandStore().cached("A"))
    }
    func testDuplicateReturnsRecordedResponseWithDuplicateFlag() {
        let s = CommandStore()
        s.record("A", CommandResponse(stateVersion: 3, duplicate: false))
        XCTAssertEqual(s.cached("A"), CommandResponse(stateVersion: 3, duplicate: true))
    }
    func testEvictionDropsOldestOnly() {
        let s = CommandStore(capacity: 2)
        s.record("A", CommandResponse(stateVersion: 1, duplicate: false))
        s.record("B", CommandResponse(stateVersion: 2, duplicate: false))
        s.record("C", CommandResponse(stateVersion: 3, duplicate: false))
        XCTAssertNil(s.cached("A"))
        XCTAssertNotNil(s.cached("B"))
        XCTAssertNotNil(s.cached("C"))
    }
    func testPlayerStateRoundTrip() throws {
        let st = PlayerState(stateVersion: 7, playback: .playing, trackId: "abc",
                             title: "t", artist: "a", positionSec: 1.5, durationSec: 200)
        let decoded = try JSONDecoder().decode(PlayerState.self, from: JSONEncoder().encode(st))
        XCTAssertEqual(decoded, st)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd MacAgent && swift test --filter CommandStoreTests`
Expected: 컴파일 실패 (타입 미정의)

- [ ] **Step 3: 구현**

```swift
// YoutumuKit/Sources/YoutumuKit/PlayerState.swift
import Foundation

public enum PlaybackState: String, Codable { case stopped, playing, paused }

public struct PlayerState: Codable, Equatable {
    public var stateVersion: UInt64          // 단조 증가 — polling 응답 역전 방지 (spec §5·§22)
    public var playback: PlaybackState
    public var trackId: String
    public var title: String
    public var artist: String
    public var positionSec: Double
    public var durationSec: Double
    public init(stateVersion: UInt64, playback: PlaybackState, trackId: String,
                title: String, artist: String, positionSec: Double, durationSec: Double) {
        self.stateVersion = stateVersion; self.playback = playback; self.trackId = trackId
        self.title = title; self.artist = artist
        self.positionSec = positionSec; self.durationSec = durationSec
    }
}

public struct CommandResponse: Codable, Equatable {
    public let stateVersion: UInt64
    public let duplicate: Bool
    public init(stateVersion: UInt64, duplicate: Bool) {
        self.stateVersion = stateVersion; self.duplicate = duplicate
    }
}
```

```swift
// MacAgent/Sources/MacAgentCore/CommandStore.swift
import Foundation
import YoutumuKit

/// commandId 멱등성 저장소 (spec §5) — NEXT 같은 비멱등 명령의 재시도 이중 실행 방지.
/// cached→record 사이 동일 id 동시 도달은 단일 사용자 조건상 미방어 (Phase 6 재검토).
public final class CommandStore {
    private let lock = NSLock()
    private var order: [String] = []
    private var results: [String: CommandResponse] = [:]
    private let capacity: Int
    public init(capacity: Int = 64) { self.capacity = capacity }

    public func cached(_ commandId: String) -> CommandResponse? {
        lock.lock(); defer { lock.unlock() }
        guard let r = results[commandId] else { return nil }
        return CommandResponse(stateVersion: r.stateVersion, duplicate: true)
    }

    public func record(_ commandId: String, _ r: CommandResponse) {
        lock.lock(); defer { lock.unlock() }
        if results[commandId] == nil { order.append(commandId) }
        results[commandId] = r
        while order.count > capacity {
            results.removeValue(forKey: order.removeFirst())
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd MacAgent && swift test --filter CommandStoreTests`
Expected: 4 tests passed

- [ ] **Step 5: Commit**

```bash
git add YoutumuKit MacAgent && git commit -m "feat: PlayerState model + CommandStore idempotency (spec §5)"
```

---

### Task 3: CDP 코덱 + CDPClient (WebSocket)

**Files:**
- Create: `MacAgent/Sources/MacAgentCore/CDPCodec.swift`
- Create: `MacAgent/Sources/MacAgentCore/CDPClient.swift`
- Test: `MacAgent/Tests/MacAgentTests/CDPCodecTests.swift`

**Interfaces:**
- Produces:
  - `enum CDPCodec { static func evaluateRequest(id: Int, expression: String) -> Data; static func decodeResponse(_ data: Data) -> (id: Int, value: String?)? }` (internal — 모듈 내부용)
  - `public enum CDPError: Error { case noTarget, disconnected, badResponse }`
  - `public final class CDPClient { public init(port: Int = 9222); public func connect() async throws; public func evaluate(_ js: String) async throws -> String? }`
- 참고: CDP `Runtime.evaluate`는 `{id, method, params:{expression, returnByValue:true}}`를 보내고 `{id, result:{result:{type,value}}}`를 받는다. 우리 JS 스니펫은 항상 문자열(JSON string) 또는 undefined를 반환하므로 value는 `String?`로 충분하다.

- [ ] **Step 1: 코덱의 실패하는 테스트 작성**

```swift
// Tests/MacAgentTests/CDPCodecTests.swift
import XCTest
@testable import MacAgentCore

final class CDPCodecTests: XCTestCase {
    func testEvaluateRequestShape() throws {
        let d = CDPCodec.evaluateRequest(id: 7, expression: "1+1")
        let o = try JSONSerialization.jsonObject(with: d) as! [String: Any]
        XCTAssertEqual(o["id"] as? Int, 7)
        XCTAssertEqual(o["method"] as? String, "Runtime.evaluate")
        let p = o["params"] as! [String: Any]
        XCTAssertEqual(p["expression"] as? String, "1+1")
        XCTAssertEqual(p["returnByValue"] as? Bool, true)
    }
    func testDecodeStringResult() {
        let json = #"{"id":7,"result":{"result":{"type":"string","value":"hi"}}}"#
        let r = CDPCodec.decodeResponse(Data(json.utf8))
        XCTAssertEqual(r?.id, 7)
        XCTAssertEqual(r?.value, "hi")
    }
    func testDecodeUndefinedResultHasNilValue() {
        let json = #"{"id":3,"result":{"result":{"type":"undefined"}}}"#
        let r = CDPCodec.decodeResponse(Data(json.utf8))
        XCTAssertEqual(r?.id, 3)
        XCTAssertNil(r?.value)
    }
    func testDecodeEventWithoutIdReturnsNil() {
        let json = #"{"method":"Runtime.consoleAPICalled","params":{}}"#
        XCTAssertNil(CDPCodec.decodeResponse(Data(json.utf8)))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd MacAgent && swift test --filter CDPCodecTests`
Expected: 컴파일 실패

- [ ] **Step 3: 코덱 구현**

```swift
// MacAgent/Sources/MacAgentCore/CDPCodec.swift
import Foundation

/// Chrome DevTools Protocol 메시지 직렬화. Runtime.evaluate만 사용한다 (spec §11 — 고정 스니펫 실행 전용).
enum CDPCodec {
    static func evaluateRequest(id: Int, expression: String) -> Data {
        let msg: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true],
        ]
        return try! JSONSerialization.data(withJSONObject: msg)   // 키·값 전부 JSON-호환 리터럴
    }

    /// 응답이면 (id, string value). 이벤트(id 없음)나 파싱 불가면 nil.
    static func decodeResponse(_ data: Data) -> (id: Int, value: String?)? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["id"] as? Int else { return nil }
        let inner = (o["result"] as? [String: Any])?["result"] as? [String: Any]
        return (id, inner?["value"] as? String)
    }
}
```

- [ ] **Step 4: 코덱 테스트 통과 확인**

Run: `cd MacAgent && swift test --filter CDPCodecTests`
Expected: 4 tests passed

- [ ] **Step 5: CDPClient 구현 (라이브 검증은 Task 7 체크포인트)**

```swift
// MacAgent/Sources/MacAgentCore/CDPClient.swift
import Foundation

public enum CDPError: Error { case noTarget, disconnected, badResponse }

/// Chrome DevTools에 WebSocket으로 붙어 Runtime.evaluate를 실행한다.
/// 반드시 127.0.0.1에만 접속 (spec §11 — CDP는 loopback 전용).
public final class CDPClient: NSObject {
    private let port: Int
    private var ws: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<String?, Error>] = [:]

    public init(port: Int = 9222) { self.port = port }

    private struct Target: Decodable { let type: String; let url: String; let webSocketDebuggerUrl: String }

    public func connect() async throws {
        disconnect()
        let listURL = URL(string: "http://127.0.0.1:\(port)/json")!
        let (data, _) = try await URLSession.shared.data(from: listURL)
        let targets = try JSONDecoder().decode([Target].self, from: data)
        guard let t = targets.first(where: { $0.type == "page" && $0.url.hasPrefix("https://music.youtube.com") })
        else { throw CDPError.noTarget }
        let task = URLSession.shared.webSocketTask(with: URL(string: t.webSocketDebuggerUrl)!)
        task.resume()
        lock.lock(); ws = task; lock.unlock()
        receiveLoop(task)
    }

    public func evaluate(_ js: String) async throws -> String? {
        lock.lock()
        guard let task = ws else { lock.unlock(); throw CDPError.disconnected }
        let id = nextId; nextId += 1
        lock.unlock()
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending[id] = cont; lock.unlock()
            task.send(.data(CDPCodec.evaluateRequest(id: id, expression: js))) { [weak self] err in
                if let err { self?.fail(id: id, err) }
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.failAll(CDPError.disconnected)
            case .success(let msg):
                let data: Data
                switch msg {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                if let (id, value) = CDPCodec.decodeResponse(data) {
                    self.lock.lock(); let cont = self.pending.removeValue(forKey: id); self.lock.unlock()
                    cont?.resume(returning: value)
                }
                self.receiveLoop(task)   // 이벤트 프레임은 무시하고 계속 수신
            }
        }
    }

    private func fail(id: Int, _ err: Error) {
        lock.lock(); let cont = pending.removeValue(forKey: id); lock.unlock()
        cont?.resume(throwing: err)
    }

    private func failAll(_ err: Error) {
        lock.lock(); let conts = pending.values; pending.removeAll(); ws = nil; lock.unlock()
        conts.forEach { $0.resume(throwing: err) }
    }

    private func disconnect() {
        lock.lock(); let task = ws; ws = nil; lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        failAll(CDPError.disconnected)
    }
}
```

- [ ] **Step 6: 전체 빌드+테스트 확인**

Run: `cd MacAgent && swift build && swift test`
Expected: 전부 통과

- [ ] **Step 7: Commit**

```bash
git add MacAgent && git commit -m "feat: CDP codec + WebSocket client (Runtime.evaluate, loopback only)"
```

---

### Task 4: YTMSelectors + BrowserController

**Files:**
- Create: `MacAgent/Sources/MacAgentCore/YTMSelectors.swift`
- Create: `MacAgent/Sources/MacAgentCore/BrowserController.swift`
- Test: `MacAgent/Tests/MacAgentTests/BrowserControllerTests.swift`

**Interfaces:**
- Consumes: `CDPClient.evaluate(_:) async throws -> String?` (Task 3)
- Produces:
  - `public struct YTMSnapshot: Decodable, Equatable { videoId: String, title: String, byline: String, paused: Bool, position: Double, duration: Double, hasVideo: Bool }`
  - `public protocol PlayerControlling { play/pause/next/previous() async throws; playTrack(videoId: String) async throws }` — ControlAPI(Task 6)가 이 프로토콜에 의존해 fake 주입 가능
  - `public final class BrowserController: PlayerControlling { public init(cdp: CDPClient); + snapshot() async throws -> YTMSnapshot; dismissYouTherePopup() async throws -> Bool }`
- YT Music DOM 셀렉터는 이 두 파일 밖에 존재하면 안 된다 (DOM 변경 시 수정 지점 단일화)

- [ ] **Step 1: 실패하는 테스트 작성** (스냅샷 파싱 — JS가 반환할 JSON 문자열 픽스처 기준)

```swift
// Tests/MacAgentTests/BrowserControllerTests.swift
import XCTest
@testable import MacAgentCore

final class BrowserControllerTests: XCTestCase {
    func testSnapshotDecodesFromPageJSON() throws {
        let fixture = #"{"videoId":"dQw4w9WgXcQ","title":"Song","byline":"Artist • Album • 2024","paused":false,"position":42.5,"duration":212.0,"hasVideo":true}"#
        let s = try JSONDecoder().decode(YTMSnapshot.self, from: Data(fixture.utf8))
        XCTAssertEqual(s.videoId, "dQw4w9WgXcQ")
        XCTAssertFalse(s.paused)
        XCTAssertTrue(s.hasVideo)
    }
    func testSnapshotEmptyPlayer() throws {
        let fixture = #"{"videoId":"","title":"","byline":"","paused":true,"position":0,"duration":0,"hasVideo":false}"#
        let s = try JSONDecoder().decode(YTMSnapshot.self, from: Data(fixture.utf8))
        XCTAssertFalse(s.hasVideo)
    }
    func testArtistExtractedFromByline() {
        // byline은 "Artist • Album • Year" 형태 — 첫 세그먼트만 artist로 쓴다
        XCTAssertEqual(YTMSnapshot.artist(fromByline: "Artist • Album • 2024"), "Artist")
        XCTAssertEqual(YTMSnapshot.artist(fromByline: ""), "")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd MacAgent && swift test --filter BrowserControllerTests`
Expected: 컴파일 실패

- [ ] **Step 3: YTMSelectors 구현** (JS 스니펫 전부 — Agent 내부 고정 문자열, spec §11)

```swift
// MacAgent/Sources/MacAgentCore/YTMSelectors.swift
import Foundation

/// YouTube Music DOM 접점 전부. 셀렉터가 깨지면 이 파일만 고친다.
/// 검증 방법: launch-chrome-ytm.sh로 띄운 뒤 DevTools 콘솔에서 각 스니펫 실행 (Task 7 체크포인트).
enum YTM {
    /// 상태 스냅샷 — JSON 문자열 반환
    static let snapshot = """
    (() => {
      const v = document.querySelector('video');
      const bar = document.querySelector('ytmusic-player-bar');
      const u = new URL(location.href);
      return JSON.stringify({
        videoId: u.pathname === '/watch' ? (u.searchParams.get('v') || '') : '',
        title: bar?.querySelector('.title')?.textContent?.trim() || '',
        byline: bar?.querySelector('.byline')?.textContent?.trim() || '',
        paused: v ? v.paused : true,
        position: v ? v.currentTime : 0,
        duration: v && isFinite(v.duration) ? v.duration : 0,
        hasVideo: !!v && !!bar
      });
    })()
    """

    /// 이미 재생 중이면 no-op (멱등)
    static let play = """
    (() => { const v = document.querySelector('video');
      if (v && v.paused) document.querySelector('#play-pause-button')?.click(); })()
    """

    static let pause = """
    (() => { const v = document.querySelector('video');
      if (v && !v.paused) document.querySelector('#play-pause-button')?.click(); })()
    """

    static let next = "document.querySelector('ytmusic-player-bar .next-button')?.click()"
    static let previous = "document.querySelector('ytmusic-player-bar .previous-button')?.click()"

    /// videoId는 호출 전에 ^[A-Za-z0-9_-]{1,64}$ 검증 필수 — JS 인젝션 표면 차단 (spec §11)
    static func playTrack(videoId: String) -> String {
        "location.href = 'https://music.youtube.com/watch?v=\(videoId)'"
    }

    /// "계속 시청하시겠어요?" 자동 일시정지 팝업 해제 — 눌렀으면 "true" 반환 (poc-results 백로그)
    static let dismissYouThere = """
    (() => {
      const d = document.querySelector('ytmusic-you-there-renderer');
      if (!d || d.offsetParent === null) return JSON.stringify(false);
      const b = d.querySelector('button');
      if (b) { b.click(); return JSON.stringify(true); }
      return JSON.stringify(false);
    })()
    """
}
```

- [ ] **Step 4: BrowserController 구현**

```swift
// MacAgent/Sources/MacAgentCore/BrowserController.swift
import Foundation

public struct YTMSnapshot: Decodable, Equatable {
    public let videoId: String
    public let title: String
    public let byline: String
    public let paused: Bool
    public let position: Double
    public let duration: Double
    public let hasVideo: Bool

    /// byline("Artist • Album • Year")에서 artist만 추출
    public static func artist(fromByline byline: String) -> String {
        byline.components(separatedBy: "•").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

public protocol PlayerControlling {
    func play() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func playTrack(videoId: String) async throws
}

public final class BrowserController: PlayerControlling {
    private let cdp: CDPClient
    public init(cdp: CDPClient) { self.cdp = cdp }

    /// 연결이 죽어 있으면 1회 재연결 후 재시도 (Chrome 재시작·탭 리로드 대응)
    private func eval(_ js: String) async throws -> String? {
        do { return try await cdp.evaluate(js) }
        catch { try await cdp.connect(); return try await cdp.evaluate(js) }
    }

    public func play() async throws { _ = try await eval(YTM.play) }
    public func pause() async throws { _ = try await eval(YTM.pause) }
    public func next() async throws { _ = try await eval(YTM.next) }
    public func previous() async throws { _ = try await eval(YTM.previous) }
    public func playTrack(videoId: String) async throws { _ = try await eval(YTM.playTrack(videoId: videoId)) }

    public func snapshot() async throws -> YTMSnapshot {
        guard let json = try await eval(YTM.snapshot),
              let snap = try? JSONDecoder().decode(YTMSnapshot.self, from: Data(json.utf8))
        else { throw CDPError.badResponse }
        return snap
    }

    @discardableResult
    public func dismissYouTherePopup() async throws -> Bool {
        try await eval(YTM.dismissYouThere) == "true"
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd MacAgent && swift test --filter BrowserControllerTests`
Expected: 3 tests passed

- [ ] **Step 6: Commit**

```bash
git add MacAgent && git commit -m "feat: YT Music selectors + BrowserController (fixed snippets, spec §11)"
```

---

### Task 5: PlayerStateService — 폴링·stateVersion·MARKER 분류

**Files:**
- Create: `MacAgent/Sources/MacAgentCore/PlayerStateService.swift`
- Test: `MacAgent/Tests/MacAgentTests/PlayerStateServiceTests.swift`

**Interfaces:**
- Consumes: `YTMSnapshot`(Task 4), `PlayerState`/`Marker`(YoutumuKit)
- Produces:
  - `public final class PlayerStateService { public init(); public var onTrackChange: ((Marker) -> Void)?; public func state() -> PlayerState; public func noteCommand(); func ingest(_ snap: YTMSnapshot, now: Date) -> Marker?; public func startPolling(controller: BrowserController) -> Task<Void, Never> }`
  - `ingest`는 internal — 테스트가 시간 주입으로 직접 호출. 폴링 루프는 라이브 검증(Task 7)
- MARKER cause 규칙: trackId 변경 && 마지막 명령 후 5초 이내 → `.command`(Watch가 버퍼 flush), 그 외 → `.natural`(flush 안 함, spec §6)

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Tests/MacAgentTests/PlayerStateServiceTests.swift
import XCTest
import YoutumuKit
@testable import MacAgentCore

final class PlayerStateServiceTests: XCTestCase {
    private func snap(id: String, paused: Bool = false, hasVideo: Bool = true) -> YTMSnapshot {
        YTMSnapshot(videoId: id, title: "T-\(id)", byline: "A • Al", paused: paused,
                    position: 0, duration: 100, hasVideo: hasVideo)
    }

    func testIngestBumpsVersionOnChange() {
        let s = PlayerStateService()
        let v0 = s.state().stateVersion
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        XCTAssertGreaterThan(s.state().stateVersion, v0)
        XCTAssertEqual(s.state().trackId, "a")
        XCTAssertEqual(s.state().playback, .playing)
    }

    func testIngestIdenticalSnapshotNoBump() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        let v = s.state().stateVersion
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(s.state().stateVersion, v)   // position은 상태 비교에서 제외
    }

    func testTrackChangeAfterCommandIsCommandCause() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        s.noteCommand(now: Date(timeIntervalSince1970: 10))
        let m = s.ingest(snap(id: "b"), now: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(m?.cause, .command)
        XCTAssertEqual(m?.trackId, "b")
    }

    func testTrackChangeWithoutCommandIsNatural() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        let m = s.ingest(snap(id: "b"), now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(m?.cause, .natural)
    }

    func testMarkerSeqIncreases() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0))
        let m1 = s.ingest(snap(id: "b"), now: Date(timeIntervalSince1970: 1))
        let m2 = s.ingest(snap(id: "c"), now: Date(timeIntervalSince1970: 2))
        XCTAssertLessThan(m1!.seq, m2!.seq)
    }

    func testFirstSnapshotEmitsNoMarker() {
        // 서버 기동 직후 "이미 재생 중이던 곡"은 전환이 아니다
        let s = PlayerStateService()
        XCTAssertNil(s.ingest(snap(id: "a"), now: Date(timeIntervalSince1970: 0)))
    }

    func testNoVideoMapsToStopped() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "", hasVideo: false), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(s.state().playback, .stopped)
    }

    func testPausedMapsToPaused() {
        let s = PlayerStateService()
        _ = s.ingest(snap(id: "a", paused: true), now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(s.state().playback, .paused)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd MacAgent && swift test --filter PlayerStateServiceTests`
Expected: 컴파일 실패

- [ ] **Step 3: 구현**

```swift
// MacAgent/Sources/MacAgentCore/PlayerStateService.swift
import Foundation
import YoutumuKit

/// 실제 YT Music 플레이어 상태가 Source of Truth (spec §8) — Mac에서 직접 조작해도 폴링으로 반영.
public final class PlayerStateService {
    private let lock = NSLock()
    private var current = PlayerState(stateVersion: 0, playback: .stopped, trackId: "",
                                      title: "", artist: "", positionSec: 0, durationSec: 0)
    private var lastCommandAt: Date?
    private var seenFirstSnapshot = false
    private var seq: UInt64 = 0
    private static let commandWindow: TimeInterval = 5   // 명령→전환 귀속 창 (spec §6 cause 분류)

    public var onTrackChange: ((Marker) -> Void)?

    public init() {}

    public func state() -> PlayerState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// 제어 명령 수락 시 ControlAPI가 호출 — 이후 5초 내 trackId 변경은 cause=.command
    public func noteCommand(now: Date = Date()) {
        lock.lock(); lastCommandAt = now; lock.unlock()
    }

    /// 스냅샷 반영. trackId가 바뀌면 Marker 반환 (position 변화만으로는 stateVersion을 올리지 않는다).
    func ingest(_ snap: YTMSnapshot, now: Date) -> Marker? {
        lock.lock(); defer { lock.unlock() }
        let playback: PlaybackState = !snap.hasVideo ? .stopped : (snap.paused ? .paused : .playing)
        let changed = snap.videoId != current.trackId || playback != current.playback
            || snap.title != current.title
        var marker: Marker?
        if seenFirstSnapshot, snap.videoId != current.trackId, !snap.videoId.isEmpty {
            seq += 1
            let cause: MarkerCause = (lastCommandAt.map { now.timeIntervalSince($0) <= Self.commandWindow } ?? false)
                ? .command : .natural
            marker = Marker(seq: seq, trackId: snap.videoId, cause: cause)
        }
        current = PlayerState(
            stateVersion: changed ? current.stateVersion + 1 : current.stateVersion,
            playback: playback, trackId: snap.videoId, title: snap.title,
            artist: YTMSnapshot.artist(fromByline: snap.byline),
            positionSec: snap.position, durationSec: snap.duration)
        seenFirstSnapshot = true
        if let marker { onTrackChangeLocked(marker) }
        return marker
    }

    private func onTrackChangeLocked(_ m: Marker) {
        let cb = onTrackChange
        DispatchQueue.global().async { cb?(m) }   // lock 밖에서 콜백 (broadcast가 NIO로 홉)
    }

    /// 1초 폴링 + 5초마다 자동 일시정지 팝업 점검. CDP가 죽어 있으면 5초 간격 재시도.
    @discardableResult
    public func startPolling(controller: BrowserController) -> Task<Void, Never> {
        Task {
            var tick = 0
            while !Task.isCancelled {
                do {
                    let snap = try await controller.snapshot()
                    _ = ingest(snap, now: Date())
                    if tick % 5 == 0, try await controller.dismissYouTherePopup() {
                        print("YT Music you-there 팝업 자동 해제")
                    }
                    try? await Task.sleep(for: .seconds(1))
                } catch {
                    try? await Task.sleep(for: .seconds(5))   // Chrome 미기동 등 — 조용히 재시도
                }
                tick += 1
            }
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd MacAgent && swift test --filter PlayerStateServiceTests`
Expected: 8 tests passed

- [ ] **Step 5: Commit**

```bash
git add MacAgent && git commit -m "feat: PlayerStateService — polling state, stateVersion, marker cause (spec §6·§8·§22)"
```

---

### Task 6: ControlAPI — REST 라우팅·검증·멱등성

**Files:**
- Create: `MacAgent/Sources/MacAgentCore/ControlAPI.swift`
- Modify: `MacAgent/Sources/MacAgentCore/StreamServer.swift` (바디 수집 + /api dispatch)
- Test: `MacAgent/Tests/MacAgentTests/ControlAPITests.swift`

**Interfaces:**
- Consumes: `CommandStore`(T2), `PlayerStateService.state()/noteCommand()`(T5), `PlayerControlling`(T4)
- Produces:
  - `public struct ApiRequest { method: String, path: String, body: Data }`
  - `public struct ApiResponse { status: Int, body: Data }` (Content-Type은 항상 application/json)
  - `public final class ControlAPI { public init(store: CommandStore, svc: PlayerStateService, controller: PlayerControlling); public func handle(_ req: ApiRequest) async -> ApiResponse }`
  - `StreamServer`에 `public var api: ControlAPI?` 추가
- 라우트(allow-list — 이 외 전부 404, spec §11):
  - `GET  /api/player` → 200 PlayerState JSON
  - `POST /api/player/play|pause|next|previous` → body `{"commandId":"<uuid>"}` 정확히 1필드
  - `POST /api/player/tracks/{trackId}` → trackId `^[A-Za-z0-9_-]{1,64}$`
  - 응답: 200 `CommandResponse`, 400 잘못된 요청(재시도 무의미), 502 브라우저 실행 실패(reconcile 대상), 413 body 초과

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Tests/MacAgentTests/ControlAPITests.swift
import XCTest
import YoutumuKit
@testable import MacAgentCore

private final class FakeController: PlayerControlling {
    var calls: [String] = []
    var shouldThrow = false
    private func rec(_ s: String) throws { calls.append(s); if shouldThrow { throw CDPError.disconnected } }
    func play() async throws { try rec("play") }
    func pause() async throws { try rec("pause") }
    func next() async throws { try rec("next") }
    func previous() async throws { try rec("previous") }
    func playTrack(videoId: String) async throws { try rec("track:\(videoId)") }
}

final class ControlAPITests: XCTestCase {
    private var fake: FakeController!
    private var api: ControlAPI!

    override func setUp() {
        fake = FakeController()
        api = ControlAPI(store: CommandStore(), svc: PlayerStateService(), controller: fake)
    }

    private func post(_ path: String, _ body: String) async -> ApiResponse {
        await api.handle(ApiRequest(method: "POST", path: path, body: Data(body.utf8)))
    }
    private var okBody: String { #"{"commandId":"\#(UUID().uuidString)"}"# }

    func testGetPlayerReturnsStateJSON() async throws {
        let r = await api.handle(ApiRequest(method: "GET", path: "/api/player", body: Data()))
        XCTAssertEqual(r.status, 200)
        _ = try JSONDecoder().decode(PlayerState.self, from: r.body)
    }

    func testNextExecutesAndReturnsCommandResponse() async throws {
        let r = await post("/api/player/next", okBody)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(fake.calls, ["next"])
        let cr = try JSONDecoder().decode(CommandResponse.self, from: r.body)
        XCTAssertFalse(cr.duplicate)
    }

    func testDuplicateCommandIdNotReExecuted() async throws {
        let id = UUID().uuidString
        let body = #"{"commandId":"\#(id)"}"#
        _ = await post("/api/player/next", body)
        let r2 = await post("/api/player/next", body)
        XCTAssertEqual(fake.calls, ["next"])          // 1회만 실행 (spec §5)
        let cr = try JSONDecoder().decode(CommandResponse.self, from: r2.body)
        XCTAssertTrue(cr.duplicate)
    }

    func testMissingCommandIdRejected400() async {
        let r = await post("/api/player/play", "{}")
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testNonUUIDCommandIdRejected400() async {
        let r = await post("/api/player/play", #"{"commandId":"nope"}"#)
        XCTAssertEqual(r.status, 400)
    }

    func testUnknownFieldRejected400() async {
        // 정의되지 않은 필드는 무시가 아니라 거부 (spec §11)
        let r = await post("/api/player/play", #"{"commandId":"\#(UUID().uuidString)","js":"x"}"#)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testValidTrackIdExecutes() async {
        let r = await post("/api/player/tracks/dQw4w9WgXcQ", okBody)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(fake.calls, ["track:dQw4w9WgXcQ"])
    }

    func testInvalidTrackIdRejected400() async {
        let r = await post("/api/player/tracks/bad%2Fid!", okBody)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testUnknownPathRejected404() async {
        let r = await post("/api/execute", okBody)
        XCTAssertEqual(r.status, 404)
    }

    func testControllerFailureReturns502AndNotCached() async {
        fake.shouldThrow = true
        let id = UUID().uuidString
        let body = #"{"commandId":"\#(id)"}"#
        let r1 = await post("/api/player/next", body)
        XCTAssertEqual(r1.status, 502)               // 실행 여부 불명 → reconcile (spec §5)
        fake.shouldThrow = false
        let r2 = await post("/api/player/next", body)
        XCTAssertEqual(r2.status, 200)               // 실패는 캐시되지 않아 재시도 가능
        XCTAssertEqual(fake.calls, ["next", "next"])
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd MacAgent && swift test --filter ControlAPITests`
Expected: 컴파일 실패

- [ ] **Step 3: ControlAPI 구현**

```swift
// MacAgent/Sources/MacAgentCore/ControlAPI.swift
import Foundation
import YoutumuKit

public struct ApiRequest {
    public let method: String
    public let path: String
    public let body: Data
    public init(method: String, path: String, body: Data) {
        self.method = method; self.path = path; self.body = body
    }
}

public struct ApiResponse {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
    static func error(_ status: Int, _ msg: String) -> ApiResponse {
        ApiResponse(status: status, body: try! JSONEncoder().encode(["error": msg]))
    }
}

/// mTLS 뒤에서도 애플리케이션 계층이 한 번 더 막는다 (spec §11 심층 방어).
public final class ControlAPI {
    private let store: CommandStore
    private let svc: PlayerStateService
    private let controller: PlayerControlling
    private static let trackIdPattern = /^[A-Za-z0-9_-]{1,64}$/   // spec §11

    public init(store: CommandStore, svc: PlayerStateService, controller: PlayerControlling) {
        self.store = store; self.svc = svc; self.controller = controller
    }

    public func handle(_ req: ApiRequest) async -> ApiResponse {
        switch (req.method, req.path) {
        case ("GET", "/api/player"):
            return ApiResponse(status: 200, body: try! JSONEncoder().encode(svc.state()))
        case ("POST", "/api/player/play"):     return await command(req) { try await self.controller.play() }
        case ("POST", "/api/player/pause"):    return await command(req) { try await self.controller.pause() }
        case ("POST", "/api/player/next"):     return await command(req) { try await self.controller.next() }
        case ("POST", "/api/player/previous"): return await command(req) { try await self.controller.previous() }
        case ("POST", let p) where p.hasPrefix("/api/player/tracks/"):
            let trackId = String(p.dropFirst("/api/player/tracks/".count))
            guard trackId.wholeMatch(of: Self.trackIdPattern) != nil else {
                return .error(400, "invalid trackId")
            }
            return await command(req) { try await self.controller.playTrack(videoId: trackId) }
        default:
            return .error(404, "unknown endpoint")   // allow-list 외 전부 거부
        }
    }

    private func command(_ req: ApiRequest, _ exec: () async throws -> Void) async -> ApiResponse {
        // body는 정확히 {"commandId": "<uuid>"} — 정의되지 않은 필드는 거부 (spec §11)
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              obj.count == 1,
              let id = obj["commandId"] as? String,
              UUID(uuidString: id) != nil else {
            return .error(400, "body must be exactly {\"commandId\": \"<uuid>\"}")
        }
        if let dup = store.cached(id) {
            return ApiResponse(status: 200, body: try! JSONEncoder().encode(dup))   // 재실행 없음 (spec §5)
        }
        do { try await exec() } catch {
            return .error(502, "browser control failed")   // 실행 여부 불명 — 캐시하지 않음
        }
        svc.noteCommand()
        let resp = CommandResponse(stateVersion: svc.state().stateVersion, duplicate: false)
        store.record(id, resp)
        return ApiResponse(status: 200, body: try! JSONEncoder().encode(resp))
    }
}
```

- [ ] **Step 4: StreamServer에 /api dispatch 추가** — Handler를 바디 수집형으로 교체

`StreamServer.swift`에서: 클래스에 `public var api: ControlAPI?` 프로퍼티 추가, `Handler.channelRead`를 아래로 교체.

```swift
// StreamServer 클래스 본문에 추가
public var api: ControlAPI?

// Handler 교체 (기존 channelRead 대체)
private final class Handler: ChannelInboundHandler {
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
            let req = ApiRequest(method: h.method.rawValue, path: h.uri, body: body)
            let ch = context.channel
            let api = server.api
            Task {   // BrowserController가 async — NIO 이벤트 루프를 막지 않는다
                let resp = await api?.handle(req) ?? ApiResponse(status: 404, body: Data(#"{"error":"unknown endpoint"}"#.utf8))
                self.writeJSON(ch, status: .init(statusCode: resp.status), body: resp.body)
            }
        }
    }

    private func writeJSON(_ ch: Channel, status: HTTPResponseStatus, body: Data) {
        ch.eventLoop.execute {
            var hdr = HTTPHeaders()
            hdr.add(name: "Content-Type", value: "application/json")
            hdr.add(name: "Content-Length", value: "\(body.count)")
            ch.write(HTTPServerResponsePart.head(.init(version: .http1_1, status: status, headers: hdr)), promise: nil)
            var buf = ch.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            ch.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
            ch.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        }
    }
}
```

- [ ] **Step 5: 테스트 통과 + 전체 회귀 확인**

Run: `cd MacAgent && swift test`
Expected: ControlAPITests 10개 포함 전부 통과

- [ ] **Step 6: Commit**

```bash
git add MacAgent && git commit -m "feat: ControlAPI REST routing with allow-list, validation, idempotency (spec §5·§11)"
```

---

### Task 7: serve 통합 + Chrome 실행 스크립트 + Caddy body 제한 + 라이브 체크포인트

**Files:**
- Modify: `MacAgent/Sources/MacAgent/main.swift` (serve case)
- Create: `scripts/launch-chrome-ytm.sh`
- Modify: `infra/Caddyfile`

**Interfaces:**
- Consumes: Task 2~6의 모든 public 타입
- Produces: 동작하는 `MacAgent serve` — 오디오 스트림 + REST 제어 + 실제 MARKER. 이후 Watch(Task 8)가 이 API를 소비

- [ ] **Step 1: serve case를 CDP·API 배선으로 교체** (stdin 'm' 주입기는 실제 MARKER로 대체·삭제)

```swift
case "serve":
    let server = StreamServer(port: 8080)
    let cap = ChromeAudioCapture()
    var enc: AACEncoder?
    cap.onPCM = { pcm in
        if enc == nil { enc = AACEncoder(inputFormat: pcm.format) }
        for frame in enc?.encode(pcm) ?? [] {
            server.broadcast(Envelope.encode(type: .audio, payload: frame))
        }
    }
    let cdp = CDPClient()
    let controller = BrowserController(cdp: cdp)
    let svc = PlayerStateService()
    server.api = ControlAPI(store: CommandStore(), svc: svc, controller: controller)
    svc.onTrackChange = { m in
        server.broadcast(Envelope.encodeMarker(m))    // 실제 곡 전환 → 스트림 MARKER (spec §6)
        print("MARKER seq=\(m.seq) cause=\(m.cause.rawValue) track=\(m.trackId)")
    }
    Task {
        try await cap.start()
        try? await cdp.connect()                      // Chrome 미기동이면 폴링 루프가 재시도
        svc.startPolling(controller: controller)
        print("streaming + control API ready (CDP \(  (try? await controller.snapshot()) != nil ? "connected" : "retrying"))")
    }
    try server.run()
```

- [ ] **Step 2: Chrome 실행 스크립트 작성**

```bash
#!/bin/bash
# 원격 제어 전용 Chrome 프로필 실행 (spec §11 — 개인 세션과 격리, CDP는 127.0.0.1만)
# 최초 1회: 열린 창에서 Google 로그인 → music.youtube.com 재생 확인
set -euo pipefail
PROFILE="$HOME/.youtumu-chrome"
open -na "Google Chrome" --args \
  --remote-debugging-port=9222 \
  --user-data-dir="$PROFILE" \
  --no-first-run \
  "https://music.youtube.com"
```

Save as `scripts/launch-chrome-ytm.sh`, then: `chmod +x scripts/launch-chrome-ytm.sh`

주의(코드 주석으로도 남김): SCK 캡처는 bundle id(com.google.Chrome) 기준이므로 개인 Chrome 창의 소리도 함께 캡처된다 — 스트리밍 중에는 개인 창에서 오디오 재생을 피한다 (완전 분리는 Phase 3에서 검토).

- [ ] **Step 3: Caddyfile에 request body 제한 추가** — `https://:8443` 사이트 블록 안, `tls` 지시자 다음에:

```
    request_body {
        max_size 16KB
    }
```

- [ ] **Step 4: 빌드 + 로컬 API 검증 (Caddy 우회, Agent 직접)**

```bash
cd MacAgent && swift build && swift test
```

사용자 체크포인트 안내 (serve는 사용자 Terminal.app에서 실행 — TCC 유지):
1. `./scripts/launch-chrome-ytm.sh` 실행 → 열린 창에서 Google 로그인(최초 1회) → YT Music에서 아무 곡 재생
2. 기존 serve 중지 후 재시작: `cd MacAgent && swift run MacAgent serve`
3. 로컬 검증 (Mac에서):

```bash
curl -s http://127.0.0.1:8080/api/player | python3 -m json.tool
```
Expected: 현재 재생 곡의 trackId/title/artist/playback=playing, stateVersion > 0

```bash
curl -s -X POST http://127.0.0.1:8080/api/player/next -d "{\"commandId\":\"$(uuidgen)\"}"
```
Expected: `{"stateVersion":N,"duplicate":false}` + Chrome이 다음 곡으로 넘어감 + serve 로그에 `MARKER seq=1 cause=command` + (스트림 청취 중이면) Watch/iPhone에서 곡 전환

4. 같은 commandId로 재요청 → `duplicate: true` + 곡 안 넘어감
5. 검증 실패 시: DevTools(전용 Chrome에서 F12) 콘솔에 `YTMSelectors.swift`의 스니펫을 붙여 셀렉터 확인 — 깨진 셀렉터는 YTMSelectors.swift만 수정

- [ ] **Step 5: 외부 경로 검증 (Caddy 경유 mTLS)** — Watch Task 8에서 함께 하거나, 즉시 확인하려면 iPhone/Watch 대신 Caddy 재시작 후 iPhone 앱 Play로 스트림 회귀 확인

```bash
# Caddy 재시작 (infra/ 디렉터리에서)
caddy validate --config infra/Caddyfile --adapter caddyfile
```
Expected: Valid configuration → Caddy 재시작

- [ ] **Step 6: Commit**

```bash
git add MacAgent scripts/launch-chrome-ytm.sh infra/Caddyfile
git commit -m "feat: wire CDP control into serve, chrome launch script, caddy body limit"
```

---

### Task 8: Watch 제어 UI — 버튼 + Now Playing

**Files:**
- Create: `watch/YoutumuWatch Watch App/ApiClient.swift`
- Modify: `watch/YoutumuWatch Watch App/ContentView.swift`

**Interfaces:**
- Consumes: `PlayerState`/`CommandResponse`(YoutumuKit, Task 2), `PinnedSessionDelegate`(기존 EnrollClient.swift 내), Task 7의 REST API
- Produces: Watch 화면에서 ⏯/⏮/⏭ 제어 + 곡 제목 표시. Phase 5 정식 UI의 선행 검증 (optimistic UI 없음 — 응답 후 갱신만)

- [ ] **Step 1: ApiClient 작성**

```swift
// watch/YoutumuWatch Watch App/ApiClient.swift
import Foundation
import YoutumuKit

/// 제어 REST 호출 — 스트림과 동일한 CA 핀닝 세션 (spec §5 Control Plane)
enum ApiClient {
    private static let delegate = PinnedSessionDelegate()
    private static let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    static func post(host: String, path: String) async throws -> CommandResponse {
        var req = URLRequest(url: URL(string: "https://\(host):8443\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["commandId": UUID().uuidString])
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CommandResponse.self, from: data)
    }

    static func player(host: String) async throws -> PlayerState {
        var req = URLRequest(url: URL(string: "https://\(host):8443/api/player")!)
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(PlayerState.self, from: data)
    }
}
```

전제: `PinnedSessionDelegate`가 internal이면 그대로 사용 가능 (같은 타깃). 파일 위치만 확인.

- [ ] **Step 2: ContentView에 제어 행 + now playing 추가**

Playback 섹션의 `Text("Marker: ...")` 위에 삽입:

```swift
HStack(spacing: 8) {
    Button("⏮") { control("/api/player/previous") }
    Button(playerState?.playback == .playing ? "⏸" : "▶") {
        control(playerState?.playback == .playing ? "/api/player/pause" : "/api/player/play")
    }
    Button("⏭") { control("/api/player/next") }
}
Text(nowPlaying).font(.footnote).lineLimit(2)
```

`@State` 추가 및 헬퍼 (struct 본문에):

```swift
@State private var playerState: PlayerState?
private var nowPlaying: String {
    guard let s = playerState, !s.title.isEmpty else { return "-" }
    return "\(s.title) — \(s.artist)"
}

private func control(_ path: String) {
    Task {
        do {
            _ = try await ApiClient.post(host: serverHost, path: path)
            await refreshPlayer()   // 응답 후 상태 갱신 (optimistic UI는 Phase 5)
        } catch {
            await MainActor.run { playStatus = "ctrl err: \(error.localizedDescription)" }
        }
    }
}

private func refreshPlayer() async {
    // stateVersion이 낮은 응답으로 최신 상태를 덮지 않는다 (spec §5 응답 역전 방지)
    if let s = try? await ApiClient.player(host: serverHost) {
        await MainActor.run {
            if s.stateVersion >= (playerState?.stateVersion ?? 0) { playerState = s }
        }
    }
}
```

기존 5초 ticker의 `.onReceive` 클로저 끝에 한 줄 추가:

```swift
Task { await refreshPlayer() }
```

- [ ] **Step 3: 빌드 확인**

Run: `cd watch && xcodegen generate && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 실기기 설치 + 체크포인트** (Phase 0과 동일 절차: 서명 빌드 → devicectl로 페어링된 iPhone 경유 설치)

사용자 확인 항목:
1. Watch에서 ⏭ 탭 → Mac Chrome 곡 전환 + 듣던 스트림이 ~1초 내 새 곡으로 flush (MARKER cause=command 경로)
2. 곡 제목이 Watch 화면에 표시
3. Mac에서 직접 곡을 바꿔도 (폴링 주기 내) Watch 표시 갱신 — Source of Truth 검증 (spec §8)
4. 곡이 자연 종료로 넘어갈 때는 소리 안 끊김 (cause=natural — flush 없음)

- [ ] **Step 5: Commit**

```bash
git add watch && git commit -m "feat: watch control buttons + now playing via /api/player (spec §5·§22)"
```

---

## Phase 1 완료 기준

- [ ] `swift test` 전부 통과 (신규 ~30 테스트)
- [ ] curl: GET /api/player가 실제 재생 상태 반영, POST 명령 4종+track 동작, 중복 commandId 재실행 없음, 미정의 엔드포인트/필드 400·404
- [ ] Watch에서 Play/Pause/Next/Previous/곡 제목 확인
- [ ] 곡 전환 시 실제 MARKER가 스트림에 주입되고 cause 분류가 맞음 (command=flush됨, natural=이어짐)
- [ ] YT Music you-there 팝업이 자동 해제됨 (장시간 재생 중 확인 — 강제 유발 어려우면 셀렉터 존재만 DevTools로 확인하고 G5 soak에서 실증)

## Self-Review 기록

- 스펙 커버리지: §5 Control Plane(POST 5종+GET player ✓; playlists/queue는 Phase 2 명시), §5 멱등성(commandId ✓, stateVersion ✓, 409는 queue와 함께 Phase 2 — Out of Scope에 명시), §8 지원 명령(Play/Pause/Next/Previous/Track ✓; Playlist/Queue는 Phase 2), §11(allow-list ✓, trackId 검증 ✓, 미정의 필드·엔드포인트 거부 ✓, body 양쪽 제한 ✓, CDP loopback ✓, 전용 프로필 ✓)
- 타입 일관성: `CommandResponse{stateVersion,duplicate}`·`PlayerState`·`YTMSnapshot`·`PlayerControlling` 시그니처를 태스크 간 대조 완료. Task 6 테스트의 `YTMSnapshot` memberwise init은 `@testable import`로 internal init 접근 — Decodable struct는 memberwise init이 internal로 합성되므로 가능
- 알려진 리스크: YT Music DOM 셀렉터는 실측 전 미확정 — Task 7 체크포인트에서 DevTools로 검증하는 절차와 단일 수정 지점(YTMSelectors.swift)을 마련함. `swift-tools 5.9` regex 리터럴(`/…/`)은 macOS 13+ 타깃에서 사용 가능(플랫폼 macOS 14 ✓)

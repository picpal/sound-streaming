# Phase 5 — watchOS UI (Playlists / Detail / Now Playing / Queue / Crown Volume / 오류 상태) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 개발용 단일 ContentView를 spec §15–§22의 실사용 UI로 교체한다 — Playlists → Playlist 상세 → Now Playing(+Queue) 네비게이션, Crown 볼륨, optimistic UI, 오류 상태.

**Architecture:** 순수 상태 로직(optimistic overlay reconcile, 시작 라우트 결정, 연결 상태 축)은 YoutumuKit에 넣어 XCTest로 검증하고(Watch 앱에는 테스트 타깃이 없음), Watch 앱에는 `PlayerModel`(@MainActor ObservableObject) 하나가 폴링·명령·optimistic 적용·스트림 수명을 관장한다. 화면은 NavigationStack 4개 View로 구성하며, artwork는 `/api/artwork/{id}` 프록시를 NSCache로 감싼 ArtworkStore가 공급한다. Mac 서버 변경은 GET /api/player에서 현재 곡 artwork 등록 2줄뿐이다.

**Tech Stack:** SwiftUI(NavigationStack, watchOS 9 호환 — @Observable 사용 금지, ObservableObject/@Published), digitalCrownRotation, AVAudioEngine mainMixer 볼륨, XCTest(YoutumuKit·MacAgent), xcodegen.

**Spec:** `apple_watch_youtube_music_remote_player_design.md` — §15(Navigation·시작 라우트), §16(Playlists), §17(Playlist 상세), §18(Now Playing·Crown Volume), §19(Queue), §20(네트워크 상태 UX), §21(Optimistic UI), §22(상태 모델), §23 Phase 5 정의.

## Global Constraints

(spec에서 그대로 — 모든 태스크에 암묵 적용)

- Black background, System typography, SF Symbols, 큰 Touch Target, 한 화면 한 목적, Navigation depth ≤ 3 (§디자인 방향)
- 정상 상태에서 네트워크 기술 정보(LTE/mTLS/AAC/RTT) 미노출 — 오류만 표시 (§20)
- 연결과 재생 축 분리: ControlLinkState(ok|degraded|down) / AudioStreamState(disconnected|connecting|streaming|stalled) / PlaybackState / OutputRoute (§22)
- `volume`은 Watch 로컬 출력 볼륨(Crown 제어) — 서버 상태에 속하지 않는다 (§22)
- Optimistic 전환: 즉시 화면 반영 → POST → 실패 시 **마지막으로 확인된 서버 상태**로 rollback. stateVersion 비교로 reconcile (§21·§22)
- stateVersion이 낮은 폴링 응답으로 최신 상태를 덮지 않는다 (§5, 기존 ContentView 규약 유지)
- Watch 소스는 iOS 타깃(YoutumuPhone)과 공유 — watchOS 전용 API는 `#if os(watchOS)` 가드 (기존 관례)
- SWIFT_VERSION 6.0 / watchOS deploymentTarget 9.0 — @Observable·Observation 프레임워크 금지, 새 클래스는 @MainActor로 격리
- Watch는 URL/JS를 전송하지 않는다 — 기존 ApiClient 경로 문자열은 고정 리터럴 + path 파라미터는 서버가 검증 (spec §11)
- 파일 추가 후에는 `cd watch && xcodegen generate`로 프로젝트 재생성 (sources는 폴더 단위 포함이라 yml 수정 불요)
- Watch 빌드 게이트: `cd watch && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build` 성공
- 커밋은 태스크 단위, 테스트(해당 시)·빌드 통과 후

## 설계 결정 (계획 수준 ruling)

1. **순수 로직은 YoutumuKit으로**: Watch 프로젝트에 테스트 타깃이 없으므로 reconcile/라우트 결정/링크 상태 판정을 YoutumuKit(`WatchPlayback.swift`)에 두고 XCTest로 검증한다. UI 자체는 빌드 게이트 + T9 실기기 체크포인트로 검증.
2. **Overlay 해소 규칙**: 서버 `stateVersion > overlay.baseStateVersion`이면 서버가 명령 이후 상태를 반영한 것이므로 overlay 해제. `appliedAt + 5초` 경과에도 서버가 안 따라오면 timeout 해제(= 마지막 확인된 서버 상태로 rollback 표시). POST 실패 시 즉시 해제 + 오류 배너.
3. **Crown 볼륨은 mainMixer(앱 로컬)**: `engine.mainMixerNode.outputVolume` 0.0–1.0. 시스템 볼륨 API는 watchOS에서 제한적이고, §22가 "Watch 로컬 출력 볼륨"으로 규정.
4. **Now Playing artwork 공급**: 서버 GET /api/player 처리 시 현재 trackId를 ArtworkService에 등록(2줄) — 라디오 재생 등 라이브러리 밖 곡도 artwork 표시. 미등록/404는 음표 placeholder.
5. **오디오 스트림 자동 연결**: 앱 시작 시 그리고 재생 명령 시 스트림이 disconnected면 자동 start. 수동 Play/Stop 버튼(개발용)은 제거. Stop은 두지 않는다 — 앱 이탈/시스템이 관리 (한 화면 한 목적).
6. **Enrollment 게이트**: KeyStore.identity()가 nil이면 EnrollView만 표시(네비게이션 밖). 기존 개발용 metrics·수동 host 입력은 삭제 — host는 `youtumu.duckdns.org` 상수(설정 화면 YAGNI, git 이력에 남음).
7. **폴링 주기 2초**(앱 활성 시). ADR '§PoC 후 확정' 항목이며 배터리 실측은 T9에서 관찰.
8. **Playlist 상세 페이지네이션 미사용**: limit=200 1회 호출(개인 플레이리스트 ≤50곡 실측). offset UI는 YAGNI.
9. **Queue jump 409 처리**: 409 수신 시 큐 재조회 + "큐가 바뀌었어요" 배너, 자동 재시도 없음 (사용자가 새 큐에서 다시 탭).
10. **iOS 타깃(YoutumuPhone)은 컴파일만 보장** — crown·WK API는 `#if os(watchOS)` 가드. iOS UX 최적화는 범위 밖.

## Out of Scope (이 계획에서 하지 않음)

- seek/progress bar (§18 "초기 버전 필수 아님"), 곡별 좋아요/메뉴 (§17)
- WebSocket push, 자동 재접속·stalled 복구 로직 — Phase 6 (AudioStreamState.stalled 값은 정의만)
- OutputRoute 표시·route change 대응 — poc-results 백로그 (Phase 5 후속)
- 서버 재시작 시 Watch 자동 재연결 — Phase 6
- 곡 전환 latency p95 측정 — Phase 6 (§24-7)

## File Structure

| 파일 | 책임 |
|---|---|
| `YoutumuKit/Sources/YoutumuKit/WatchPlayback.swift` (신규) | ControlLinkState/AudioStreamState/StartRoute/OptimisticOverlay + Reconcile 순수 함수 |
| `YoutumuKit/Tests/YoutumuKitTests/WatchPlaybackTests.swift` (신규) | reconcile·라우트·링크 판정 테스트 |
| `MacAgent/Sources/MacAgentCore/ControlAPI.swift` (수정 2줄) | GET /api/player에서 현재 trackId artwork 등록 |
| `MacAgent/Tests/MacAgentTests/ControlAPILibraryTests.swift` (수정) | 위 등록 검증 1건 |
| `watch/YoutumuWatch Watch App/ApiClient.swift` (수정) | 라이브러리 GET/POST 6종 + ApiError(status) + artwork fetch |
| `watch/YoutumuWatch Watch App/StreamPlayer.swift` (수정) | `volume` 프로퍼티, `isConnected` 노출 |
| `watch/YoutumuWatch Watch App/PlayerModel.swift` (신규) | 폴링·명령·optimistic·큐·링크 상태·스트림 수명 (@MainActor ObservableObject) |
| `watch/YoutumuWatch Watch App/ArtworkStore.swift` (신규) | artwork 캐시(NSCache) + `ArtworkView` |
| `watch/YoutumuWatch Watch App/NowPlayingView.swift` (신규) | §18 화면 + Crown 볼륨 + Connecting 오버레이 + Queue 링크 |
| `watch/YoutumuWatch Watch App/PlaylistsView.swift` (신규) | §16 목록 |
| `watch/YoutumuWatch Watch App/PlaylistDetailView.swift` (신규) | §17 상세 (전체 재생 + 트랙 행) |
| `watch/YoutumuWatch Watch App/QueueView.swift` (신규) | §19 큐 |
| `watch/YoutumuWatch Watch App/EnrollView.swift` (신규) | 기존 enrollment UI 이식 |
| `watch/YoutumuWatch Watch App/ContentView.swift` (교체) | RootView: enrollment 게이트 + 시작 라우트 + §20 오류 화면 |

**Interfaces 요약 (태스크 간 계약):**

```swift
// YoutumuKit (T1)
public enum ControlLinkState: Equatable { case ok, degraded, down }        // §22
public enum AudioStreamState: Equatable { case disconnected, connecting, streaming, stalled }
public enum StartRoute: Equatable { case nowPlaying, playlists
    public static func decide(_ state: PlayerState?) -> StartRoute }       // §15: playing → nowPlaying
public struct OptimisticOverlay: Equatable {
    public var playback: PlaybackState?
    public var title: String?
    public var artist: String?
    public var baseStateVersion: UInt64
    public var appliedAt: Date
    public init(playback: PlaybackState?, title: String?, artist: String?,
                baseStateVersion: UInt64, appliedAt: Date)
}
public enum Reconcile {
    public struct Display: Equatable { public let title, artist: String; public let playback: PlaybackState }
    /// overlay가 살아있으면 overlay 우선 표시, 서버가 따라잡거나(stateVersion 증가) 5초 timeout이면 해제
    public static func resolve(server: PlayerState?, overlay: OptimisticOverlay?, now: Date)
        -> (display: Display, overlay: OptimisticOverlay?)
    /// 연속 실패 횟수 → 링크 상태 (0 = ok, 1–2 = degraded, 3+ = down)
    public static func linkState(consecutiveFailures: Int) -> ControlLinkState
}

// ApiClient 추가 (T2)
struct ApiError: Error, Equatable { let status: Int }                       // 409 식별용
static func playlists(host: String) async throws -> [PlaylistSummary]
static func playlistTracks(host: String, id: String) async throws -> PlaylistPage   // limit=200 고정
static func queue(host: String) async throws -> QueueSnapshot
static func playPlaylist(host: String, id: String) async throws -> CommandResponse
static func playTrack(host: String, id: String) async throws -> CommandResponse
static func jumpQueue(host: String, position: Int, stateVersion: UInt64) async throws -> CommandResponse
static func artwork(host: String, id: String) async throws -> Data

// StreamPlayer 추가 (T3)
var volume: Float { get set }          // mainMixer 0.0–1.0
var isConnected: Bool { get }          // task 활성 여부

// PlayerModel (T3) — 모든 View가 소비
@MainActor final class PlayerModel: ObservableObject {
    @Published private(set) var display: Reconcile.Display
    @Published private(set) var serverState: PlayerState?
    @Published private(set) var queue: QueueSnapshot?
    @Published private(set) var link: ControlLinkState
    @Published private(set) var stream: AudioStreamState
    @Published var banner: String?                       // 일시 오류 배너 (nil = 없음)
    let host: String                                     // "youtumu.duckdns.org"
    let player: StreamPlayer
    func startPolling()
    func stopPolling()
    func ensureStream()                                  // disconnected면 /audio/live 연결
    func togglePlayPause()                               // optimistic
    func next()                                          // optimistic (queue에서 다음 곡 메타)
    func previous()
    func playTrack(id: String, title: String, artist: String)      // optimistic
    func playPlaylist(id: String)
    func refreshQueue() async
    func jumpQueue(to position: Int) async               // 409 → 큐 재조회 + banner
}

// ArtworkStore (T4)
@MainActor final class ArtworkStore: ObservableObject {
    static let shared: ArtworkStore
    func image(id: String, host: String) async -> CGImage?   // 실패/404 → nil (placeholder)
}
struct ArtworkView: View { let id: String; let size: CGFloat }   // 음표 placeholder 내장
```

---

### Task 1: YoutumuKit — WatchPlayback 상태 로직

**Files:**
- Create: `YoutumuKit/Sources/YoutumuKit/WatchPlayback.swift`
- Test: `YoutumuKit/Tests/YoutumuKitTests/WatchPlaybackTests.swift`

**Interfaces:**
- Consumes: `PlayerState`/`PlaybackState` (기존 YoutumuKit)
- Produces: 위 Interfaces 요약의 YoutumuKit 블록 전부 — T3 PlayerModel·T8 RootView가 소비

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import YoutumuKit

final class WatchPlaybackTests: XCTestCase {
    private func state(_ sv: UInt64, _ playback: PlaybackState = .playing,
                       title: String = "Song A", artist: String = "Artist A") -> PlayerState {
        PlayerState(stateVersion: sv, playback: playback, trackId: "t1",
                    title: title, artist: artist, positionSec: 0, durationSec: 100)
    }

    // §15 시작 라우트
    func testStartRoutePlayingGoesNowPlaying() {
        XCTAssertEqual(StartRoute.decide(state(1, .playing)), .nowPlaying)
    }
    func testStartRouteOtherwisePlaylists() {
        XCTAssertEqual(StartRoute.decide(state(1, .paused)), .playlists)
        XCTAssertEqual(StartRoute.decide(state(1, .stopped)), .playlists)
        XCTAssertEqual(StartRoute.decide(nil), .playlists)
    }

    // §21 overlay 우선 표시
    func testOverlayWinsWhileActive() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let ov = OptimisticOverlay(playback: .playing, title: "Next Song", artist: "B",
                                   baseStateVersion: 10, appliedAt: t0)
        let r = Reconcile.resolve(server: state(10), overlay: ov, now: t0.addingTimeInterval(1))
        XCTAssertEqual(r.display.title, "Next Song")
        XCTAssertEqual(r.display.playback, .playing)
        XCTAssertNotNil(r.overlay)
    }

    // §22 서버가 따라잡으면 해제 (stateVersion 증가)
    func testOverlayClearedWhenServerCatchesUp() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let ov = OptimisticOverlay(playback: nil, title: "Next Song", artist: "B",
                                   baseStateVersion: 10, appliedAt: t0)
        let r = Reconcile.resolve(server: state(11, .playing, title: "Next Song", artist: "B"),
                                  overlay: ov, now: t0.addingTimeInterval(1))
        XCTAssertNil(r.overlay)
        XCTAssertEqual(r.display.title, "Next Song")   // 이제 서버 값
    }

    // §21 rollback: timeout 시 마지막 확인된 서버 상태로
    func testOverlayTimeoutRollsBackToServer() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let ov = OptimisticOverlay(playback: .playing, title: "Next Song", artist: "B",
                                   baseStateVersion: 10, appliedAt: t0)
        let r = Reconcile.resolve(server: state(10, .paused), overlay: ov,
                                  now: t0.addingTimeInterval(5.1))
        XCTAssertNil(r.overlay)
        XCTAssertEqual(r.display.title, "Song A")
        XCTAssertEqual(r.display.playback, .paused)
    }

    // overlay 일부 필드만 있는 경우 나머지는 서버 값
    func testPartialOverlayFallsThroughToServer() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let ov = OptimisticOverlay(playback: .paused, title: nil, artist: nil,
                                   baseStateVersion: 10, appliedAt: t0)
        let r = Reconcile.resolve(server: state(10, .playing), overlay: ov, now: t0)
        XCTAssertEqual(r.display.title, "Song A")
        XCTAssertEqual(r.display.playback, .paused)
    }

    // 서버 nil (첫 폴링 전): overlay 없으면 빈 표시
    func testNilServerShowsEmptyStopped() {
        let r = Reconcile.resolve(server: nil, overlay: nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r.display, Reconcile.Display(title: "", artist: "", playback: .stopped))
    }

    // §22 링크 상태 판정
    func testLinkStateThresholds() {
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 0), .ok)
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 1), .degraded)
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 2), .degraded)
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 3), .down)
        XCTAssertEqual(Reconcile.linkState(consecutiveFailures: 9), .down)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd YoutumuKit && swift test 2>&1 | tail -5`
Expected: 컴파일 실패 — `cannot find 'StartRoute' in scope` 등

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Watch 클라이언트 상태 로직 (spec §15·§21·§22). 서버와 무관한 순수 함수 — Watch 앱에 테스트
/// 타깃이 없어 여기서 XCTest로 검증한다.

public enum ControlLinkState: Equatable { case ok, degraded, down }          // §22 REST 연결 축
public enum AudioStreamState: Equatable { case disconnected, connecting, streaming, stalled }

/// §15 앱 시작 라우트: 재생 중이면 Now Playing 직행, 아니면 Playlists.
public enum StartRoute: Equatable {
    case nowPlaying, playlists
    public static func decide(_ state: PlayerState?) -> StartRoute {
        state?.playback == .playing ? .nowPlaying : .playlists
    }
}

/// §21 optimistic 전환의 화면 오버레이. 서버가 따라잡거나 timeout이면 해제된다.
public struct OptimisticOverlay: Equatable {
    public var playback: PlaybackState?
    public var title: String?
    public var artist: String?
    public var baseStateVersion: UInt64      // 적용 시점의 서버 stateVersion
    public var appliedAt: Date
    public init(playback: PlaybackState?, title: String?, artist: String?,
                baseStateVersion: UInt64, appliedAt: Date) {
        self.playback = playback; self.title = title; self.artist = artist
        self.baseStateVersion = baseStateVersion; self.appliedAt = appliedAt
    }
}

public enum Reconcile {
    public struct Display: Equatable {
        public let title: String
        public let artist: String
        public let playback: PlaybackState
        public init(title: String, artist: String, playback: PlaybackState) {
            self.title = title; self.artist = artist; self.playback = playback
        }
    }

    static let overlayTimeout: TimeInterval = 5   // §21: 이 시간 내 서버 미반영이면 rollback

    /// 실제 Player State가 최종 Source of Truth (§21) — overlay는 표시용 임시 상태일 뿐이다.
    public static func resolve(server: PlayerState?, overlay: OptimisticOverlay?, now: Date)
        -> (display: Display, overlay: OptimisticOverlay?) {
        let base = Display(title: server?.title ?? "", artist: server?.artist ?? "",
                           playback: server?.playback ?? .stopped)
        guard let ov = overlay else { return (base, nil) }
        let caughtUp = (server?.stateVersion ?? 0) > ov.baseStateVersion
        let timedOut = now.timeIntervalSince(ov.appliedAt) > overlayTimeout
        if caughtUp || timedOut { return (base, nil) }   // 해제 — timeout이면 결과적으로 rollback
        return (Display(title: ov.title ?? base.title,
                        artist: ov.artist ?? base.artist,
                        playback: ov.playback ?? base.playback), ov)
    }

    /// §22 ControlLinkState: 폴링 연속 실패 0회 ok / 1–2회 degraded / 3회+ down.
    public static func linkState(consecutiveFailures: Int) -> ControlLinkState {
        switch consecutiveFailures {
        case 0: return .ok
        case 1, 2: return .degraded
        default: return .down
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd YoutumuKit && swift test 2>&1 | tail -3`
Expected: 전체 PASS (기존 6 + 신규 8)

- [ ] **Step 5: Commit**

```bash
git add YoutumuKit/Sources/YoutumuKit/WatchPlayback.swift YoutumuKit/Tests/YoutumuKitTests/WatchPlaybackTests.swift
git commit -m "feat: watch playback state logic (route/overlay reconcile/link state)"
```

---

### Task 2: 서버 — 현재 곡 artwork 등록 + Watch ApiClient 라이브러리 호출

**Files:**
- Modify: `MacAgent/Sources/MacAgentCore/ControlAPI.swift` (GET /api/player 케이스)
- Modify: `MacAgent/Tests/MacAgentTests/ControlAPILibraryTests.swift` (테스트 1건 추가)
- Modify: `watch/YoutumuWatch Watch App/ApiClient.swift`

**Interfaces:**
- Consumes: Phase 2 라우트 6종(GET /api/playlists, GET /api/playlists/{id}, GET /api/queue, POST /api/player/playlists/{id}, POST /api/queue/{position}, GET /api/artwork/{id}), Phase 1 POST /api/player/tracks/{id}
- Produces: ApiClient 시그니처 7종 + `ApiError` (Interfaces 요약 참조) — T3·T4가 소비. GET /api/player가 현재 trackId를 artwork에 등록 — T4 NowPlaying artwork가 의존

- [ ] **Step 1: ArtworkService에 등록 조회 추가 + 서버 테스트 (failing)**

`ArtworkService`는 `public final class`라 스파이 서브클래싱이 불가하다. 대신 등록 여부를 물을 수 있는 internal 조회를 추가한다 (`ArtworkService.swift`, `registerTrack` 아래 — 기존 lock 관례에 맞춰 lock 잡고 조회):

```swift
    /// 테스트·진단용 — id가 서빙 가능 상태(등록됨)인지. @testable 경유로만 쓴다.
    func isRegistered(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return urls[id] != nil
    }
```

(실제 파일의 등록 저장소 프로퍼티명이 `urls`가 아니면 그 이름에 맞춘다 — 의미는 "register/registerTrack이 기록하는 dict 조회".)

`ControlAPILibraryTests.swift`에 추가 — 파일의 기존 setUp 구성(mock library·ControlAPI 생성부)을 그대로 따라 ArtworkService 인스턴스를 변수로 보관하고:

```swift
func testPlayerStateRegistersCurrentTrackArtwork() async throws {
    // setUp이 만든 api/artwork 인스턴스 사용. svc mock의 현재 trackId를 tid로 둔다
    // (기존 테스트가 PlayerStateService를 어떻게 시딩하는지 따라간다 — ingest로 스냅샷 주입).
    _ = await api.handle(ApiRequest(method: "GET", path: "/api/player", body: Data()))
    XCTAssertTrue(artwork.isRegistered(id: tid))
}
```

주의: 기존 setUp이 artwork 인스턴스를 지역 생성해 보관하지 않으면 프로퍼티로 승격한다. 검증 대상은 고정 — **GET /api/player 처리 후 현재 trackId가 등록되어 있어야 한다** (빈 trackId면 미등록).

- [ ] **Step 2: Run — verify fail**

Run: `cd MacAgent && swift test --filter ControlAPILibraryTests 2>&1 | tail -5`
Expected: FAIL (registered == [])

- [ ] **Step 3: 서버 구현 — GET /api/player 케이스에 등록 추가**

`ControlAPI.swift`의 기존:

```swift
        case ("GET", "/api/player"):
            return ApiResponse(status: 200, body: try! JSONEncoder().encode(svc.state()))
```

를 다음으로:

```swift
        case ("GET", "/api/player"):
            let s = svc.state()
            if !s.trackId.isEmpty { artwork.registerTrack(id: s.trackId) }   // Now Playing artwork 공급 (§18)
            return ApiResponse(status: 200, body: try! JSONEncoder().encode(s))
```

- [ ] **Step 4: Run — verify pass + full suite**

Run: `cd MacAgent && swift test 2>&1 | grep -E "Executed|error:" | tail -2`
Expected: 전체 PASS (70/70)

- [ ] **Step 5: Watch ApiClient 확장**

`ApiClient.swift`를 다음 전체 내용으로 교체:

```swift
import Foundation
import YoutumuKit

/// 4xx/5xx 식별용 (409 큐 경합 등). 200 외 상태는 전부 이 오류로 던진다.
struct ApiError: Error, Equatable { let status: Int }

/// 제어 REST 호출 — 스트림과 동일한 CA 핀닝 세션 (spec §5 Control Plane)
enum ApiClient {
    private static let delegate = PinnedSessionDelegate()
    private static let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    // MARK: 공용 요청 헬퍼

    private static func get<T: Decodable>(host: String, path: String) async throws -> T {
        var req = URLRequest(url: URL(string: "https://\(host):8443\(path)")!)
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw ApiError(status: code) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func postJSON(host: String, path: String, body: [String: Any]) async throws -> CommandResponse {
        var req = URLRequest(url: URL(string: "https://\(host):8443\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw ApiError(status: code) }
        return try JSONDecoder().decode(CommandResponse.self, from: data)
    }

    // MARK: Phase 1 제어 (기존 시그니처 유지 — ContentView가 사용)

    static func post(host: String, path: String) async throws -> CommandResponse {
        try await postJSON(host: host, path: path, body: ["commandId": UUID().uuidString])
    }

    static func player(host: String) async throws -> PlayerState {
        try await get(host: host, path: "/api/player")
    }

    // MARK: Phase 5 라이브러리 (Phase 2 라우트 소비)

    static func playlists(host: String) async throws -> [PlaylistSummary] {
        try await get(host: host, path: "/api/playlists")
    }

    static func playlistTracks(host: String, id: String) async throws -> PlaylistPage {
        try await get(host: host, path: "/api/playlists/\(id)?offset=0&limit=200")
    }

    static func queue(host: String) async throws -> QueueSnapshot {
        try await get(host: host, path: "/api/queue")
    }

    static func playPlaylist(host: String, id: String) async throws -> CommandResponse {
        try await post(host: host, path: "/api/player/playlists/\(id)")
    }

    static func playTrack(host: String, id: String) async throws -> CommandResponse {
        try await post(host: host, path: "/api/player/tracks/\(id)")
    }

    static func jumpQueue(host: String, position: Int, stateVersion: UInt64) async throws -> CommandResponse {
        try await postJSON(host: host, path: "/api/queue/\(position)",
                           body: ["commandId": UUID().uuidString, "stateVersion": stateVersion])
    }

    static func artwork(host: String, id: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://\(host):8443/api/artwork/\(id)")!)
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw ApiError(status: code) }
        return data
    }
}
```

- [ ] **Step 6: Watch 빌드 게이트**

Run: `cd watch && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add MacAgent/Sources/MacAgentCore/ControlAPI.swift MacAgent/Tests/MacAgentTests/ControlAPILibraryTests.swift "watch/YoutumuWatch Watch App/ApiClient.swift"
git commit -m "feat: library api client + current-track artwork registration"
```

---

### Task 3: StreamPlayer volume/isConnected + PlayerModel

**Files:**
- Modify: `watch/YoutumuWatch Watch App/StreamPlayer.swift`
- Create: `watch/YoutumuWatch Watch App/PlayerModel.swift`

**Interfaces:**
- Consumes: T1 `Reconcile`/`OptimisticOverlay`/`StartRoute`/`ControlLinkState`/`AudioStreamState`, T2 ApiClient 7종, 기존 StreamPlayer(onMarker/onEnded/onRemoteCommand/start/stop/updateNowPlaying)
- Produces: Interfaces 요약의 `PlayerModel` 전체 + StreamPlayer `volume`/`isConnected` — T4~T8 모든 View가 소비

- [ ] **Step 1: StreamPlayer에 volume·isConnected 추가**

`StreamPlayer.swift`의 `var onRemoteCommand:` 선언 근처에 추가:

```swift
    /// Crown 볼륨 (§18·§22 — Watch 로컬 출력, 서버 상태 아님)
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }
    var isConnected: Bool { task != nil && started }
```

주의: `started` 플래그는 엔진 시작 여부다. 실제 파일에서 task 상태와 가장 잘 맞는 기존 프로퍼티를 확인해 사용하고(없으면 `task?.state == .running` 대신 `task != nil`만), 의미는 "스트림 연결 시도 이후 stop 전"이면 된다.

- [ ] **Step 2: PlayerModel 작성**

```swift
import Foundation
import SwiftUI
import YoutumuKit

/// 화면 전체가 공유하는 단일 플레이어 모델 (§21·§22).
/// 폴링(2s) → reconcile → display 갱신. 명령은 optimistic 적용 후 POST, 실패 시 overlay 해제(=rollback).
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var display = Reconcile.Display(title: "", artist: "", playback: .stopped)
    @Published private(set) var serverState: PlayerState?
    @Published private(set) var queue: QueueSnapshot?
    @Published private(set) var link: ControlLinkState = .ok
    @Published private(set) var stream: AudioStreamState = .disconnected
    @Published var banner: String?

    let host = "youtumu.duckdns.org"     // NAT loopback 확인 → 내외부 단일 주소 (Phase 3 확정)
    let player = StreamPlayer()

    private var overlay: OptimisticOverlay?
    private var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?

    init() {
        player.onEnded = { [weak self] _ in
            Task { @MainActor in self?.stream = .disconnected }
        }
        player.onRemoteCommand = { [weak self] cmd in     // AirPods 스템/시스템 컨트롤 위임 (Phase 1)
            Task { @MainActor in
                switch cmd {
                case .play: self?.togglePlayPause()
                case .pause: self?.togglePlayPause()
                case .next: self?.next()
                case .previous: self?.previous()
                }
            }
        }
    }

    // MARK: 폴링 (§22 PlaybackState 축)

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() async {
        do {
            let s = try await ApiClient.player(host: host)
            consecutiveFailures = 0
            // stateVersion 낮은 응답으로 덮지 않는다 (§5)
            if s.stateVersion >= (serverState?.stateVersion ?? 0) { serverState = s }
            player.updateNowPlaying(title: display.title, artist: display.artist)
        } catch {
            consecutiveFailures += 1
        }
        link = Reconcile.linkState(consecutiveFailures: consecutiveFailures)
        applyReconcile()
    }

    private func applyReconcile(now: Date = Date()) {
        let r = Reconcile.resolve(server: serverState, overlay: overlay, now: now)
        display = r.display
        overlay = r.overlay
    }

    // MARK: 오디오 스트림 (§22 AudioStreamState 축)

    func ensureStream() {
        guard stream == .disconnected else { return }
        stream = .connecting
        Task {
            do {
                try await player.start(url: URL(string: "https://\(host):8443/audio/live")!)
                stream = .streaming
            } catch {
                stream = .disconnected
                banner = "오디오 연결 실패"
            }
        }
    }

    // MARK: 명령 (§21 optimistic)

    private func applyOverlay(playback: PlaybackState?, title: String?, artist: String?) {
        overlay = OptimisticOverlay(playback: playback, title: title, artist: artist,
                                    baseStateVersion: serverState?.stateVersion ?? 0, appliedAt: Date())
        applyReconcile()
    }

    private func send(_ path: String) {
        Task {
            do { _ = try await ApiClient.post(host: host, path: path) }
            catch {
                overlay = nil                            // rollback → 마지막 확인된 서버 상태 (§21)
                applyReconcile()
                banner = "명령 실패"
            }
        }
    }

    func togglePlayPause() {
        let playing = display.playback == .playing
        applyOverlay(playback: playing ? .paused : .playing, title: nil, artist: nil)
        send(playing ? "/api/player/pause" : "/api/player/play")
        if !playing { ensureStream() }
    }

    func next() {
        let meta = adjacentQueueMeta(offset: +1)
        applyOverlay(playback: .playing, title: meta?.title, artist: meta?.artist)
        send("/api/player/next")
    }

    func previous() {
        let meta = adjacentQueueMeta(offset: -1)
        applyOverlay(playback: .playing, title: meta?.title, artist: meta?.artist)
        send("/api/player/previous")
    }

    /// §21 Next: queue에서 인접 곡 메타를 즉시 표시
    private func adjacentQueueMeta(offset: Int) -> QueueItem? {
        guard let items = queue?.items,
              let cur = items.firstIndex(where: { $0.current }) else { return nil }
        let idx = cur + offset
        return items.indices.contains(idx) ? items[idx] : nil
    }

    func playTrack(id: String, title: String, artist: String) {
        applyOverlay(playback: .playing, title: title, artist: artist)
        ensureStream()
        Task {
            do { _ = try await ApiClient.playTrack(host: host, id: id) }
            catch { overlay = nil; applyReconcile(); banner = "재생 실패" }
        }
    }

    func playPlaylist(id: String) {
        applyOverlay(playback: .playing, title: nil, artist: nil)
        ensureStream()
        Task {
            do { _ = try await ApiClient.playPlaylist(host: host, id: id) }
            catch { overlay = nil; applyReconcile(); banner = "재생 실패" }
        }
    }

    // MARK: Queue (§19)

    func refreshQueue() async {
        queue = try? await ApiClient.queue(host: host)
    }

    func jumpQueue(to position: Int) async {
        guard let sv = queue?.stateVersion else { return }
        if let item = queue?.items.first(where: { $0.position == position }) {
            applyOverlay(playback: .playing, title: item.title, artist: item.artist)
        }
        do { _ = try await ApiClient.jumpQueue(host: host, position: position, stateVersion: sv) }
        catch let e as ApiError where e.status == 409 {
            overlay = nil; applyReconcile()
            banner = "큐가 바뀌었어요"
            await refreshQueue()                          // 새 큐 표시, 자동 재시도 없음 (설계 결정 9)
        } catch { overlay = nil; applyReconcile(); banner = "명령 실패" }
    }
}
```

- [ ] **Step 3: 빌드 게이트**

Run: `cd watch && xcodegen generate && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED` (ContentView는 아직 구버전 그대로 — PlayerModel은 추가만)

- [ ] **Step 4: Commit**

```bash
git add "watch/YoutumuWatch Watch App/StreamPlayer.swift" "watch/YoutumuWatch Watch App/PlayerModel.swift" watch/YoutumuWatch.xcodeproj
git commit -m "feat: PlayerModel (polling/optimistic/queue/stream axes) + crown volume hook"
```

---

### Task 4: ArtworkStore + ArtworkView

**Files:**
- Create: `watch/YoutumuWatch Watch App/ArtworkStore.swift`

**Interfaces:**
- Consumes: T2 `ApiClient.artwork(host:id:)`
- Produces: `ArtworkStore.shared.image(id:host:)`, `ArtworkView(id:size:)` — T5·T6이 소비 (T7 Queue는 §19에 artwork 없음)

- [ ] **Step 1: 구현**

```swift
import SwiftUI
import YoutumuKit

/// /api/artwork/{id} 프록시의 클라이언트 캐시 (§9 — 서버가 128px JPEG로 리사이즈 완료).
/// 404(미등록)·실패는 nil → placeholder. 재시도는 화면 재진입 시 자연 발생 (in-flight dedup은 YAGNI).
@MainActor
final class ArtworkStore: ObservableObject {
    static let shared = ArtworkStore()
    private let cache = NSCache<NSString, CGImageBox>()
    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    func image(id: String, host: String) async -> CGImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit.image }
        guard let data = try? await ApiClient.artwork(host: host, id: id),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cache.setObject(CGImageBox(img), forKey: id as NSString)
        return img
    }
}

/// artwork 사각형 — 로드 전/실패 시 음표 placeholder (§16·§18)
struct ArtworkView: View {
    let id: String
    let size: CGFloat
    @EnvironmentObject private var model: PlayerModel
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
        .task(id: id) {
            guard !id.isEmpty else { image = nil; return }
            image = await ArtworkStore.shared.image(id: id, host: model.host)
        }
    }
}
```

`CGImageSourceCreateWithData`는 `ImageIO` — 파일 상단 import에 `import ImageIO` 추가 (watchOS 지원).

- [ ] **Step 2: 빌드 게이트**

Run: `cd watch && xcodegen generate && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add "watch/YoutumuWatch Watch App/ArtworkStore.swift" watch/YoutumuWatch.xcodeproj
git commit -m "feat: artwork cache + placeholder view"
```

---

### Task 5: NowPlayingView (§18) + Crown 볼륨 + Connecting 오버레이 (§20)

**Files:**
- Create: `watch/YoutumuWatch Watch App/NowPlayingView.swift`

**Interfaces:**
- Consumes: T3 PlayerModel(display/stream/togglePlayPause/next/previous/ensureStream, player.volume), T4 ArtworkView
- Produces: `NowPlayingView` (NavigationLink로 QueueView 연결 — QueueView는 T7에서 생성되므로 이 태스크에서는 링크 자리에 `EmptyView` 대신 **QueueView를 참조하지 않고** toolbar 버튼을 T7에서 붙인다)

- [ ] **Step 1: 구현**

```swift
import SwiftUI
import YoutumuKit

/// §18 — 가장 중요한 화면. artwork 중심, Play/Pause가 Primary, Crown은 볼륨.
struct NowPlayingView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var crownVolume: Double = 0.7

    var body: some View {
        VStack(spacing: 6) {
            ArtworkView(id: model.serverState?.trackId ?? "", size: 70)

            Text(model.display.title.isEmpty ? "—" : model.display.title)
                .font(.headline).lineLimit(1)
            Text(model.display.artist)
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)

            if model.stream == .connecting {
                Text("Connecting…").font(.footnote).foregroundStyle(.secondary)   // §20
            }

            HStack(spacing: 14) {
                Button { model.previous() } label: { Image(systemName: "backward.fill") }
                    .buttonStyle(.plain)
                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.display.playback == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))                                   // Primary Action (§18)
                }
                .buttonStyle(.plain)
                Button { model.next() } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(.plain)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        #if os(watchOS)
        .focusable(true)
        .digitalCrownRotation($crownVolume, from: 0, through: 1, by: 0.05,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownVolume) { v in model.player.volume = Float(v) }        // §18 Crown → 로컬 볼륨
        #endif
        .onAppear {
            crownVolume = Double(model.player.volume)
            model.ensureStream()                                                  // 설계 결정 5
            Task { await model.refreshQueue() }                                   // §21 Next 메타 준비
        }
    }
}
```

- [ ] **Step 2: 빌드 게이트**

Run: `cd watch && xcodegen generate && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add "watch/YoutumuWatch Watch App/NowPlayingView.swift" watch/YoutumuWatch.xcodeproj
git commit -m "feat: now playing screen (artwork/controls/crown volume/connecting)"
```

---

### Task 6: PlaylistsView (§16) + PlaylistDetailView (§17)

**Files:**
- Create: `watch/YoutumuWatch Watch App/PlaylistsView.swift`
- Create: `watch/YoutumuWatch Watch App/PlaylistDetailView.swift`

**Interfaces:**
- Consumes: T2 ApiClient.playlists/playlistTracks, T3 PlayerModel.playPlaylist/playTrack, T4 ArtworkView
- Produces: `PlaylistsView`, `PlaylistDetailView(playlist: PlaylistSummary)` — T8 네비게이션이 소비. 트랙 탭 → `model.playTrack` + NowPlaying push는 **NavigationLink가 아니라** 탭 액션 + `model` 상태로 T8 루트가 처리하도록 `onPlay: () -> Void` 콜백을 받는다

- [ ] **Step 1: PlaylistsView**

```swift
import SwiftUI
import YoutumuKit

/// §16 — artwork 행 목록. Crown 스크롤은 List 기본 동작.
struct PlaylistsView: View {
    @EnvironmentObject private var model: PlayerModel
    let onPlay: () -> Void                                  // 재생 시작 → NowPlaying push (T8)
    @State private var playlists: [PlaylistSummary]?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let playlists {
                List(playlists, id: \.playlistId) { p in
                    NavigationLink(value: p) {
                        HStack(spacing: 8) {
                            ArtworkView(id: p.playlistId, size: 36)
                            VStack(alignment: .leading) {
                                Text(p.title).font(.body).lineLimit(1)
                                Text("\(p.trackCount)곡").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if loadFailed {
                ErrorRetryView { await load() }              // §20 — T8에서 정의
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Playlists")
        .task { await load() }
    }

    private func load() async {
        loadFailed = false
        do { playlists = try await ApiClient.playlists(host: model.host) }
        catch { loadFailed = true }
    }
}
```

주의: `ErrorRetryView`는 T8에서 만들지만 이 태스크의 빌드가 깨지므로 **이 태스크에서 함께 생성**한다 (아래 Step 2) — T8 Interfaces에도 명시.

- [ ] **Step 2: ErrorRetryView (§20 Mac 연결 실패 패턴 재사용)**

`PlaylistsView.swift` 하단에 추가:

```swift
/// §20 오류 상태 — 정상일 땐 절대 보이지 않는다.
struct ErrorRetryView: View {
    let retry: () async -> Void
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.title3)
            Text("Mac에 연결할 수 없습니다.").font(.footnote).multilineTextAlignment(.center)
            Button("재시도") { Task { await retry() } }
        }
    }
}
```

- [ ] **Step 3: PlaylistDetailView**

```swift
import SwiftUI
import YoutumuKit

/// §17 — artwork 없는 고밀도 트랙 목록 + 전체 재생. Row 전체가 Touch Target.
struct PlaylistDetailView: View {
    @EnvironmentObject private var model: PlayerModel
    let playlist: PlaylistSummary
    let onPlay: () -> Void
    @State private var page: PlaylistPage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let page {
                List {
                    Button {
                        model.playPlaylist(id: playlist.playlistId)
                        onPlay()
                    } label: {
                        Label("전체 재생", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(page.items.enumerated()), id: \.offset) { i, t in
                        Button {
                            guard !t.unavailable, !t.trackId.isEmpty else { return }
                            model.playTrack(id: t.trackId, title: t.title, artist: t.artist)   // §21 즉시 전환
                            onPlay()
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Text(String(format: "%02d", i + 1))
                                    .font(.footnote).foregroundStyle(.tertiary)
                                VStack(alignment: .leading) {
                                    Text(t.title).font(.body).lineLimit(1)
                                    Text(t.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .opacity(t.unavailable ? 0.4 : 1)
                        }
                        .disabled(t.unavailable)
                    }
                }
            } else if loadFailed {
                ErrorRetryView { await load() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(playlist.title)
        .task { await load() }
    }

    private func load() async {
        loadFailed = false
        do { page = try await ApiClient.playlistTracks(host: model.host, id: playlist.playlistId) }
        catch { loadFailed = true }
    }
}
```

- [ ] **Step 4: 빌드 게이트** — `PlaylistSummary`가 NavigationLink value로 쓰이려면 `Hashable` 필요. YoutumuKit `Library.swift`의 `PlaylistSummary` 선언에 `Hashable` 채택 추가(`Codable, Equatable, Hashable`) 후:

Run: `cd YoutumuKit && swift test 2>&1 | tail -2 && cd ../watch && xcodegen generate && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build 2>&1 | tail -3`
Expected: YoutumuKit 테스트 PASS + `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add "watch/YoutumuWatch Watch App/PlaylistsView.swift" "watch/YoutumuWatch Watch App/PlaylistDetailView.swift" YoutumuKit/Sources/YoutumuKit/Library.swift watch/YoutumuWatch.xcodeproj
git commit -m "feat: playlists + playlist detail screens"
```

---

### Task 7: QueueView (§19)

**Files:**
- Create: `watch/YoutumuWatch Watch App/QueueView.swift`
- Modify: `watch/YoutumuWatch Watch App/NowPlayingView.swift` (toolbar에 Queue 진입 추가)

**Interfaces:**
- Consumes: T3 PlayerModel.queue/refreshQueue/jumpQueue, T5 NowPlayingView
- Produces: `QueueView` — NowPlaying toolbar에서 push (§15 depth 3)

- [ ] **Step 1: QueueView**

```swift
import SwiftUI
import YoutumuKit

/// §19 — 현재 곡 표시 + 탭 즉시 이동. artwork 없음.
struct QueueView: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let q = model.queue {
                List(q.items, id: \.position) { item in
                    Button {
                        Task {
                            await model.jumpQueue(to: item.position)
                            dismiss()                       // §19 "즉시 이동" — Now Playing으로 복귀
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                                .opacity(item.current ? 1 : 0)   // ▶ 현재 곡 마커
                            VStack(alignment: .leading) {
                                Text(item.title).font(.body).lineLimit(1)
                                Text(item.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Playing Next")
        .task { await model.refreshQueue() }
    }
}
```

- [ ] **Step 2: NowPlayingView에 Queue 진입 추가**

`NowPlayingView`의 `.navigationBarTitleDisplayMode(.inline)` 아래에:

```swift
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { QueueView() } label: { Image(systemName: "list.bullet") }
            }
        }
```

- [ ] **Step 3: 빌드 게이트**

Run: `cd watch && xcodegen generate && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add "watch/YoutumuWatch Watch App/QueueView.swift" "watch/YoutumuWatch Watch App/NowPlayingView.swift" watch/YoutumuWatch.xcodeproj
git commit -m "feat: queue screen with jump + 409 recovery"
```

---

### Task 8: RootView — enrollment 게이트 + 시작 라우트 + 오류 화면 + 배너

**Files:**
- Create: `watch/YoutumuWatch Watch App/EnrollView.swift`
- Modify: `watch/YoutumuWatch Watch App/ContentView.swift` (전체 교체)

**Interfaces:**
- Consumes: T1 StartRoute, T3 PlayerModel, T5–T7 View 4종, 기존 EnrollClient/KeyStore
- Produces: 최종 앱 진입 구조 — `YoutumuWatchApp`은 기존대로 `ContentView()`를 띄우므로 앱 파일 수정 없음

- [ ] **Step 1: EnrollView (기존 ContentView의 enrollment 섹션 이식)**

```swift
import SwiftUI

/// LAN 1회 등록 (spec §10) — identity가 없을 때만 표시.
struct EnrollView: View {
    let onEnrolled: () -> Void
    @State private var mac = "172.30.1.15"
    @State private var code = ""
    @State private var status = ""

    var body: some View {
        ScrollView { VStack(spacing: 8) {
            Text("등록").font(.headline)
            TextField("Mac LAN IP", text: $mac)
            TextField("code", text: $code)
            Button("Enroll") {
                Task {
                    do {
                        if try await EnrollClient.enroll(macAddr: mac, code: code) {
                            status = "완료"; onEnrolled()
                        } else { status = "실패" }
                    } catch { status = "오류: \(error.localizedDescription)" }
                }
            }
            Text(status).font(.footnote)
        }.padding() }
    }
}
```

- [ ] **Step 2: ContentView 전체 교체 (RootView 역할)**

```swift
import SwiftUI
import YoutumuKit

/// 앱 루트: enrollment 게이트 → 시작 라우트 결정(§15) → NavigationStack.
/// 정상 상태에서는 연결 정보를 보여주지 않는다 (§20).
struct ContentView: View {
    @StateObject private var model = PlayerModel()
    @State private var enrolled = KeyStore.identity() != nil
    @State private var path = NavigationPath()
    @State private var routed = false

    private enum Route: Hashable { case nowPlaying }

    var body: some View {
        if !enrolled {
            EnrollView { enrolled = true }
        } else {
            NavigationStack(path: $path) {
                PlaylistsView(onPlay: { pushNowPlaying() })
                    .navigationDestination(for: PlaylistSummary.self) { p in
                        PlaylistDetailView(playlist: p, onPlay: { pushNowPlaying() })
                    }
                    .navigationDestination(for: Route.self) { _ in NowPlayingView() }
            }
            .overlay(alignment: .bottom) {
                if let msg = model.banner {
                    Text(msg).font(.footnote).padding(6)
                        .background(.red.opacity(0.8), in: Capsule())
                        .task { try? await Task.sleep(for: .seconds(2)); model.banner = nil }
                }
            }
            .overlay {
                if model.link == .down {                      // §20 Mac 연결 실패 — 전면 오류만
                    ZStack {
                        Rectangle().fill(.black)
                        ErrorRetryView { model.startPolling() }
                    }
                }
            }
            .environmentObject(model)
            .task {
                model.startPolling()
                // §15: 첫 상태 확인 후 재생 중이면 Now Playing 직행 (1회만)
                for _ in 0..<10 where model.serverState == nil {
                    try? await Task.sleep(for: .seconds(1))
                }
                if !routed {
                    routed = true
                    if StartRoute.decide(model.serverState) == .nowPlaying { pushNowPlaying() }
                }
            }
        }
    }

    private func pushNowPlaying() {
        if path.isEmpty || path.count >= 0 { path.append(Route.nowPlaying) }
    }
}
```

주의: `pushNowPlaying`의 중복 push 방지가 필요하면 `path`의 마지막이 이미 `.nowPlaying`인지 추적하는 `@State private var onNowPlaying = false`를 쓰되, NavigationPath는 내용 검사가 안 되므로 NowPlayingView의 `onAppear/onDisappear`로 갱신한다. 구현 시 가장 단순한 동작 방식(중복 push 허용 여부)을 택하고 T9 실기기에서 확인.

- [ ] **Step 3: 빌드 게이트 (watchOS + iOS 타깃 둘 다)**

Run: `cd watch && xcodegen generate && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build 2>&1 | tail -3 && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuPhone" -destination "generic/platform=iOS" -allowProvisioningUpdates build 2>&1 | tail -3`
Expected: 두 타깃 모두 `BUILD SUCCEEDED` (iOS 쪽 crown API 등 가드 확인)

- [ ] **Step 4: Commit**

```bash
git add "watch/YoutumuWatch Watch App/EnrollView.swift" "watch/YoutumuWatch Watch App/ContentView.swift" watch/YoutumuWatch.xcodeproj
git commit -m "feat: root navigation (enroll gate, start route, error overlay)"
```

---

### Task 9: 실기기 체크포인트

**Files:**
- Modify: `status.json` (결과 기록)
- Modify: `docs/poc-results.md` (관찰 기록 — 있을 때만)

**Interfaces:**
- Consumes: 전부

- [ ] **Step 1: 설치**

전제: Mac serve 실행 중(사용자 Terminal.app — 디스플레이 깨운 상태에서 시작), Caddy 실행 중, Watch가 잠금 해제·착용 상태.

```bash
cd watch && xcodebuild -project YoutumuWatch.xcodeproj -scheme "YoutumuWatch Watch App" -destination "generic/platform=watchOS" -allowProvisioningUpdates build
xcrun devicectl device install app --device C9DE6B2F-62EE-57C8-8AF1-045BFB812831 "/Users/picpal/Library/Developer/Xcode/DerivedData/YoutumuWatch-bgamrzqmrusovgfxehwgbtzhdykz/Build/Products/Debug-watchos/YoutumuWatch Watch App.app"
```

- [ ] **Step 2: 사용자 확인 체크리스트 (Watch 실조작 — 사용자 협조 필요)**

각 항목 실패 시 해당 View/PlayerModel 수정 후 재설치:

1. 앱 시작: Mac에서 재생 중이면 Now Playing 직행 / 정지 상태면 Playlists (§15)
2. Playlists: 19개 목록 + artwork(또는 placeholder) 표시, Crown 스크롤 (§16)
3. Playlist 상세: 전체 재생 버튼 + 번호/제목/아티스트 행, unavailable 곡 흐림·비활성 (§17)
4. 전체 재생 탭 → 즉시 Now Playing 전환 + 수 초 내 Watch에서 오디오 (§21)
5. 트랙 탭 → 즉시 Now Playing에 해당 곡 메타 표시(optimistic), Mac 재생 전환 (§21)
6. Now Playing: artwork·제목·아티스트, ⏮ ⏸/▶ ⏭ 동작, Crown 돌리면 볼륨 변화 (§18)
7. Next 탭 → 다음 곡 메타 즉시 표시 → 실제 오디오 전환 (§21)
8. Queue: 현재 곡 ▶ 마커 정확, 곡 탭 → 즉시 이동 + Now Playing 복귀 (§19)
9. 오류: Mac serve 중단 → 수 초 내 전면 "Mac에 연결할 수 없습니다 + 재시도" (§20), serve 재시작 + 재시도 → 복구
10. 화면 끄기/손바닥 덮기 → 재생 지속 (Phase 1 회귀 확인)

- [ ] **Step 3: 결과 기록 + 커밋**

```bash
python3 - <<'EOF'
import json
s = json.load(open('status.json'))
s['phases'].setdefault('phase5', {'name': 'watchOS UI', 'tasks': []})
s['phases']['phase5']['status'] = 'done'
s['current'] = {'phase': 'phase5', 'status': 'done'}
json.dump(s, open('status.json', 'w'), ensure_ascii=False, indent=2)
EOF
git add status.json docs/poc-results.md && git commit -m "chore: phase5 device checkpoint"
```

---

## Self-Review

- **스펙 커버리지**: §15 네비게이션 구조·시작 라우트 → T8 ✓. §16 Playlists(artwork 행·Crown 스크롤) → T6 ✓. §17 상세(전체 재생·번호 행·artwork 제거·부가 버튼 없음) → T6 ✓. §18 Now Playing(artwork 중심·3버튼·Primary Play/Pause·Crown 볼륨·seek 없음) → T5 ✓. §19 Queue(현재 곡 표시·탭 즉시 이동) → T7 ✓. §20 오류만 표시(Mac 연결 실패 전면 + Connecting… 인라인, LTE/mTLS 등 미노출) → T5·T6·T8 ✓. §21 optimistic(즉시 전환·POST·실패 rollback·Next 메타 즉시 표시·reconcile) → T1·T3 ✓. §22 상태 축 분리(link/stream/playback 독립, volume 로컬, stateVersion reconcile·역전 방지) → T1·T3 ✓. §23 Phase 5 6항목(Playlists/Detail/NowPlaying/Queue/Crown/오류) 전부 커버 ✓.
- **플레이스홀더 스캔**: 전 태스크 코드 블록 완결 ✓. T2 Step 1의 mock 이름은 실제 파일 확인 지시가 명시된 의도적 적응 지점(placeholder 아님 — 검증 대상은 고정). T8 Step 2의 중복 push 메모도 동작 선택지를 명시한 구현 재량.
- **타입 일관성**: `Reconcile.resolve(server:overlay:now:)` T1 정의 = T3 사용 ✓. `ApiError(status:)` T2 = T3 jumpQueue catch ✓. `PlaylistSummary: Hashable` 추가는 T6 Step 4에 명시 ✓. `ArtworkView(id:size:)` T4 = T5·T6 호출 ✓. `onPlay: () -> Void` T6 정의 = T8 주입 ✓. `ErrorRetryView`는 T6에서 생성·T8에서 재사용 ✓.
- **알려진 리스크**: (a) NavigationStack 중복 push UX — T9 실기기에서 확인, 필요시 T8 메모대로 보완. (b) `CommandResponse.stateVersion`은 폴링 반영 전 값(Phase 2 최종 리뷰 노트) — overlay 해소를 응답이 아닌 폴링 stateVersion 증가에 걸었으므로 설계상 문제 없음. (c) 2초 폴링의 배터리 영향 — T9에서 관찰. (d) Swift 6 strict concurrency에서 SwiftUI/AVFoundation 경계 경고 가능 — 빌드 게이트에서 드러나면 @MainActor/@unchecked Sendable 대신 구조 수정 우선.

## Execution

권장 순서: T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9 (전부 순차 — T5~T7은 파일이 겹치지 않지만 T7이 T5 파일을 수정).
T9는 Watch 실조작이 필요하므로 사용자 협조 시점을 조율한다.

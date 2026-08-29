# Phase 2 — Library (Playlist/Queue 조회·재생, Metadata Cache, Artwork) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Watch가 Playlist 목록·트랙 목록·Queue를 조회하고, Playlist 전체 재생·Queue 이동을 명령할 수 있는 서버 API를 MacAgent에 추가한다 (Watch UI는 Phase 5).

**Architecture:** 라이브러리 데이터(플레이리스트 목록·트랙 목록)는 DOM 스크래핑이 아니라 **페이지 컨텍스트 안에서 YT Music 내부 API(innertube `/youtubei/v1/browse`)를 fetch**해서 얻는다 — 페이지 자체의 쿠키·설정을 그대로 쓰므로 별도 인증이 없고, 페이지 네비게이션 없이(재생 무중단) 구조화된 JSON을 받는다. JS 스니펫이 페이지 안에서 파싱까지 끝내고 우리 wire 모델에 가까운 압축 JSON만 반환한다. Queue는 이미 렌더된 DOM(`ytmusic-player-queue-item`)을 읽는다. 결과는 MetadataCache(TTL 5분)에 캐시하고, artwork는 Agent가 원본을 받아 128px JPEG로 리사이즈·캐시 후 `/api/artwork/{id}`로 서빙한다(Watch 단일 origin 유지, spec §9).

**Tech Stack:** Swift 5.9+, SwiftNIO(기존 StreamServer), CDP `Runtime.evaluate`(+`awaitPromise` 신규), ImageIO(리사이즈), XCTest.

**Spec:** `apple_watch_youtube_music_remote_player_design.md` — §5(Control Plane 엔드포인트·멱등성·409), §8(지원 명령), §9(Playlist/Metadata·Artwork·대용량), §11(API 보안), §19(Queue), §22(상태 모델), §23 Phase 2 정의.

## Global Constraints

(spec에서 그대로 — 모든 태스크에 암묵 적용)

- Agent·CDP는 127.0.0.1에만 bind (spec §7) — 이 계획은 bind를 건드리지 않는다
- API는 allow-list 라우팅: 정의된 엔드포인트 외 전부 404, 정의되지 않은 body 필드는 400 (spec §11)
- `trackId`/`playlistId`/`artwork id`는 사용 전 `^[A-Za-z0-9_-]{1,64}$` 검증 — JS 인젝션 표면 차단 (spec §11). Swift 5.9 모드에서 bare-slash regex 리터럴은 컴파일 불가 — `try! Regex(#"..."#)` 사용 (Phase 1 확정 deviation)
- JS 스니펫은 Agent 측 고정 문자열(YTMSelectors)만 — Watch는 URL/JS를 전송하지 않는다 (spec §11)
- POST body 제한: Agent 4KB(기존 Handler maxBody)·Caddy 16KB — 변경 없음
- 오류 규약: 4xx = 요청 거부(재시도 무의미), 5xx = 실행 여부 불명 (spec §5). 실패 응답은 commandId 캐시에 기록하지 않는다 (Phase 1 확정)
- `POST /api/queue/{position}`은 body에 기대 `stateVersion`을 포함하고 불일치 시 409 (spec §5)
- Watch의 네트워크 경로는 단일 origin — artwork는 Agent가 프록시·리사이즈(~128px) (spec §9)
- 목표 처리 시간: `GET /api/playlists*` < 50ms(캐시 히트 기준), `POST /api/player/*` < 100ms (spec §9)
- 커밋은 태스크 단위, 테스트 통과 후

## 설계 결정 (계획 수준 ruling)

1. **innertube in-page fetch vs DOM 스크래핑**: 라이브러리 조회는 innertube fetch. 근거 — 플레이리스트 상세를 DOM으로 읽으려면 페이지 네비게이션이 필요해 재생이 끊긴다(§5 지속 스트림 원칙 위배). innertube 응답 구조 변경 리스크는 YTMSelectors 단일 수정 지점 원칙으로 관리한다. Queue만 DOM(이미 화면에 있고 fetch 경로가 없음).
2. **Pagination**: 첫 browse 응답(통상 ≤100곡)만 사용하고 continuation은 따라가지 않는다. `?offset=&limit=`은 캐시된 전체 목록 위에서 동작. 개인용 플레이리스트 규모에서 충분 — 100곡 초과분 누락은 알려진 제한으로 문서화 (YAGNI).
3. **Artwork id 정책**: track artwork id = trackId(`https://i.ytimg.com/vi/{id}/mqdefault.jpg`에서 파생), playlist artwork id = playlistId(innertube thumbnail URL을 조회 시 등록). **등록된 id만 서빙** — open proxy 방지.
4. **`GET /api/queue`는 캐시하지 않는다** — 재생 진행에 따라 수시로 변하는 상태라 TTL 캐시가 오히려 해롭다.
5. **queue jump 실행 시점에 position이 사라진 경우 409** — stateVersion이 맞았어도 DOM이 그새 변한 것이므로 "상태 경합" 의미인 409로 통일.
6. **awaitPromise 타임아웃은 기존 5초 유지** — innertube fetch는 통상 1초 미만. T9 체크포인트에서 타임아웃이 관찰되면 그때 늘린다.

## Out of Scope (이 계획에서 하지 않음)

- Watch UI(Playlists/Detail/Queue 화면, artwork 표시) — Phase 5 (§16–19)
- Optimistic UI, WebSocket push, 자동 재접속 — Phase 5/6
- innertube continuation(100곡 초과 페이지) — 필요해지면 후속
- SQLite 영속 캐시 — 메모리로 충분 (spec §9 "메모리 또는 SQLite 수준")
- SCStream 사망 감지 — Phase 3/6

## File Structure

| 파일 | 책임 |
|---|---|
| `YoutumuKit/Sources/YoutumuKit/Library.swift` (신규) | wire 모델: PlaylistSummary, TrackSummary, PlaylistPage, QueueItem, QueueSnapshot |
| `YoutumuKit/Tests/YoutumuKitTests/LibraryModelsTests.swift` (신규) | Codable 왕복 |
| `MacAgent/Sources/MacAgentCore/CDPCodec.swift` (수정) | `awaitPromise` 파라미터 |
| `MacAgent/Sources/MacAgentCore/CDPClient.swift` (수정) | `evaluate(_:awaitPromise:)` |
| `MacAgent/Sources/MacAgentCore/YTMSelectors.swift` (수정) | innertube fetch 스니펫 2종 + queue 스니펫 3종 |
| `MacAgent/Sources/MacAgentCore/BrowserController.swift` (수정) | `LibraryProviding` 프로토콜 + 구현, `PlaylistInfo` |
| `MacAgent/Sources/MacAgentCore/MetadataCache.swift` (신규) | TTL 캐시 (playlists / tracks-per-playlist) |
| `MacAgent/Sources/MacAgentCore/ArtworkService.swift` (신규) | id→URL 등록, fetch, 128px 리사이즈, LRU 캐시 |
| `MacAgent/Sources/MacAgentCore/ControlAPI.swift` (수정) | 신규 라우트 6종, queue jump 409, query 파싱 |
| `MacAgent/Sources/MacAgentCore/StreamServer.swift` (수정) | uri query 분리, Content-Type 가변화, Handler internal화 |
| `MacAgent/Sources/MacAgent/main.swift` (수정) | 조립 |
| `MacAgent/Tests/MacAgentTests/{MetadataCacheTests,ArtworkServiceTests,ControlAPILibraryTests,LibraryDecodeTests,StreamServerHandlerTests}.swift` (신규) | 태스크별 테스트 |

**Interfaces 요약 (태스크 간 계약):**

```swift
// YoutumuKit (wire, public)
public struct PlaylistSummary: Codable, Equatable { public let playlistId, title: String; public let trackCount: Int }
public struct TrackSummary: Codable, Equatable { public let trackId, title, artist: String; public let durationSec: Int; public let unavailable: Bool }
public struct PlaylistPage: Codable, Equatable { public let items: [TrackSummary]; public let total, offset: Int }
public struct QueueItem: Codable, Equatable { public let position: Int; public let title, artist: String; public let current: Bool }
public struct QueueSnapshot: Codable, Equatable { public let stateVersion: UInt64; public let items: [QueueItem] }

// MacAgentCore
public struct PlaylistInfo: Decodable, Equatable { public let playlistId, title: String; public let trackCount: Int; public let thumbnailUrl: String }
public protocol LibraryProviding {
    func listPlaylists() async throws -> [PlaylistInfo]
    func playlistTracks(playlistId: String) async throws -> [TrackSummary]
    func queueItems() async throws -> [QueueItem]
    func jumpQueue(position: Int) async throws -> Bool      // false = position 없음
    func playPlaylist(playlistId: String) async throws
}
// BrowserController: LibraryProviding 채택
// MetadataCache: playlists(now:fill:), tracks(playlistId:now:fill:)
// ArtworkService: register(id:url:), registerTrack(id:), image(id:) async -> Data?
// ControlAPI.init(store:svc:controller:library:cache:artwork:)
// ApiRequest.query: [String: String] (기본 [:]) / ApiResponse.contentType: String (기본 "application/json")
```

---

### Task 1: YoutumuKit wire 모델

**Files:**
- Create: `YoutumuKit/Sources/YoutumuKit/Library.swift`
- Test: `YoutumuKit/Tests/YoutumuKitTests/LibraryModelsTests.swift`

**Interfaces:**
- Produces: 위 Interfaces 요약의 YoutumuKit 5개 struct — 이후 모든 태스크가 소비

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import YoutumuKit

final class LibraryModelsTests: XCTestCase {
    func testPlaylistPageRoundTrip() throws {
        let page = PlaylistPage(
            items: [TrackSummary(trackId: "dQw4w9WgXcQ", title: "Song", artist: "Artist", durationSec: 222, unavailable: false)],
            total: 42, offset: 0)
        let data = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(PlaylistPage.self, from: data), page)
    }

    func testQueueSnapshotRoundTrip() throws {
        let snap = QueueSnapshot(stateVersion: 7,
                                 items: [QueueItem(position: 0, title: "A", artist: "B", current: true)])
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(QueueSnapshot.self, from: data), snap)
    }

    func testPlaylistSummaryDecodesFromWireJSON() throws {
        let json = #"{"playlistId":"PLabc_-123","title":"Running","trackCount":42}"#
        let p = try JSONDecoder().decode(PlaylistSummary.self, from: Data(json.utf8))
        XCTAssertEqual(p.playlistId, "PLabc_-123")
        XCTAssertEqual(p.trackCount, 42)
    }
}
```

- [ ] **Step 2: 실행 — 실패 확인**

Run: `cd YoutumuKit && swift test 2>&1 | grep -E "error|Executed"`
Expected: 컴파일 에러 (타입 미정의)

- [ ] **Step 3: 최소 구현**

```swift
import Foundation

// Phase 2 wire 모델 (spec §5·§9·§19). Watch(Phase 5)와 공유하므로 YoutumuKit에 둔다.

public struct PlaylistSummary: Codable, Equatable {
    public let playlistId: String
    public let title: String
    public let trackCount: Int
    public init(playlistId: String, title: String, trackCount: Int) {
        self.playlistId = playlistId; self.title = title; self.trackCount = trackCount
    }
}

public struct TrackSummary: Codable, Equatable {
    public let trackId: String
    public let title: String
    public let artist: String
    public let durationSec: Int
    public let unavailable: Bool          // 삭제·재생 불가 곡 (spec §9)
    public init(trackId: String, title: String, artist: String, durationSec: Int, unavailable: Bool) {
        self.trackId = trackId; self.title = title; self.artist = artist
        self.durationSec = durationSec; self.unavailable = unavailable
    }
}

public struct PlaylistPage: Codable, Equatable {
    public let items: [TrackSummary]
    public let total: Int                 // 페이지와 무관한 전체 곡 수
    public let offset: Int
    public init(items: [TrackSummary], total: Int, offset: Int) {
        self.items = items; self.total = total; self.offset = offset
    }
}

public struct QueueItem: Codable, Equatable {
    public let position: Int              // Queue 이동은 position 기준 — 중복 곡 대응 (spec §5)
    public let title: String
    public let artist: String
    public let current: Bool
    public init(position: Int, title: String, artist: String, current: Bool) {
        self.position = position; self.title = title; self.artist = artist; self.current = current
    }
}

public struct QueueSnapshot: Codable, Equatable {
    public let stateVersion: UInt64       // queue jump의 기대 stateVersion 출처 (spec §5 409)
    public let items: [QueueItem]
    public init(stateVersion: UInt64, items: [QueueItem]) {
        self.stateVersion = stateVersion; self.items = items
    }
}
```

- [ ] **Step 4: 실행 — 통과 확인**

Run: `swift test 2>&1 | grep -E "Executed|error"`
Expected: 전부 PASS

- [ ] **Step 5: Commit**

```bash
git add YoutumuKit/Sources/YoutumuKit/Library.swift YoutumuKit/Tests/YoutumuKitTests/LibraryModelsTests.swift
git commit -m "feat: library wire models (playlists/tracks/queue) in YoutumuKit"
```

---

### Task 2: CDP awaitPromise 지원

**Files:**
- Modify: `MacAgent/Sources/MacAgentCore/CDPCodec.swift`
- Modify: `MacAgent/Sources/MacAgentCore/CDPClient.swift:31` (evaluate 시그니처)
- Modify: `MacAgent/Sources/MacAgentCore/BrowserController.swift:31-34` (eval 전달)
- Test: `MacAgent/Tests/MacAgentTests/CDPCodecTests.swift` (추가)

**Interfaces:**
- Produces: `CDPClient.evaluate(_ js: String, awaitPromise: Bool = false) async throws -> String?`, `BrowserController.eval(_ js: String, awaitPromise: Bool = false)` (private) — Task 3의 async 스니펫이 소비
- 기본값 `false`라 기존 호출부는 무변경

- [ ] **Step 1: 실패하는 테스트 추가** (기존 `CDPCodecTests.swift`에)

```swift
    func testEvaluateRequestAwaitPromise() throws {
        let data = CDPCodec.evaluateRequest(id: 3, expression: "fetch('/x')", awaitPromise: true)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(params["awaitPromise"] as? Bool, true)
    }

    func testEvaluateRequestDefaultsNoAwait() throws {
        let data = CDPCodec.evaluateRequest(id: 4, expression: "1+1")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(params["awaitPromise"] as? Bool, false)
    }
```

- [ ] **Step 2: 실행 — 실패 확인**

Run: `cd MacAgent && swift test --filter CDPCodecTests 2>&1 | grep -E "error|Executed"`
Expected: 컴파일 에러 (파라미터 없음)

- [ ] **Step 3: 구현**

`CDPCodec.evaluateRequest`:

```swift
    static func evaluateRequest(id: Int, expression: String, awaitPromise: Bool = false) -> Data {
        let msg: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true, "awaitPromise": awaitPromise],
        ]
        return try! JSONSerialization.data(withJSONObject: msg)   // 키·값 전부 JSON-호환 리터럴
    }
```

`CDPClient.evaluate` 시그니처를 `public func evaluate(_ js: String, awaitPromise: Bool = false) async throws -> String?`로 바꾸고, 내부에서 `CDPCodec.evaluateRequest(id: id, expression: js, awaitPromise: awaitPromise)`를 호출하도록 해당 한 줄만 수정한다 (타임아웃·continuation 로직은 그대로).

`BrowserController.eval`:

```swift
    private func eval(_ js: String, awaitPromise: Bool = false) async throws -> String? {
        do { return try await cdp.evaluate(js, awaitPromise: awaitPromise) }
        catch { try await cdp.connect(); return try await cdp.evaluate(js, awaitPromise: awaitPromise) }
    }
```

- [ ] **Step 4: 전체 테스트 통과 확인**

Run: `swift test 2>&1 | grep -E "Executed|error"`
Expected: 기존 포함 전부 PASS

- [ ] **Step 5: Commit**

```bash
git add MacAgent/Sources/MacAgentCore/CDPCodec.swift MacAgent/Sources/MacAgentCore/CDPClient.swift MacAgent/Sources/MacAgentCore/BrowserController.swift MacAgent/Tests/MacAgentTests/CDPCodecTests.swift
git commit -m "feat: CDP Runtime.evaluate awaitPromise for in-page async snippets"
```

---

### Task 3: 라이브러리 조회 — innertube 스니펫 + LibraryProviding(조회 절반)

**Files:**
- Modify: `MacAgent/Sources/MacAgentCore/YTMSelectors.swift` (스니펫 2종 추가)
- Modify: `MacAgent/Sources/MacAgentCore/BrowserController.swift` (PlaylistInfo, LibraryProviding, listPlaylists/playlistTracks)
- Test: `MacAgent/Tests/MacAgentTests/LibraryDecodeTests.swift` (신규)

**Interfaces:**
- Consumes: Task 1 모델, Task 2 `eval(_:awaitPromise:)`
- Produces: `PlaylistInfo`, `LibraryProviding`의 `listPlaylists()`/`playlistTracks(playlistId:)` — Task 5·7이 소비. **주의: LibraryProviding 프로토콜 전체(5개 메서드)를 이 태스크에서 선언**하되, queue 3종은 `BrowserController`에 스텁 없이 Task 4에서 구현을 추가한다 — 프로토콜 채택은 Task 4 완료 시점에 붙인다 (이 태스크에서는 BrowserController에 메서드 2개만 추가, `: LibraryProviding` 표기는 Task 4가 붙임)

- [ ] **Step 1: 실패하는 테스트 작성**

스니펫이 페이지 안에서 파싱해 돌려주는 압축 JSON을 Swift가 디코드하는 경로를 검증한다 (innertube 원본이 아니라 **스니펫 출력 포맷**이 계약).

```swift
import XCTest
@testable import MacAgentCore
import YoutumuKit

final class LibraryDecodeTests: XCTestCase {
    func testDecodePlaylistList() throws {
        let json = #"{"playlists":[{"playlistId":"PLabc","title":"Running","trackCount":42,"thumbnailUrl":"https://lh3.example/x.jpg"}]}"#
        let list = try JSONDecoder().decode(PlaylistListEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(list.playlists, [PlaylistInfo(playlistId: "PLabc", title: "Running", trackCount: 42,
                                                     thumbnailUrl: "https://lh3.example/x.jpg")])
    }

    func testDecodeTrackList() throws {
        let json = #"{"tracks":[{"trackId":"dQw4w9WgXcQ","title":"Song","artist":"Artist","durationSec":222,"unavailable":false},{"trackId":"","title":"Deleted","artist":"","durationSec":0,"unavailable":true}]}"#
        let list = try JSONDecoder().decode(TrackListEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(list.tracks.count, 2)
        XCTAssertTrue(list.tracks[1].unavailable)
    }

    func testSnippetsInterpolatePlaylistId() {
        // playlistId는 호출 전 정규식 검증 완료 전제 (spec §11) — 여기서는 삽입 위치만 확인
        XCTAssertTrue(YTM.playlistTracks(playlistId: "PLabc").contains("'VLPLabc'"))
        XCTAssertTrue(YTM.playPlaylist(playlistId: "PLabc").contains("list=PLabc"))
    }
}
```

- [ ] **Step 2: 실행 — 실패 확인**

Run: `swift test --filter LibraryDecodeTests 2>&1 | grep -E "error|Executed"`
Expected: 컴파일 에러

- [ ] **Step 3: YTMSelectors 스니펫 추가**

`YTM` enum에 추가 (`playPlaylist`는 Task 4 소관이지만 테스트 컴파일을 위해 여기서 함께 추가한다 — 한 줄이라 분리 비용이 더 큼):

```swift
    /// 라이브러리 플레이리스트 목록 — 페이지 컨텍스트에서 innertube browse 호출 (네비게이션 없음 = 재생 무중단).
    /// 반환: {"playlists":[{playlistId,title,trackCount,thumbnailUrl}]} 또는 {"error":"..."}
    static let listPlaylists = """
    (async () => {
      const cfg = (window.ytcfg && ytcfg.data_) || (window.yt && yt.config_);
      if (!cfg || !cfg.INNERTUBE_API_KEY) return JSON.stringify({error: 'no ytcfg'});
      const res = await fetch('/youtubei/v1/browse?key=' + cfg.INNERTUBE_API_KEY, {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({context: cfg.INNERTUBE_CONTEXT, browseId: 'FEmusic_liked_playlists'})
      });
      const j = await res.json();
      const found = [];
      (function walk(o) {
        if (!o || typeof o !== 'object') return;
        if (o.musicTwoRowItemRenderer) {
          const r = o.musicTwoRowItemRenderer;
          const bid = (r.navigationEndpoint && r.navigationEndpoint.browseEndpoint && r.navigationEndpoint.browseEndpoint.browseId) || '';
          if (bid.startsWith('VL')) {
            const sub = ((r.subtitle && r.subtitle.runs) || []).map(x => x.text).join('');
            const m = sub.match(/(\\d+)/);
            const th = (r.thumbnailRenderer && r.thumbnailRenderer.musicThumbnailRenderer
                        && r.thumbnailRenderer.musicThumbnailRenderer.thumbnail
                        && r.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails) || [];
            found.push({
              playlistId: bid.slice(2),
              title: (r.title && r.title.runs && r.title.runs[0] && r.title.runs[0].text) || '',
              trackCount: m ? parseInt(m[1], 10) : 0,
              thumbnailUrl: th.length ? th[th.length - 1].url : ''
            });
          }
        }
        for (const k in o) walk(o[k]);
      })(j);
      return JSON.stringify({playlists: found});
    })()
    """

    /// 플레이리스트 트랙 목록. playlistId는 호출 전에 ^[A-Za-z0-9_-]{1,64}$ 검증 필수 (spec §11).
    /// 첫 browse 응답만 사용 (continuation 미지원 — 계획 설계 결정 2).
    /// 반환: {"tracks":[{trackId,title,artist,durationSec,unavailable}]} 또는 {"error":"..."}
    static func playlistTracks(playlistId: String) -> String {
        """
        (async () => {
          const cfg = (window.ytcfg && ytcfg.data_) || (window.yt && yt.config_);
          if (!cfg || !cfg.INNERTUBE_API_KEY) return JSON.stringify({error: 'no ytcfg'});
          const res = await fetch('/youtubei/v1/browse?key=' + cfg.INNERTUBE_API_KEY, {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({context: cfg.INNERTUBE_CONTEXT, browseId: 'VL\(playlistId)'})
          });
          const j = await res.json();
          const found = [];
          (function walk(o) {
            if (!o || typeof o !== 'object') return;
            if (o.musicResponsiveListItemRenderer) {
              const r = o.musicResponsiveListItemRenderer;
              const cols = r.flexColumns || [];
              const col = i => cols[i] && cols[i].musicResponsiveListItemFlexColumnRenderer
                             && cols[i].musicResponsiveListItemFlexColumnRenderer.text
                             && cols[i].musicResponsiveListItemFlexColumnRenderer.text.runs
                             && cols[i].musicResponsiveListItemFlexColumnRenderer.text.runs[0];
              const videoId = (r.playlistItemData && r.playlistItemData.videoId) || '';
              const durText = (r.fixedColumns && r.fixedColumns[0]
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0]
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text) || '';
              let dur = 0;
              for (const p of durText.split(':')) { const n = parseInt(p, 10); dur = dur * 60 + (isFinite(n) ? n : 0); }
              found.push({
                trackId: videoId,
                title: (col(0) && col(0).text) || '',
                artist: (col(1) && col(1).text) || '',
                durationSec: dur,
                unavailable: !videoId || r.musicItemRendererDisplayPolicy === 'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT'
              });
            }
            for (const k in o) walk(o[k]);
          })(j);
          return JSON.stringify({tracks: found});
        })()
        """
    }

    /// Playlist 전체 재생. playlistId는 호출 전 검증 필수. Phase 1 playTrack과 동일한 full-navigation 방식 (M1 리스크 공유).
    static func playPlaylist(playlistId: String) -> String {
        "location.href = 'https://music.youtube.com/watch?list=\(playlistId)'"
    }
```

- [ ] **Step 4: BrowserController 확장**

`BrowserController.swift`에 추가:

```swift
public struct PlaylistInfo: Decodable, Equatable {
    public let playlistId: String
    public let title: String
    public let trackCount: Int
    public let thumbnailUrl: String      // Watch에 직접 노출하지 않는다 — ArtworkService 등록용 (spec §9 단일 origin)
    public init(playlistId: String, title: String, trackCount: Int, thumbnailUrl: String) {
        self.playlistId = playlistId; self.title = title
        self.trackCount = trackCount; self.thumbnailUrl = thumbnailUrl
    }
}

public protocol LibraryProviding {
    func listPlaylists() async throws -> [PlaylistInfo]
    func playlistTracks(playlistId: String) async throws -> [TrackSummary]
    func queueItems() async throws -> [QueueItem]
    func jumpQueue(position: Int) async throws -> Bool      // false = 해당 position 없음 (경합)
    func playPlaylist(playlistId: String) async throws
}

struct PlaylistListEnvelope: Decodable { let playlists: [PlaylistInfo] }
struct TrackListEnvelope: Decodable { let tracks: [TrackSummary] }

extension BrowserController {
    public func listPlaylists() async throws -> [PlaylistInfo] {
        guard let json = try await eval(YTM.listPlaylists, awaitPromise: true),
              let env = try? JSONDecoder().decode(PlaylistListEnvelope.self, from: Data(json.utf8))
        else { throw CDPError.badResponse }
        return env.playlists
    }

    public func playlistTracks(playlistId: String) async throws -> [TrackSummary] {
        guard let json = try await eval(YTM.playlistTracks(playlistId: playlistId), awaitPromise: true),
              let env = try? JSONDecoder().decode(TrackListEnvelope.self, from: Data(json.utf8))
        else { throw CDPError.badResponse }
        return env.tracks
    }
}
```

`import YoutumuKit`이 `BrowserController.swift` 상단에 이미 있는지 확인하고 없으면 추가한다.

- [ ] **Step 5: 실행 — 통과 확인**

Run: `swift test 2>&1 | grep -E "Executed|error"`
Expected: 전부 PASS

- [ ] **Step 6: Commit**

```bash
git add MacAgent/Sources/MacAgentCore/YTMSelectors.swift MacAgent/Sources/MacAgentCore/BrowserController.swift MacAgent/Tests/MacAgentTests/LibraryDecodeTests.swift
git commit -m "feat: library queries via in-page innertube fetch (playlists, playlist tracks)"
```

---

### Task 4: Queue 조회·이동 + Playlist 재생 — LibraryProviding 완성

**Files:**
- Modify: `MacAgent/Sources/MacAgentCore/YTMSelectors.swift` (queue 스니펫 2종)
- Modify: `MacAgent/Sources/MacAgentCore/BrowserController.swift` (queueItems/jumpQueue/playPlaylist + `LibraryProviding` 채택 표기)
- Test: `MacAgent/Tests/MacAgentTests/LibraryDecodeTests.swift` (추가)

**Interfaces:**
- Consumes: Task 3의 프로토콜·envelope 패턴
- Produces: `LibraryProviding` 완전 구현체로서의 `BrowserController` — Task 7·9가 소비

- [ ] **Step 1: 실패하는 테스트 추가**

```swift
    func testDecodeQueueList() throws {
        let json = #"{"queue":[{"position":0,"title":"A","artist":"X","current":true},{"position":1,"title":"B","artist":"Y","current":false}]}"#
        let env = try JSONDecoder().decode(QueueListEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.queue[0].current, true)
        XCTAssertEqual(env.queue[1].position, 1)
    }

    func testJumpQueueSnippetInterpolatesPosition() {
        XCTAssertTrue(YTM.jumpQueue(position: 3).contains("[3]"))
    }
```

- [ ] **Step 2: 실행 — 실패 확인**

Run: `swift test --filter LibraryDecodeTests 2>&1 | grep -E "error|Executed"`
Expected: 컴파일 에러

- [ ] **Step 3: 스니펫 추가**

```swift
    /// 현재 Queue — 이미 렌더된 DOM에서 읽는다 (fetch 경로 없음). 반환: {"queue":[{position,title,artist,current}]}
    /// 셀렉터 검증: T9 체크포인트에서 DevTools로 확인 (selected 속성이 현재 곡 표시인지 포함)
    static let queueSnapshot = """
    (() => {
      const items = [...document.querySelectorAll('ytmusic-player-queue ytmusic-player-queue-item')];
      return JSON.stringify({queue: items.map((el, i) => ({
        position: i,
        title: el.querySelector('.song-title')?.textContent?.trim() || '',
        artist: el.querySelector('.byline')?.textContent?.trim() || '',
        current: el.hasAttribute('selected')
      }))});
    })()
    """

    /// Queue의 position번째 곡으로 이동. 반환 "true"/"false"(문자열) — false = 해당 position 없음(경합).
    static func jumpQueue(position: Int) -> String {
        """
        (() => {
          const el = document.querySelectorAll('ytmusic-player-queue ytmusic-player-queue-item')[\(position)];
          if (!el) return JSON.stringify(false);
          (el.querySelector('ytmusic-play-button-renderer') || el).click();
          return JSON.stringify(true);
        })()
        """
    }
```

- [ ] **Step 4: BrowserController 완성**

```swift
struct QueueListEnvelope: Decodable { let queue: [QueueItem] }

extension BrowserController {
    public func queueItems() async throws -> [QueueItem] {
        guard let json = try await eval(YTM.queueSnapshot),
              let env = try? JSONDecoder().decode(QueueListEnvelope.self, from: Data(json.utf8))
        else { throw CDPError.badResponse }
        return env.queue
    }

    public func jumpQueue(position: Int) async throws -> Bool {
        try await eval(YTM.jumpQueue(position: position)) == "true"
    }

    public func playPlaylist(playlistId: String) async throws {
        _ = try await eval(YTM.playPlaylist(playlistId: playlistId))
    }
}
```

클래스 선언을 `public final class BrowserController: PlayerControlling, LibraryProviding`로 갱신.

- [ ] **Step 5: 실행 — 통과 확인 후 Commit**

Run: `swift test 2>&1 | grep -E "Executed|error"` → 전부 PASS

```bash
git add MacAgent/Sources/MacAgentCore/YTMSelectors.swift MacAgent/Sources/MacAgentCore/BrowserController.swift MacAgent/Tests/MacAgentTests/LibraryDecodeTests.swift
git commit -m "feat: queue snapshot/jump + playlist playback (LibraryProviding complete)"
```

---

### Task 5: MetadataCache

**Files:**
- Create: `MacAgent/Sources/MacAgentCore/MetadataCache.swift`
- Test: `MacAgent/Tests/MacAgentTests/MetadataCacheTests.swift`

**Interfaces:**
- Consumes: `PlaylistInfo`(Task 3), `TrackSummary`(Task 1)
- Produces: `MetadataCache.playlists(now:fill:)`, `.tracks(playlistId:now:fill:)` — Task 7이 소비

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import MacAgentCore
import YoutumuKit

final class MetadataCacheTests: XCTestCase {
    private let p1 = PlaylistInfo(playlistId: "PL1", title: "A", trackCount: 1, thumbnailUrl: "")
    private let t1 = TrackSummary(trackId: "v1", title: "T", artist: "A", durationSec: 10, unavailable: false)

    func testFillsOnceWithinTTL() async throws {
        let cache = MetadataCache(ttl: 300)
        var calls = 0
        let base = Date()
        _ = try await cache.playlists(now: base) { calls += 1; return [self.p1] }
        let second = try await cache.playlists(now: base.addingTimeInterval(299)) { calls += 1; return [] }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(second, [p1])              // 캐시 히트 — fill 미호출
    }

    func testRefetchesAfterTTL() async throws {
        let cache = MetadataCache(ttl: 300)
        var calls = 0
        let base = Date()
        _ = try await cache.playlists(now: base) { calls += 1; return [self.p1] }
        _ = try await cache.playlists(now: base.addingTimeInterval(301)) { calls += 1; return [] }
        XCTAssertEqual(calls, 2)
    }

    func testTracksCachedPerPlaylist() async throws {
        let cache = MetadataCache(ttl: 300)
        var calls = 0
        let base = Date()
        _ = try await cache.tracks(playlistId: "PL1", now: base) { calls += 1; return [self.t1] }
        _ = try await cache.tracks(playlistId: "PL2", now: base) { calls += 1; return [] }
        let hit = try await cache.tracks(playlistId: "PL1", now: base) { calls += 1; return [] }
        XCTAssertEqual(calls, 2)                   // PL1은 히트, PL2만 추가 fill
        XCTAssertEqual(hit, [t1])
    }

    func testFillErrorPropagatesAndNothingCached() async {
        struct E: Error {}
        let cache = MetadataCache(ttl: 300)
        do {
            _ = try await cache.playlists(now: Date()) { throw E() }
            XCTFail("expected throw")
        } catch {}
        var calls = 0
        _ = try? await cache.playlists(now: Date()) { calls += 1; return [] }
        XCTAssertEqual(calls, 1)                   // 실패는 캐시되지 않는다
    }
}
```

- [ ] **Step 2: 실행 — 실패 확인**

Run: `swift test --filter MetadataCacheTests 2>&1 | grep -E "error|Executed"`
Expected: 컴파일 에러

- [ ] **Step 3: 구현**

```swift
import Foundation
import YoutumuKit

/// Watch가 화면을 열 때마다 브라우저를 scraping하지 않기 위한 TTL 캐시 (spec §9). 메모리 전용.
/// fill은 lock 밖에서 실행 — 동시 요청이 겹치면 중복 fetch가 날 수 있으나(개인용 단일 Watch) 무해.
public final class MetadataCache {
    private let lock = NSLock()
    private var playlistsEntry: (value: [PlaylistInfo], at: Date)?
    private var tracksEntries: [String: (value: [TrackSummary], at: Date)] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 300) { self.ttl = ttl }

    public func playlists(now: Date = Date(),
                          fill: () async throws -> [PlaylistInfo]) async throws -> [PlaylistInfo] {
        lock.lock()
        if let e = playlistsEntry, now.timeIntervalSince(e.at) < ttl {
            let v = e.value; lock.unlock(); return v
        }
        lock.unlock()
        let v = try await fill()
        lock.lock(); playlistsEntry = (v, now); lock.unlock()
        return v
    }

    public func tracks(playlistId: String, now: Date = Date(),
                       fill: () async throws -> [TrackSummary]) async throws -> [TrackSummary] {
        lock.lock()
        if let e = tracksEntries[playlistId], now.timeIntervalSince(e.at) < ttl {
            let v = e.value; lock.unlock(); return v
        }
        lock.unlock()
        let v = try await fill()
        lock.lock(); tracksEntries[playlistId] = (v, now); lock.unlock()
        return v
    }
}
```

- [ ] **Step 4: 실행 — 통과 확인 후 Commit**

Run: `swift test --filter MetadataCacheTests 2>&1 | grep -E "Executed|error"` → PASS

```bash
git add MacAgent/Sources/MacAgentCore/MetadataCache.swift MacAgent/Tests/MacAgentTests/MetadataCacheTests.swift
git commit -m "feat: TTL metadata cache for playlists/tracks"
```

---

### Task 6: ArtworkService

**Files:**
- Create: `MacAgent/Sources/MacAgentCore/ArtworkService.swift`
- Test: `MacAgent/Tests/MacAgentTests/ArtworkServiceTests.swift`

**Interfaces:**
- Consumes: 없음 (Foundation/ImageIO만)
- Produces: `register(id:url:)`, `registerTrack(id:)`, `image(id:) async -> Data?`, `static resizeJPEG(_:maxPx:)` — Task 7이 소비

- [ ] **Step 1: 실패하는 테스트 작성**

네트워크 없이 검증한다: 리사이즈는 ImageIO로 만든 인메모리 PNG로, 서빙 정책은 미등록 id로.

```swift
import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import MacAgentCore

final class ArtworkServiceTests: XCTestCase {
    /// 256x256 단색 PNG를 인메모리 생성
    private func makePNG(side: Int) -> Data {
        var pixels = [UInt8](repeating: 128, count: side * side * 4)
        let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testResizeCapsLongestSideTo128() throws {
        let resized = try XCTUnwrap(ArtworkService.resizeJPEG(makePNG(side: 256), maxPx: 128))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(resized as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let w = props[kCGImagePropertyPixelWidth] as? Int
        XCTAssertEqual(w, 128)
        // JPEG로 재인코딩됐는지
        let type = CGImageSourceGetType(src) as String?
        XCTAssertEqual(type, UTType.jpeg.identifier)
    }

    func testResizeRejectsGarbage() {
        XCTAssertNil(ArtworkService.resizeJPEG(Data([0x00, 0x01, 0x02]), maxPx: 128))
    }

    func testUnregisteredIdServesNothing() async {
        let svc = ArtworkService()
        let img = await svc.image(id: "unknown-id")
        XCTAssertNil(img)                          // 등록된 id만 — open proxy 방지
    }

    func testRegisterTrackDerivesYtimgURL() {
        let svc = ArtworkService()
        svc.registerTrack(id: "dQw4w9WgXcQ")
        XCTAssertEqual(svc.registeredURL(id: "dQw4w9WgXcQ"),
                       "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
    }
}
```

- [ ] **Step 2: 실행 — 실패 확인**

Run: `swift test --filter ArtworkServiceTests 2>&1 | grep -E "error|Executed"`
Expected: 컴파일 에러

- [ ] **Step 3: 구현**

```swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Watch는 Google CDN에 직접 접근하지 않는다 — Agent가 원본을 받아 128px JPEG로 리사이즈·캐시 후 서빙 (spec §9).
/// 조회 시점에 등록된 id만 서빙한다 (open proxy 방지, spec §11 심층 방어).
public final class ArtworkService {
    private let lock = NSLock()
    private var urls: [String: String] = [:]       // id → 원본 URL
    private var cache: [String: Data] = [:]        // id → 리사이즈된 JPEG
    private var order: [String] = []               // LRU (최근 사용이 뒤)
    private let maxEntries: Int
    private let session: URLSession

    public init(session: URLSession = .shared, maxEntries: Int = 256) {
        self.session = session; self.maxEntries = maxEntries
    }

    public func register(id: String, url: String) {
        guard !url.isEmpty else { return }
        lock.lock(); urls[id] = url; lock.unlock()
    }

    public func registerTrack(id: String) {
        register(id: id, url: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }

    func registeredURL(id: String) -> String? {    // 테스트용 (internal)
        lock.lock(); defer { lock.unlock() }
        return urls[id]
    }

    public func image(id: String) async -> Data? {
        lock.lock()
        if let hit = cache[id] {
            order.removeAll { $0 == id }; order.append(id)
            lock.unlock(); return hit
        }
        let urlString = urls[id]
        lock.unlock()
        guard let urlString, let url = URL(string: urlString) else { return nil }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let jpeg = Self.resizeJPEG(data, maxPx: 128) else { return nil }
        lock.lock()
        cache[id] = jpeg; order.append(id)
        while order.count > maxEntries { cache.removeValue(forKey: order.removeFirst()) }
        lock.unlock()
        return jpeg
    }

    static func resizeJPEG(_ data: Data, maxPx: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPx,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
```

`resizeJPEG`를 테스트가 `ArtworkService.resizeJPEG`로 부르므로 `static func`는 internal이 아닌 `public static`이어도 무방하나 internal + `@testable`로 충분 — internal 유지.

- [ ] **Step 4: 실행 — 통과 확인 후 Commit**

Run: `swift test --filter ArtworkServiceTests 2>&1 | grep -E "Executed|error"` → PASS

```bash
git add MacAgent/Sources/MacAgentCore/ArtworkService.swift MacAgent/Tests/MacAgentTests/ArtworkServiceTests.swift
git commit -m "feat: artwork proxy — fetch, 128px JPEG resize, LRU cache, registered-id-only"
```

---

### Task 7: ControlAPI 라우트 확장 + StreamServer query/Content-Type

**Files:**
- Modify: `MacAgent/Sources/MacAgentCore/ControlAPI.swift`
- Modify: `MacAgent/Sources/MacAgentCore/StreamServer.swift` (uri query 분리, Content-Type 가변)
- Test: `MacAgent/Tests/MacAgentTests/ControlAPILibraryTests.swift` (신규)

**Interfaces:**
- Consumes: Task 1 모델, Task 3·4 `LibraryProviding`, Task 5 `MetadataCache`, Task 6 `ArtworkService`
- Produces: `ControlAPI.init(store:svc:controller:library:cache:artwork:)` — Task 9가 소비. `ApiRequest.query: [String: String] = [:]`, `ApiResponse.contentType: String = "application/json"`

**신규 라우트 계약 (spec §5·§9):**

| 라우트 | 성공 | 거부 |
|---|---|---|
| `GET /api/playlists` | 200 `[PlaylistSummary]` | 502 fetch 실패 |
| `GET /api/playlists/{id}?offset=&limit=` | 200 `PlaylistPage` | 400 잘못된 id, 502 |
| `GET /api/queue` | 200 `QueueSnapshot` | 502 |
| `POST /api/player/playlists/{id}` | 200 `CommandResponse` (기존 command 규약) | 400/502 기존과 동일 |
| `POST /api/queue/{position}` | 200 `CommandResponse` | 400 잘못된 position/body, **409 stateVersion 불일치·position 소멸**, 502 |
| `GET /api/artwork/{id}` | 200 `image/jpeg` | 400 잘못된 id, 404 미등록/획득 실패 |

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import MacAgentCore
import YoutumuKit

/// LibraryProviding mock — 호출 기록 + 조작 가능 응답
private final class MockLibrary: LibraryProviding {
    var playlists: [PlaylistInfo] = []
    var tracks: [TrackSummary] = []
    var queue: [QueueItem] = []
    var jumpResult = true
    var playlistCalls: [String] = []
    var jumpCalls: [Int] = []
    var listCalls = 0
    var shouldThrow = false
    struct E: Error {}
    func listPlaylists() async throws -> [PlaylistInfo] {
        if shouldThrow { throw E() }; listCalls += 1; return playlists
    }
    func playlistTracks(playlistId: String) async throws -> [TrackSummary] {
        if shouldThrow { throw E() }; return tracks
    }
    func queueItems() async throws -> [QueueItem] {
        if shouldThrow { throw E() }; return queue
    }
    func jumpQueue(position: Int) async throws -> Bool {
        if shouldThrow { throw E() }; jumpCalls.append(position); return jumpResult
    }
    func playPlaylist(playlistId: String) async throws {
        if shouldThrow { throw E() }; playlistCalls.append(playlistId)
    }
}

/// PlayerControlling mock (기존 라우트 유지 확인용 최소)
private final class NoopController: PlayerControlling {
    func play() async throws {}
    func pause() async throws {}
    func next() async throws {}
    func previous() async throws {}
    func playTrack(videoId: String) async throws {}
}

final class ControlAPILibraryTests: XCTestCase {
    private var lib: MockLibrary!
    private var svc: PlayerStateService!
    private var api: ControlAPI!

    override func setUp() {
        lib = MockLibrary()
        svc = PlayerStateService()
        api = ControlAPI(store: CommandStore(), svc: svc, controller: NoopController(),
                         library: lib, cache: MetadataCache(ttl: 300), artwork: ArtworkService())
    }

    private func get(_ path: String, query: [String: String] = [:]) async -> ApiResponse {
        await api.handle(ApiRequest(method: "GET", path: path, body: Data(), query: query))
    }
    private func post(_ path: String, body: String) async -> ApiResponse {
        await api.handle(ApiRequest(method: "POST", path: path, body: Data(body.utf8)))
    }
    private func cmdBody(_ extra: String = "") -> String {
        #"{"commandId": "\#(UUID().uuidString)"\#(extra)}"#
    }

    func testListPlaylistsMapsToWireModel() async throws {
        lib.playlists = [PlaylistInfo(playlistId: "PL1", title: "Run", trackCount: 3, thumbnailUrl: "https://x/y.jpg")]
        let resp = await get("/api/playlists")
        XCTAssertEqual(resp.status, 200)
        let out = try JSONDecoder().decode([PlaylistSummary].self, from: resp.body)
        XCTAssertEqual(out, [PlaylistSummary(playlistId: "PL1", title: "Run", trackCount: 3)])
    }

    func testListPlaylistsUsesCache() async {
        lib.playlists = []
        _ = await get("/api/playlists")
        _ = await get("/api/playlists")
        XCTAssertEqual(lib.listCalls, 1)
    }

    func testListPlaylistsFetchFailureIs502() async {
        lib.shouldThrow = true
        let resp = await get("/api/playlists")
        XCTAssertEqual(resp.status, 502)
    }

    func testPlaylistDetailPagination() async throws {
        lib.tracks = (0..<10).map { TrackSummary(trackId: "v\($0)", title: "T\($0)", artist: "A", durationSec: 60, unavailable: false) }
        let resp = await get("/api/playlists/PL1", query: ["offset": "8", "limit": "5"])
        let page = try JSONDecoder().decode(PlaylistPage.self, from: resp.body)
        XCTAssertEqual(page.items.map(\.trackId), ["v8", "v9"])
        XCTAssertEqual(page.total, 10)
        XCTAssertEqual(page.offset, 8)
    }

    func testPlaylistDetailBadIdIs400() async {
        let resp = await get("/api/playlists/bad$id")
        XCTAssertEqual(resp.status, 400)
    }

    func testQueueSnapshotCarriesStateVersion() async throws {
        lib.queue = [QueueItem(position: 0, title: "A", artist: "B", current: true)]
        let resp = await get("/api/queue")
        let snap = try JSONDecoder().decode(QueueSnapshot.self, from: resp.body)
        XCTAssertEqual(snap.stateVersion, svc.state().stateVersion)
        XCTAssertEqual(snap.items.count, 1)
    }

    func testPlayPlaylistCommand() async {
        let resp = await post("/api/player/playlists/PL1", body: cmdBody())
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(lib.playlistCalls, ["PL1"])
    }

    func testQueueJumpHappyPath() async {
        let sv = svc.state().stateVersion
        let resp = await post("/api/queue/2", body: cmdBody(#", "stateVersion": \#(sv)"#))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(lib.jumpCalls, [2])
    }

    func testQueueJumpStaleStateVersionIs409NoExec() async {
        let sv = svc.state().stateVersion &- 1
        let resp = await post("/api/queue/2", body: cmdBody(#", "stateVersion": \#(sv)"#))
        XCTAssertEqual(resp.status, 409)
        XCTAssertEqual(lib.jumpCalls, [])          // 실행되지 않아야 한다 (spec §5)
    }

    func testQueueJumpPositionGoneIs409() async {
        lib.jumpResult = false
        let sv = svc.state().stateVersion
        let resp = await post("/api/queue/2", body: cmdBody(#", "stateVersion": \#(sv)"#))
        XCTAssertEqual(resp.status, 409)
    }

    func testQueueJumpMissingStateVersionIs400() async {
        let resp = await post("/api/queue/2", body: cmdBody())
        XCTAssertEqual(resp.status, 400)
    }

    func testQueueJumpExtraFieldIs400() async {
        let sv = svc.state().stateVersion
        let resp = await post("/api/queue/2", body: cmdBody(#", "stateVersion": \#(sv), "x": 1"#))
        XCTAssertEqual(resp.status, 400)
    }

    func testQueueJumpDuplicateCommandIdNotReexecuted() async {
        let id = UUID().uuidString
        let sv = svc.state().stateVersion
        let body = #"{"commandId": "\#(id)", "stateVersion": \#(sv)}"#
        _ = await post("/api/queue/1", body: body)
        let dup = await post("/api/queue/1", body: body)
        XCTAssertEqual(dup.status, 200)
        XCTAssertEqual(lib.jumpCalls, [1])         // 1회만 실행
    }

    func testQueueJumpBadPositionIs400() async {
        let resp = await post("/api/queue/abc", body: cmdBody())
        XCTAssertEqual(resp.status, 400)
    }

    func testArtworkUnknownIdIs404() async {
        let resp = await get("/api/artwork/unknownid")
        XCTAssertEqual(resp.status, 404)
    }

    func testArtworkBadIdIs400() async {
        let resp = await get("/api/artwork/bad$id")
        XCTAssertEqual(resp.status, 400)
    }

    func testUnknownEndpointStill404() async {
        let resp = await get("/api/library")
        XCTAssertEqual(resp.status, 404)
    }
}
```

- [ ] **Step 2: 실행 — 실패 확인**

Run: `swift test --filter ControlAPILibraryTests 2>&1 | grep -E "error|Executed"`
Expected: 컴파일 에러 (init 시그니처)

- [ ] **Step 3: ApiRequest/ApiResponse 확장** (`ControlAPI.swift`)

```swift
public struct ApiRequest {
    public let method: String
    public let path: String
    public let body: Data
    public let query: [String: String]
    public init(method: String, path: String, body: Data, query: [String: String] = [:]) {
        self.method = method; self.path = path; self.body = body; self.query = query
    }
}

public struct ApiResponse {
    public let status: Int
    public let body: Data
    public let contentType: String
    public init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status; self.body = body; self.contentType = contentType
    }
    static func error(_ status: Int, _ msg: String) -> ApiResponse {
        ApiResponse(status: status, body: try! JSONEncoder().encode(["error": msg]))
    }
}
```

- [ ] **Step 4: ControlAPI 라우트 구현**

init·프로퍼티:

```swift
    private let store: CommandStore
    private let svc: PlayerStateService
    private let controller: PlayerControlling
    private let library: LibraryProviding
    private let cache: MetadataCache
    private let artwork: ArtworkService
    private static let idPattern = try! Regex(#"^[A-Za-z0-9_-]{1,64}$"#)   // trackId·playlistId·artwork id 공통 (spec §11)

    public init(store: CommandStore, svc: PlayerStateService, controller: PlayerControlling,
                library: LibraryProviding, cache: MetadataCache, artwork: ArtworkService) {
        self.store = store; self.svc = svc; self.controller = controller
        self.library = library; self.cache = cache; self.artwork = artwork
    }
```

(기존 `trackIdPattern` 참조는 `idPattern`으로 일괄 변경.)

`handle`의 switch에 추가 (기존 case들 유지, `default` 앞):

```swift
        case ("GET", "/api/playlists"):
            do {
                let infos = try await cache.playlists { try await self.library.listPlaylists() }
                for p in infos { artwork.register(id: p.playlistId, url: p.thumbnailUrl) }
                let out = infos.map { PlaylistSummary(playlistId: $0.playlistId, title: $0.title, trackCount: $0.trackCount) }
                return ApiResponse(status: 200, body: try! JSONEncoder().encode(out))
            } catch { return .error(502, "library fetch failed") }

        case ("GET", let p) where p.hasPrefix("/api/playlists/"):
            let id = String(p.dropFirst("/api/playlists/".count))
            guard id.wholeMatch(of: Self.idPattern) != nil else { return .error(400, "invalid playlistId") }
            let offset = max(0, Int(req.query["offset"] ?? "") ?? 0)
            let limit = min(200, max(1, Int(req.query["limit"] ?? "") ?? 100))
            do {
                let all = try await cache.tracks(playlistId: id) { try await self.library.playlistTracks(playlistId: id) }
                for t in all where !t.trackId.isEmpty { artwork.registerTrack(id: t.trackId) }
                let page = PlaylistPage(items: Array(all.dropFirst(offset).prefix(limit)), total: all.count, offset: offset)
                return ApiResponse(status: 200, body: try! JSONEncoder().encode(page))
            } catch { return .error(502, "library fetch failed") }

        case ("GET", "/api/queue"):
            do {
                let items = try await library.queueItems()
                let snap = QueueSnapshot(stateVersion: svc.state().stateVersion, items: items)
                return ApiResponse(status: 200, body: try! JSONEncoder().encode(snap))
            } catch { return .error(502, "queue fetch failed") }

        case ("POST", let p) where p.hasPrefix("/api/player/playlists/"):
            let id = String(p.dropFirst("/api/player/playlists/".count))
            guard id.wholeMatch(of: Self.idPattern) != nil else { return .error(400, "invalid playlistId") }
            return await command(req) { try await self.library.playPlaylist(playlistId: id) }

        case ("POST", let p) where p.hasPrefix("/api/queue/"):
            guard let pos = Int(p.dropFirst("/api/queue/".count)), (0..<1000).contains(pos) else {
                return .error(400, "invalid position")
            }
            return await queueJump(req, position: pos)

        case ("GET", let p) where p.hasPrefix("/api/artwork/"):
            let id = String(p.dropFirst("/api/artwork/".count))
            guard id.wholeMatch(of: Self.idPattern) != nil else { return .error(400, "invalid artwork id") }
            if let jpeg = await artwork.image(id: id) {
                return ApiResponse(status: 200, body: jpeg, contentType: "image/jpeg")
            }
            return .error(404, "unknown artwork")
```

queueJump (private 메서드 추가):

```swift
    /// spec §5: body에 기대 stateVersion 포함, 불일치 시 409. body는 정확히 {"commandId", "stateVersion"} 두 필드.
    private func queueJump(_ req: ApiRequest, position: Int) async -> ApiResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              obj.count == 2,
              let id = obj["commandId"] as? String, UUID(uuidString: id) != nil,
              let n = obj["stateVersion"] as? NSNumber, let expected = UInt64(exactly: n) else {
            return .error(400, "body must be exactly {\"commandId\": \"<uuid>\", \"stateVersion\": <n>}")
        }
        if let dup = store.cached(id) {
            return ApiResponse(status: 200, body: try! JSONEncoder().encode(dup))   // 재실행 없음 (spec §5)
        }
        guard expected == svc.state().stateVersion else {
            return .error(409, "stateVersion mismatch")     // 자동 곡 전환과의 경합 — 엉뚱한 곡 이동 방지
        }
        do {
            guard try await library.jumpQueue(position: position) else {
                return .error(409, "queue position gone")   // 검사 통과 후 DOM이 변한 경합 — 같은 의미의 409
            }
        } catch { return .error(502, "browser control failed") }   // 실행 여부 불명 — 캐시하지 않음
        svc.noteCommand()
        let resp = CommandResponse(stateVersion: svc.state().stateVersion, duplicate: false)
        store.record(id, resp)
        return ApiResponse(status: 200, body: try! JSONEncoder().encode(resp))
    }
```

주의: `store.cached(id)`가 반환하는 `CommandResponse`의 duplicate 처리 방식은 기존 `command()`와 동일하게 맞춘다 (기존 코드가 cached를 그대로 돌려주면 동일하게, duplicate=true로 변환해 돌려주면 동일하게 — **기존 command()의 실제 구현을 열어 확인하고 똑같이** 한다).

- [ ] **Step 5: StreamServer 수정**

`Handler.channelRead`의 `.end` 분기에서 uri를 분리:

```swift
            case .end:
                guard let h = head else { return }
                head = nil
                if h.uri == "/healthz" {
                    writeJSON(context.channel, status: .ok, body: Data(#"{"ok":true}"#.utf8))
                    return
                }
                let parts = h.uri.split(separator: "?", maxSplits: 1)
                let path = String(parts[0])
                var query: [String: String] = [:]
                if let items = URLComponents(string: h.uri)?.queryItems {
                    for it in items { query[it.name] = it.value ?? "" }
                }
                let req = ApiRequest(method: h.method.rawValue, path: path, body: body, query: query)
                let ch = context.channel
                let api = server.api
                Task {   // BrowserController가 async — NIO 이벤트 루프를 막지 않는다
                    let resp = await api?.handle(req) ?? ApiResponse(status: 404, body: Data(#"{"error":"unknown endpoint"}"#.utf8))
                    self.writeJSON(ch, status: .init(statusCode: resp.status), body: resp.body, contentType: resp.contentType)
                }
```

`writeJSON`에 contentType 파라미터 추가 (기본값으로 기존 호출부 무변경):

```swift
        private func writeJSON(_ ch: Channel, status: HTTPResponseStatus, body: Data,
                               contentType: String = "application/json") {
            ch.eventLoop.execute {
                var hdr = HTTPHeaders()
                hdr.add(name: "Content-Type", value: contentType)
                hdr.add(name: "Content-Length", value: "\(body.count)")
                // (이하 기존과 동일)
```

- [ ] **Step 6: 전체 테스트 통과 확인 후 Commit**

Run: `swift test 2>&1 | grep -E "Executed|error"` → 전부 PASS (기존 ControlAPITests 포함 — ApiRequest 기본 파라미터로 무수정 통과해야 함)

```bash
git add MacAgent/Sources/MacAgentCore/ControlAPI.swift MacAgent/Sources/MacAgentCore/StreamServer.swift MacAgent/Tests/MacAgentTests/ControlAPILibraryTests.swift
git commit -m "feat: library/queue/artwork routes with stateVersion 409 queue jump (spec §5·§9)"
```

---

### Task 8: StreamServer Handler EmbeddedChannel 테스트 (Phase 1 백로그)

**Files:**
- Modify: `MacAgent/Sources/MacAgentCore/StreamServer.swift` (Handler를 `private final class` → `final class`로 — @testable 접근)
- Test: `MacAgent/Tests/MacAgentTests/StreamServerHandlerTests.swift` (신규)

**Interfaces:**
- Consumes: Task 7 이후의 Handler (query 분리 포함)
- Produces: 없음 (테스트만)

**범위 ruling:** async `Task` 홉을 타는 API 디스패치 경로는 EmbeddedChannel에서 불안정하므로 제외 — ControlAPI 단위 테스트가 커버한다. 여기서는 동기 경로만: healthz, 413, /audio/live 수신자 등록·broadcast·단일 수신자 교체.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import MacAgentCore

final class StreamServerHandlerTests: XCTestCase {
    private func makeChannel(_ server: StreamServer) -> EmbeddedChannel {
        EmbeddedChannel(handler: StreamServer.Handler(server: server))
    }
    private func head(_ method: HTTPMethod, _ uri: String) -> HTTPServerRequestPart {
        .head(.init(version: .http1_1, method: method, uri: uri))
    }
    private func readHead(_ ch: EmbeddedChannel) throws -> HTTPResponseHead? {
        ch.embeddedEventLoop.run()
        guard case .some(.head(let h)) = try ch.readOutbound(as: HTTPServerResponsePart.self) else { return nil }
        return h
    }
    private func readBodyData(_ ch: EmbeddedChannel) throws -> Data? {
        ch.embeddedEventLoop.run()
        guard case .some(.body(.byteBuffer(var buf))) = try ch.readOutbound(as: HTTPServerResponsePart.self) else { return nil }
        return buf.readData(length: buf.readableBytes)
    }

    func testHealthz() throws {
        let ch = makeChannel(StreamServer(port: 0))
        try ch.writeInbound(head(.GET, "/healthz"))
        try ch.writeInbound(HTTPServerRequestPart.end(nil))
        XCTAssertEqual(try readHead(ch)?.status, .ok)
        XCTAssertEqual(try readBodyData(ch), Data(#"{"ok":true}"#.utf8))
    }

    func testOversizedBodyIs413() throws {
        let ch = makeChannel(StreamServer(port: 0))
        try ch.writeInbound(head(.POST, "/api/player/play"))
        var big = ch.allocator.buffer(capacity: 5000)
        big.writeBytes([UInt8](repeating: 0x41, count: 5000))    // maxBody 4096 초과
        try ch.writeInbound(HTTPServerRequestPart.body(big))
        XCTAssertEqual(try readHead(ch)?.status, .payloadTooLarge)
    }

    func testAudioLiveRegistersReceiverAndStreams() throws {
        let server = StreamServer(port: 0)
        let ch = makeChannel(server)
        try ch.writeInbound(head(.GET, "/audio/live"))
        let h = try readHead(ch)
        XCTAssertEqual(h?.status, .ok)
        XCTAssertEqual(h?.headers.first(name: "Content-Type"), "application/octet-stream")
        server.broadcast(Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(try readBodyData(ch), Data([0x01, 0x02, 0x03]))
    }

    func testSecondReceiverDisplacesFirst() throws {
        let server = StreamServer(port: 0)
        let ch1 = makeChannel(server)
        try ch1.writeInbound(head(.GET, "/audio/live"))
        _ = try readHead(ch1)
        let ch2 = makeChannel(server)
        try ch2.writeInbound(head(.GET, "/audio/live"))
        _ = try readHead(ch2)
        ch1.embeddedEventLoop.run(); ch2.embeddedEventLoop.run()
        XCTAssertFalse(ch1.isActive)               // 단일 수신자 (spec §6) — 이전 연결 종료
        server.broadcast(Data([0x09]))
        XCTAssertEqual(try readBodyData(ch2), Data([0x09]))
        XCTAssertNil(try? ch1.readOutbound(as: HTTPServerResponsePart.self) as Any?)
    }
}
```

- [ ] **Step 2: 실행 — 실패 확인**

Run: `swift test --filter StreamServerHandlerTests 2>&1 | grep -E "error|Executed"`
Expected: 컴파일 에러 (`Handler` private)

- [ ] **Step 3: Handler 가시성 변경**

`StreamServer.swift`의 `private final class Handler` → `final class Handler` (같은 파일 내 중첩 타입 유지, 다른 변경 없음).

- [ ] **Step 4: 실행 — 통과 확인**

Run: `swift test --filter StreamServerHandlerTests 2>&1 | grep -E "Executed|error"`
Expected: PASS. `broadcast`는 `ch.eventLoop.execute`를 쓰므로 각 assert 전 `embeddedEventLoop.run()`이 돌게 되어 있다(helper에 포함). flaky하면 run() 호출을 명시적으로 늘린다 — sleep은 금지.

- [ ] **Step 5: Commit**

```bash
git add MacAgent/Sources/MacAgentCore/StreamServer.swift MacAgent/Tests/MacAgentTests/StreamServerHandlerTests.swift
git commit -m "test: NIO Handler EmbeddedChannel coverage (healthz/413/audio-live single receiver)"
```

---

### Task 9: 조립 + 라이브 체크포인트

**Files:**
- Modify: `MacAgent/Sources/MacAgent/main.swift:57-60` (조립)
- Modify: `status.json` (체크포인트 결과 기록 — `python3 scripts/update_status.py`)

**Interfaces:**
- Consumes: 전부

- [ ] **Step 1: 조립**

`main.swift`의 serve 조립부를:

```swift
    let cdp = CDPClient()
    let controller = BrowserController(cdp: cdp)
    let svc = PlayerStateService()
    server.api = ControlAPI(store: CommandStore(), svc: svc, controller: controller,
                            library: controller, cache: MetadataCache(), artwork: ArtworkService())
```

- [ ] **Step 2: 빌드·전체 테스트**

Run: `cd MacAgent && swift build && swift test 2>&1 | grep -E "Executed|error"`
Expected: 빌드 성공, 전 테스트 PASS

- [ ] **Step 3: Commit**

```bash
git add MacAgent/Sources/MacAgent/main.swift
git commit -m "feat: wire library/cache/artwork into serve"
```

- [ ] **Step 4: 라이브 체크포인트 (사람 개입 — serve는 사용자 Terminal.app에서 재시작)**

전제: launch-chrome-ytm.sh Chrome 실행 중 + serve 재시작(TCC 때문에 Terminal.app에서: `cd .../MacAgent; swift run MacAgent serve`). curl은 127.0.0.1:8080 직결(mTLS 우회, API만 — `/audio/live`는 건드리지 않는다: Watch 수신자를 뺏는다).

체크리스트 (각 항목 실패 시 YTMSelectors 스니펫을 DevTools에서 실측·수정 — 단일 수정 지점):

```bash
# 1. 플레이리스트 목록 — 실제 라이브러리와 대조
curl -s 127.0.0.1:8080/api/playlists | python3 -m json.tool
# 2. 트랙 목록 + 페이지네이션
curl -s "127.0.0.1:8080/api/playlists/<위에서 얻은 id>?offset=0&limit=5" | python3 -m json.tool
# 3. Queue 조회 — current가 실제 재생 곡과 일치하는지
curl -s 127.0.0.1:8080/api/queue | python3 -m json.tool
# 4. Playlist 전체 재생 — Mac에서 실제 재생 시작 확인
curl -s -X POST 127.0.0.1:8080/api/player/playlists/<id> -d "{\"commandId\": \"$(uuidgen)\"}"
# 5. Queue 이동 — stateVersion은 3번 응답에서
curl -s -X POST 127.0.0.1:8080/api/queue/2 -d "{\"commandId\": \"$(uuidgen)\", \"stateVersion\": <sv>}"
# 6. 409 — 일부러 낡은 stateVersion
curl -s -X POST 127.0.0.1:8080/api/queue/2 -d "{\"commandId\": \"$(uuidgen)\", \"stateVersion\": 1}" -w "%{http_code}"
# 7. Artwork — JPEG 확인 (1번 이후 등록됨)
curl -s 127.0.0.1:8080/api/artwork/<playlistId> -o /tmp/art.jpg && file /tmp/art.jpg && sips -g pixelWidth /tmp/art.jpg
# 8. 거부: 잘못된 id·position·body
curl -s -o /dev/null -w "%{http_code}\n" "127.0.0.1:8080/api/playlists/bad\$id"        # 400
curl -s -o /dev/null -w "%{http_code}\n" -X POST 127.0.0.1:8080/api/queue/99999 -d '{}' # 400
curl -s -o /dev/null -w "%{http_code}\n" 127.0.0.1:8080/api/artwork/nope                # 404
```

- [ ] **Step 5: 스니펫 수정이 있었으면 커밋, status.json 갱신 후 커밋**

```bash
git add -A && git commit -m "fix: YTM selectors adjusted from live checkpoint" # 수정이 있을 때만
python3 scripts/update_status.py 9 done "라이브 체크포인트 통과"
git add status.json && git commit -m "chore: phase2 checkpoint status"
```

---

## Self-Review

- **스펙 커버리지**: §5 신규 엔드포인트 4종(GET playlists/playlists/{id}/queue, POST player/playlists/{id}·queue/{position}) → T3·T4·T7 ✓. §5 queue 409 → T7 ✓ (테스트 3종: 불일치·소멸·중복). §8 Playlist 전체 재생·Queue 이동 → T4 ✓. §9 캐시 대상 필드(playlistId/title/thumbnail/trackCount, trackId/title/artist/duration) → T1·T3 ✓, artwork 128px 프록시 → T6 ✓, 대용량 offset/limit + unavailable 플래그 → T3·T7 ✓ (continuation 미지원은 설계 결정 2로 명시). §11 id 검증·allow-list 유지 → T7 ✓. §19 Queue 곡 선택 시 이동 → T4 ✓ (UI는 Phase 5). §23 Phase 2 정의(Playlist 조회·Track 조회·Metadata Cache) 전부 커버 ✓.
- **플레이스홀더 스캔**: 전 태스크 코드 블록 완결 확인 ✓ (queueSnapshot title 줄의 초안 임시 표기는 작성 시점에 정리 완료).
- **타입 일관성**: `LibraryProviding` 5개 메서드 시그니처가 T3 선언 = T4 구현 = T7 mock 일치 ✓. `ApiRequest.query`/`ApiResponse.contentType` 기본값으로 기존 테스트 무수정 통과 ✓. `PlaylistInfo.thumbnailUrl`은 wire 모델(PlaylistSummary)에 미노출 ✓. `idPattern` rename은 T7에서 기존 참조 일괄 변경 지시 ✓.
- **알려진 리스크**: innertube 응답 구조·queue DOM 셀렉터는 실측 전 미확정 — T9 체크포인트에서 검증하고 YTMSelectors 단일 수정 지점으로 흡수. `store.cached` duplicate 의미는 T7에 기존 구현 확인 지시를 명시.

## Execution

권장 순서: T1 → T2 → T3 → T4 → (T5 ∥ T6 ∥ T8) → T7 → T9.
(T5·T6·T8은 서로 파일이 겹치지 않으나, SDD는 구현자 병렬 dispatch를 금지하므로 순차 실행 — 병렬은 리뷰만.)

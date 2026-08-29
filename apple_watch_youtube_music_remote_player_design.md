# Apple Watch YouTube Music Remote Player — 최종 설계안

## 1. 프로젝트 목표

Apple Watch Series 7 Cellular 41mm에서 iPhone 없이 LTE/Wi‑Fi만으로 집의 Mac에서 재생 중인 YouTube Music을 원격 제어하고, Mac의 오디오를 Watch로 실시간 스트리밍하여 Bluetooth 이어폰으로 청취한다.

본 프로젝트는 **순수 개인용**이며 공개 배포를 목표로 하지 않는다. watchOS 앱은 개발자 본인 기기에 직접 설치(무료 계정 기준 7일 주기 재서명)하여 사용한다.

### 핵심 사용자 경험

- Watch에서 YouTube Music 재생목록 조회
- 재생목록 진입/이탈
- 재생목록 내 곡 목록 조회
- 특정 곡 선택 후 즉시 재생 요청
- 이전 곡 / 다음 곡 / 재생 / 일시정지
- 현재 재생 곡 정보 확인
- 재생 대기열(Queue) 확인 및 특정 곡 이동
- Mac에서 재생되는 오디오를 Watch로 스트리밍
- Watch에 직접 연결된 AirPods/블루투스 이어폰으로 청취
- iPhone 없이 Cellular Watch 단독 사용

---

## 2. 핵심 설계 원칙

1. **Mac의 YouTube Music Web Player가 실제 Player이자 유일한 Source of Truth**이다. Agent는 그 상태의 관찰자·중계자일 뿐 별도의 권위 상태를 갖지 않는다.
2. Watch는 `Library Browser + Remote Controller + Audio Receiver` 역할을 한다.
3. 별도 클라우드 애플리케이션 서버는 두지 않는다.
4. Watch와 Mac 사이 제어와 미디어 전송을 분리한다.
5. 외부에는 공유기의 **단일 TCP 포트만 공개**한다.
6. 공개 endpoint는 반드시 **HTTPS + mTLS**를 적용한다.
7. RemotePlayerAgent는 외부 인터페이스에 직접 노출하지 않는다.
8. 오디오는 곡마다 연결을 새로 만들지 않고 **지속적인 Live Audio Stream**을 유지한다.
9. UI는 Apple Music watchOS의 interaction grammar를 참고하되 41mm에 맞춰 단순화한다.
10. 정상 상태는 숨기고 오류/연결 이상만 명확하게 표시한다.

---

## 3. 전체 아키텍처

```text
┌──────────────── Apple Watch Series 7 Cellular ────────────────┐
│ SwiftUI                                                       │
│                                                               │
│ ├─ Playlists                                                  │
│ ├─ Playlist / Tracks                                          │
│ ├─ Now Playing                                                │
│ ├─ Queue                                                      │
│ ├─ Player Controls                                            │
│ └─ Audio Player                                               │
└────────────────────────┬──────────────────────────────────────┘
                         │
                         │ LTE / Wi‑Fi
                         │ HTTPS + mTLS
                         ▼
                youtumu.duckdns.org:8443
                         │
                         ▼
┌────────────────── KT GiGA WiFi 공유기 ────────────────────────┐
│ DuckDNS (Mac launchd 업데이터가 5분 주기로 IP 갱신)           │
│ Public TCP 8443                                               │
│      ↓ Port Forward                                           │
│ Mac 내부 IP:8443                                              │
└────────────────────────┬──────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────── Mac ──────────────────────────────────┐
│ Caddy :8443                                                    │
│ ├─ TLS termination                                            │
│ ├─ mTLS require + verify                                      │
│ ├─ timeout / connection protection                            │
│ └─ reverse proxy                                              │
│          ↓                                                    │
│ RemotePlayerAgent : 127.0.0.1:8080                            │
│ ├─ REST API                                                   │
│ ├─ Player State                                               │
│ ├─ Playlist Cache                                             │
│ ├─ YouTube Music Controller                                   │
│ ├─ Audio Capture                                              │
│ └─ Audio Encoder / Stream                                     │
│          ↓                                                    │
│ Chrome / YouTube Music                                        │
└───────────────────────────────────────────────────────────────┘
```

---

## 4. 네트워크 구성

### 4.1 DDNS

DuckDNS를 사용한다. 공유기(KT GiGA WiFi)에는 DDNS 기능이 없으므로 Mac의 launchd 에이전트(`com.youtumu.duckdns`)가 5분 주기로 공인 IP를 갱신한다. 토큰은 `~/.youtumu-duckdns`(chmod 600)에만 보관한다.

```text
youtumu.duckdns.org (DuckDNS)
       ↓
현재 집 Public IP
       ↓
KT GiGA WiFi Router
```

Watch 앱에는 공인 IP를 하드코딩하지 않고 DDNS hostname만 설정한다.

### 4.2 Port Forwarding

공유기에는 서비스용 TCP 포트 **하나만** 공개한다.

현재 구성:

```text
Internet TCP 8443
        ↓
KT GiGA WiFi
        ↓
Mac 172.30.1.15:8443
```

Mac 내부 IP는 DHCP 고정 할당 또는 수동 고정한다.

### 4.3 사전 확인

공유기 WAN IP가 실제 공인 IP인지 확인한다. (2026-08 확인: 공인 IP 직할당, CGNAT 아님, NAT loopback 지원)

- `10.0.0.0/8`
- `172.16.0.0/12`
- `192.168.0.0/16`
- `100.64.0.0/10` (CGNAT 전용 대역)

등이면 이중 NAT/CGNAT 가능성이 있으므로 직접 inbound 구조를 다시 검토해야 한다.

추가 확인 사항:

- **IPv6**: 공유기가 IPv6를 통과시키면 port forwarding과 무관하게 Mac이 직접 노출될 수 있다. 공유기 IPv6 방화벽 정책을 확인한다 (§12)
- **NAT loopback**: 집 Wi‑Fi에서 DDNS hostname으로 접속하려면 공유기의 NAT loopback(hairpin) 지원이 필요하다. 미지원이면 Watch 앱이 LAN 주소로 fallback한다 (Server Leaf SAN에 LAN 주소가 포함된 이유, §10.1)

---

## 5. 통신 프로토콜

### Control Plane

Watch → Mac 제어는 **HTTPS REST**를 기본으로 한다.

```text
GET  /api/playlists
GET  /api/playlists/{playlistId}
GET  /api/player
GET  /api/queue

POST /api/player/play
POST /api/player/pause
POST /api/player/next
POST /api/player/previous
POST /api/player/tracks/{trackId}
POST /api/player/playlists/{playlistId}   # Playlist 전체 재생
POST /api/queue/{position}                # Queue 이동 — 중복 곡이 있으므로 trackId가 아닌 position 기준
```

### 명령 멱등성

`NEXT`/`PREVIOUS`는 비멱등 명령이다. 응답이 유실된 뒤 재시도하면 두 곡을 건너뛴다.

- 모든 POST 명령에 클라이언트 생성 `commandId`(UUID)를 포함한다
- Agent는 최근 commandId를 기억하고, 중복 수신 시 재실행하지 않고 이전 결과를 반환한다
- `GET /api/player` 응답에 단조 증가 `stateVersion`을 포함한다
- Watch는 낮은 stateVersion의 polling 응답으로 최신 상태를 덮지 않는다 (빠른 연속 탭 시 응답 역전 방지)
- `POST /api/queue/{position}`은 요청에 기대 `stateVersion`을 포함하고, 불일치 시 409로 거부한다 (자동 곡 전환과의 경합으로 엉뚱한 곡으로 이동하는 것 방지)

오류 규약: 4xx = 요청 거부(재시도 무의미), 5xx/timeout = 실행 여부 불명 → `GET /api/player`로 reconcile 후 필요 시 재시도.

초기 버전에서는 WebSocket을 필수 의존성으로 사용하지 않는다.

Now Playing 상태 동기화는 필요 시 짧은 polling을 사용하고, 실제 Watch에서 장시간 오디오 스트리밍과 WebSocket의 안정성이 검증된 이후 Push 방식으로 개선한다.

### Media Plane

오디오는 Control Plane과 완전히 분리한다.

```text
GET /audio/live
```

개념적으로:

```text
YouTube Music
      ↓
Mac Audio Capture
      ↓
AAC Encoder
      ↓
Continuous Live Stream
      ↓
HTTPS + mTLS
      ↓
Apple Watch
      ↓
AirPods
```

### 지속 스트림 원칙

곡이 바뀔 때 Watch가 새로운 스트림에 다시 접속하지 않는다.

```text
Watch ───────── GET /audio/live ───────── Mac
                  연결 유지

Watch → POST /next
Mac → YouTube Music 다음 곡

기존 /audio/live 안에서 새로운 곡이 이어짐
곡 경계의 discontinuity 마커로 Watch가 버퍼를 즉시 flush (§6 스트림 프로토콜)
```

이를 통해 TCP/TLS 재연결, 플레이어 재생성, 초기 buffering 비용을 최소화한다.

---

## 6. 오디오 스트리밍 전략

### 우선 검토 순서

1. **Continuous AAC Stream — PoC 1순위**
2. Low-Latency HLS — fallback 후보
3. 일반 HLS — 안정성 우선 fallback

### Continuous AAC를 우선하는 이유

- 곡 전환 latency 최소화
- segment/manifest 갱신 과정 없음
- 하나의 지속 연결 유지 가능
- 개인 사용자 1명이라는 조건에 적합

### 스트림 프로토콜

Continuous AAC는 "그냥 이어 붙인 오디오"가 아니라 최소한의 프레이밍 규약을 갖는다.

**Wire format** — ADTS에는 대역 내 마커를 넣을 표준 방법이 없으므로 얇은 envelope을 씌운다.

```text
[ type(1B) | length(2B) | payload ]

type 0x01  AUDIO   — ADTS AAC 프레임
type 0x02  MARKER  — { seq, trackId, cause: command | natural | encoder }
```

- **metadata ↔ audio 대응**: MARKER의 trackId로 "지금 들리는 곡"과 "화면에 표시된 곡"의 일치를 판별한다
- **버퍼 flush 분기**: `cause = command`(사용자가 곡을 바꿈)일 때만 재생 버퍼를 비운다. `natural`(곡이 자연히 끝남)은 flush하지 않는다 — 버퍼에 남은 직전 곡의 마지막 구간은 잘라낼 것이 아니라 재생해야 할 소리다
- **재접속**: 항상 live edge부터 시작한다 — 누락 구간은 재생하지 않는다 (LTE↔Wi‑Fi 전환 시 TCP 연결 유지를 기대하지 않으며, 끊기면 이 규칙으로 재동기화한다)
- **단일 수신자**: `/audio/live`는 동시 1연결만 허용하며, 새 연결이 들어오면 이전 연결을 종료한다 (앱 재시작·네트워크 전환 후 유령 연결 정리)

### 지연 모델

소스가 실시간 캡처이므로 서버는 실시간보다 빨리 보낼 수 없다. 따라서 **클라이언트 버퍼 = live 대비 재생 지연**이며, flush/재접속 직후 버퍼는 0에서 시작하고 저절로 다시 차오르지 않는다 (지연은 stall을 통해서만 쌓인다). "여유 버퍼"와 "낮은 전환 latency"는 같은 자원을 두고 경쟁한다.

- flush/재접속 직후: **약 1초 pre-buffer 후 재생 시작** — 이 값이 전환 latency의 하한이자 jitter 마진이다
- 이후 목표 지연(2~3초)까지 미세 time-stretch(~2%)로 점진 축적할지는 PoC 청감 테스트로 결정한다
- pre-buffer와 목표 지연은 곡 전환 p95와 stall 기준(§24)을 함께 놓고 실측 튜닝한다

### Pause 정책

무음을 계속 보내면 LTE radio가 계속 깨어 있어 배터리를 소모한다.

- Pause 후 10초까지는 무음 프레임 유지 (짧은 일시정지의 즉시 재개)
- 10초 경과 시 송신 중단 (연결은 유지) → Resume 시 재접속과 동일하게 live edge + pre-buffer로 복귀

### Watch 플레이어 구현

AVPlayer는 TLS client certificate를 제시할 지원 경로가 없고 버퍼 flush도 제어할 수 없다. 따라서 커스텀 플레이어로 확정한다.

```text
URLSession (mTLS client identity)
      ↓
envelope 파싱 (AUDIO / MARKER)
      ↓
AudioConverter (AAC decode)
      ↓
AVAudioEngine 재생 (.longFormAudio 세션)
```

- Control과 Media는 **별도 URLSession(별도 TCP 연결)**을 사용한다 — 같은 연결을 공유하면 오디오 flow-control 정체가 제어 명령을 지연시킨다 (head-of-line blocking, 원칙 4의 근거)
- `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` 연동: AirPods 스템 입력(play/pause/next)을 REST 명령으로 브릿지한다

### 목표

```text
Next 버튼 입력
   ↓
Mac Player 변경
   ↓
Watch에서 실제 다음 곡 청취

목표: 약 1 ~ 2초 (지연 모델의 pre-buffer가 하한)
```

너무 작은 버퍼는 LTE 변동에서 stall을 증가시키고, 너무 큰 버퍼는 제어 반응을 느리게 하므로 실제 Watch LTE 테스트를 통해 결정한다.

### PoC 측정 항목

- 최초 재생 시작 시간
- 평균 audio latency
- Next → 실제 오디오 변경 시간
- 30~60분 연속 재생 시 stall 횟수
- LTE 환경에서 reconnect 시간
- LTE ↔ Wi‑Fi 전환 시 복구
- 화면 OFF 상태의 백그라운드 재생
- AirPods 연결 변경 시 동작
- 배터리·셀룰러 데이터 소모 (60분 연속 재생 기준)

---

## 7. Mac RemotePlayerAgent

Mac Agent가 애플리케이션의 핵심이다.

### 주요 컴포넌트

```text
RemotePlayerAgent
│
├─ HTTP API
├─ Playlist Service
├─ Playlist Cache
├─ Player State Service
├─ Browser Controller
├─ Audio Capture
├─ Audio Encoder
└─ Stream Server
```

### Agent bind 정책

```text
❌ 0.0.0.0:8080
✅ 127.0.0.1:8080
```

인터넷에서 직접 접근할 수 있는 프로세스는 Caddy 하나만 둔다.

유일한 예외는 Enrollment 페어링 모드의 임시 LAN listener다 (§10.5, TTL 5분, WAN 비노출).

---

## 8. YouTube Music 제어

Mac의 로그인된 YouTube Music Web Player가 실제 Player이다.

```text
Watch command
     ↓
RemotePlayerAgent
     ↓
Browser Controller
     ↓
YouTube Music Web Player
```

지원 명령:

- Play
- Pause
- Next
- Previous
- 특정 Track 재생
- Playlist 전체 재생
- Queue 이동

### Source of Truth

서버 상태가 아니라 **실제 YouTube Music Player 상태**를 Source of Truth로 한다.

Mac에서 사용자가 직접 곡을 바꾸거나 자동으로 다음 곡이 재생될 수 있기 때문이다.

```text
YouTube Music
     ↓
Actual Player State
     ↓
RemotePlayerAgent
     ↓
Watch
```

---

## 9. Playlist / Metadata

Watch가 화면을 열 때마다 브라우저를 실시간 scraping하지 않는다.

```text
YouTube Music
      ↓
Metadata Sync
      ↓
Playlist Cache
      ↓
Watch REST API
```

캐시 대상:

```text
Playlist
- playlistId
- title
- thumbnail
- trackCount

Track
- trackId
- title
- artist
- duration
- artwork(optional)
```

초기 버전은 별도 DB가 필요하지 않으며 메모리 또는 SQLite 수준이면 충분하다.

### Artwork

Watch는 Google CDN에 직접 접근하지 않는다. Agent가 리사이즈(~128px)·캐시하여 `GET /api/artwork/{id}`로 제공한다 — Watch의 네트워크 경로를 단일 origin으로 유지한다.

### 대용량 Playlist

수백 곡 이상은 `?offset=&limit=` 페이지 단위로 제공한다. 삭제·재생 불가 곡은 metadata에 `unavailable` 플래그로 표시한다.

목표 서버 처리 시간:

```text
GET  /api/playlists       < 50ms
GET  /api/playlists/{id}  < 50ms
POST /api/player/*        < 100ms
```

---

## 10. 보안 아키텍처

### 10.0 핵심 결정

| 항목 | 결정 | 이유 |
|---|---|---|
| 인증서 체계 | **Private CA 일원화** — 서버·클라이언트 인증서 모두 자체 CA 발급 | Public CA(ACME)는 80/443 개방이 필요해 단일 포트 원칙과 충돌. 자체 CA 신뢰가 곧 pinning이므로 SPKI pinning 논의도 종결 |
| 서버 신뢰 기준 | 시스템 신뢰 저장소가 아닌 **앱 내장 CA 앵커** | 기기 프로파일 설치 불필요, 시스템 CA 목록과 무관하게 동작 |
| Watch 키 | **Secure Enclave** 생성, 비추출 | client key 탈취 시나리오(위협 2순위) 원천 차단 |
| 인증서 배포 | **LAN 전용 1회 Enrollment** | 부트스트랩 경로가 WAN에 노출되지 않음 |
| 유출 대응 | CRL/OCSP 없이 **CA 전체 교체(rotation)** | 클라이언트 1대 규모에서 가장 단순하고 확실한 revocation |

### 10.1 Trust Hierarchy

```text
Home Root CA  (ECDSA P-256, 10년, 오프라인 보관)
│
├─ Server Leaf   youtumu.duckdns.org        (820일 — Apple TLS 정책상 서버 인증서는 최대 825일)
│                SAN: DDNS hostname + LAN 주소(mDNS 또는 고정 IP)
│
└─ Client Leaf   watch-s7               (3년)
                 private key는 Watch Secure Enclave에만 존재
```

원칙:

- **유효한 leaf는 서버 1장 + 클라이언트 1장**을 운영 목표로 한다 — 갱신·재발급은 새 leaf가 이전 leaf를 대체한다. 단, CRL이 없으므로 교체된 leaf는 만료 전까지 암호학적으로 유효하다. 실제 무효화가 필요하면 §10.7의 CA rotation을 쓴다
- 중간 CA 없음
- leaf 프로파일 고정: Server = EKU `serverAuth`, Client = EKU `clientAuth`, 둘 다 `BasicConstraints CA:false` — Caddy와 Watch 모두 체인뿐 아니라 용도(EKU)까지 검증한다 (같은 CA 발급 leaf의 교차 사용 차단)
- CA private key는 발급/갱신 순간에만 사용하고 평소에는 암호화 오프라인 보관 (Mac 상시 저장 금지)
- Server Leaf SAN: DDNS hostname은 DNS SAN, LAN 접속 주소는 실제 접속 형태에 맞춰 IP SAN(고정 IP 접속) 또는 DNS SAN(mDNS 이름 접속)으로 넣는다 — Enrollment와 NAT loopback fallback 시 hostname 검증이 성립하는 근거

### 10.2 Trust Boundary

```text
Internet
    ↓
[ UNTRUSTED — client cert 없으면 TLS 핸드셰이크에서 종료 ]
    ↓
Caddy :8443
  ├─ TLS 1.3 only
  ├─ client_auth require_and_verify  (trust = Home Root CA)
  ├─ SNI / Host = DDNS hostname + LAN 이름 허용 (LAN 이름은 NAT loopback fallback용, §4.3)
  └─ timeout / body size / per-IP connection 제한
    ↓
[ AUTHENTICATED WATCH ]
    ↓
RemotePlayerAgent 127.0.0.1:8080
```

미인증 관측자 관점:

- 포트 스캔으로는 "TLS 서비스 존재"까지만 확인 가능
- client certificate 없이는 핸드셰이크가 완료되지 않으므로 HTTP 표면 노출은 0
- 인증 실패는 애플리케이션 계층이 아니라 TLS 계층에서 끝난다

**iOS/watchOS 클라이언트 제약 (실기기 검증으로 확정, 2026-08):**
- **HTTP/3 비활성 필수**: Caddy `servers { protocols h1 h2 }`. iOS는 h3 연결에서 URLSession 델리게이트의 신뢰 승인과 별개로 시스템 신뢰 평가를 강제하므로 사설 CA가 -9802로 거부됨.
- **ATS 예외 필수**: 공개 도메인(duckdns.org)에는 ATS가 시스템 신뢰 평가를 강제(`.local`은 비적용). Info.plist `NSAppTransportSecurity → NSExceptionDomains → duckdns.org (NSIncludesSubdomains, NSExceptionAllowsInsecureHTTPLoads)` 선언. 델리게이트의 CA 핀닝(§10.3)이 그대로 강제되므로 실질 보안 저하 없음.
- 서버 인증서 유효기간 ≤825일 (Apple TLS 정책, §10.6).

### 10.3 서버 인증 — Watch가 Mac을 검증

- Watch 앱 번들에 Home Root CA 인증서를 내장
- URLSession challenge에서 서버 체인을 **내장 CA만으로 평가** (시스템 CA 무시)
- hostname 검증 유지

효과: DDNS 하이재킹, 라우터 DNS 변조, 중간자 시나리오에서 공격자가 어떤 공인 CA 인증서를 제시해도 연결이 성립하지 않는다.

### 10.4 클라이언트 인증 — Mac이 Watch를 검증

- P-256 키를 Watch **Secure Enclave**에서 생성 (`kSecAttrTokenIDSecureEnclave`) — 비추출
- 발급받은 인증서는 Keychain 보관, `SecIdentity`로 URLSession client certificate challenge에 응답

금지:

```text
Resources/client.p12
Git repository
source code
plain file
```

### 10.5 Enrollment — 최초 1회, LAN 전용

```text
[사용자] 오프라인 보관 중인 CA key를 Mac에 연결·복호화 (이 순간에만 존재)

[Mac]   Agent 페어링 모드 시작
        ├─ 특정 LAN IPv4 주소에만 bind, IPv6 listener 없음 (포트포워딩 대상 아님 → WAN 비노출)
        ├─ TTL 5분
        └─ 6자리 페어링 코드를 Mac 화면에 표시

[Watch] Secure Enclave 키 생성 → CSR 생성

[Watch → Mac(LAN)] CSR + 페어링 코드 전송
        └─ 이 시점에도 서버 인증은 내장 CA로 정상 수행 (SAN의 LAN 주소 사용)

[Mac]   코드 검증 → CSR 검증·서명 → Client Leaf 반환 → 페어링 모드 자동 종료

[사용자] CA key 제거 (오프라인 보관 복귀)

[Watch] 인증서 저장 → 이후 모든 통신은 mTLS
```

- Enrollment는 자동화하지 않는 **의도적인 수동 의식(ceremony)**이다 — CA key가 Mac에 존재하는 시간을 이 절차 동안으로 한정한다
- CSR 검증: 서명 검증(proof-of-possession) + key type은 P-256만 허용
- 페어링 코드는 1회용이며, 5회 실패 시 페어링 모드를 즉시 종료한다 (재시도 = 처음부터)
- Watch의 Mac 주소는 앱 설정에 수동 입력을 기본으로 한다 (Bonjour 탐색은 Local Network 권한이 필요하므로 선택 사항)
- 재발급(만료·기기 교체)도 동일 절차를 다시 수행한다
- Enrollment 실패/미완료 시 남는 상태가 없어야 한다 (코드 만료 = 서명 불가)

### 10.6 인증서 수명주기

| 대상 | 유효기간 | 갱신 방법 |
|---|---|---|
| Home Root CA | 10년 | 사실상 갱신 없음 |
| Server Leaf | 820일 (Apple TLS 정책: 서버 인증서 ≤825일 — 초과 시 watchOS가 OtherTrustValidityPeriod로 거부) | CA로 재발급 후 Caddy reload |
| Client Leaf | 3년 | LAN Enrollment 재수행 |

앱 내장 CA 기준이므로 공인 CA의 유효기간 제한과 무관하게 길게 가져갈 수 있고, 운영 부담은 연 1회 미만이다.

### 10.7 유출·침해 대응

| 시나리오 | 대응 |
|---|---|
| Watch 분실 / client key 유출 의심 | **CA rotation**: 새 CA 생성 → 서버 재발급 → 앱에 새 CA 내장 후 재빌드·재설치 → 재-Enrollment. 신뢰 앵커 교체로 기존 인증서 전부 즉시 무효화 |
| CA key 유출 의심 | 동일 — CA rotation |
| Mac 자체 침해 | 위협 모델 1순위이자 신뢰의 근원 — 아키텍처로 방어 불가. 침해 시 YouTube 세션·서버 key·오디오는 탈취될 수 있다. CA key 오프라인 보관이 막는 것은 **공격자의 추가 클라이언트 인증서 발급**뿐이다 |

- CA rotation은 **앱 재빌드·재설치를 수반**한다 (내장 신뢰 앵커 교체). 어차피 7일 주기 재서명 배포 체제이므로 실질 부담이 낮아 수용한다
- 더 외과적인 대안: Caddy에서 client leaf를 직접 allow-list(`trusted_leaf_cert`)하면 CA 교체 없이 특정 leaf만 폐기할 수 있다 — 클라이언트 기기가 늘어나면 이 방식으로 전환한다
- 클라이언트가 1대이므로 CRL/OCSP 인프라는 두지 않는다

### 10.8 배포 자가 점검

배포·설정 변경 후 다음을 확인하는 것을 성공 기준 10번의 검증 방법으로 사용한다.

```text
1. 인증서 없는 curl → TLS 핸드셰이크 단계에서 실패해야 함
2. 임의 self-signed client cert → 검증 실패해야 함
3. 정상 Watch cert → 200 응답
```

---

## 11. API 보안 — 심층 방어

mTLS 뒤에 있다고 API validation을 생략하지 않는다. TLS 계층이 뚫리거나 설정 오류가 나도 애플리케이션 계층이 한 번 더 막는다.

### Command Allow-list

```text
PLAY
PAUSE
NEXT
PREVIOUS
PLAY_TRACK
PLAY_PLAYLIST
```

같은 명확한 명령만 허용한다.

금지 구조:

```text
POST /execute
{
  "command": "arbitrary shell command"
}
```

### 입력 검증

- `trackId` / `playlistId`는 형식 검증 후에만 사용: `^[A-Za-z0-9_-]{1,64}$`
- 정의되지 않은 필드·엔드포인트는 무시가 아니라 **거부**
- request body 크기 제한은 Caddy와 Agent **양쪽**에서 적용

### Browser Controller

Watch는 임의 URL이나 JavaScript를 전달하지 않는다.

```text
Watch → trackId
           ↓
Agent 내부 metadata lookup
           ↓
Browser Controller
```

- Chrome remote debugging(CDP)은 반드시 `127.0.0.1:9222`에만 bind
- 원격 제어 전용 Chrome 프로필을 분리해 개인 브라우징 세션과 격리 (CDP가 침해되어도 노출 범위는 YouTube Music 세션으로 한정)

---

## 12. 공유기 / Mac Hardening

### 공유기 (KT GiGA WiFi)

- 서비스 TCP 포트 1개만 Forward (Enrollment 포트는 절대 Forward하지 않음)
- DMZ OFF
- 외부 공유기 관리 OFF
- UPnP 불필요 시 OFF
- WPS 불필요 시 OFF
- 최신 firmware 유지
- 강한 관리자 비밀번호 사용

### Caddy

- TLS 1.3 only + mTLS `require_and_verify`
- connection timeout / idle timeout — 단, `/audio/live` 스트리밍 경로는 예외 (무한 응답 허용 + 응답 버퍼링 해제)
- request body size 제한
- per-IP connection/rate 제한
- Host/SNI validation — DDNS hostname·LAN 이름 외 기본 거부 (§10.2)
- 설정은 파일로 버전 관리 (수동 변경 금지 → §10.8 자가 점검과 세트)
- 실패한 TLS 핸드셰이크 로그 기록 (관찰용)

### Mac

- Agent `127.0.0.1` bind only — 이것이 1차 방어이다
- Browser debug `127.0.0.1` bind only
- macOS 방화벽은 보조 수단: 애플리케이션 방화벽은 **앱 단위** 차단이므로, 포트 단위 차단이 필요하면 pf 규칙을 사용한다
- IPv6: 공유기 IPv6 방화벽 정책을 확인하고, 불필요하면 Mac에서 IPv6 inbound를 차단한다 (port forwarding과 무관하게 직접 노출 가능, §4.3)
- Agent는 비관리자 계정으로 launchd 실행 (자동 재기동 겸용)
- 인증서 private key / YouTube session cookie는 로그 출력 금지
- 실패 핸드셰이크 로그는 rotation·용량 상한 설정 (로그로 디스크를 채우는 공격 방지)
- Server leaf private key, Chrome 프로필, 캐시 DB는 Agent 실행 계정만 읽을 수 있는 권한으로 저장
- CA private key는 Mac에 상시 보관하지 않음 (§10.1)

---

## 13. 위협 시나리오와 대응 통제

| # | 시나리오 | 대응 통제 | 잔여 위험 |
|---|---|---|---|
| 1 | **Mac 자체 침해** | 최소 권한 실행, 방화벽, CA key 오프라인 보관, 전용 Chrome 프로필 | **높음** — 신뢰의 근원이므로 아키텍처 외부 문제. OS 업데이트·일반 보안 수칙으로 관리 |
| 2 | Watch client key 탈취 | Secure Enclave 비추출 키 | 사실상 제거 — 기기 물리 탈취 + 잠금 해제 수준 필요, 그 경우 CA rotation |
| 3 | Agent command injection / Browser Controller 취약점 | Command allow-list, ID 형식 검증, trackId 간접 참조(임의 URL/JS 미수용) | 낮음 |
| 4 | Caddy/mTLS 설정 오류 | `require_and_verify` 명시, 설정 버전 관리, 배포 후 자가 점검(§10.8) | 낮음 — 오류가 나도 자가 점검에서 발견 |
| 5 | Router/DDNS 계정·firmware 취약점 | 하드닝 체크리스트 + 서버 신뢰가 앱 내장 CA라 DDNS가 하이재킹돼도 세션 성립 불가 | 낮음 — 기밀성 영향 없음, 가용성만 영향 |
| 6 | TLS handshake 기반 DoS | per-IP connection 제한, handshake timeout, 비표준 포트 | 수용 — 회선 소모형 DDoS는 방어 불가, 개인 서비스 특성상 표적 가능성 낮음 |
| 7 | Port scanning | client cert 없으면 TLS 계층에서 종료, HTTP 표면 0 | 수용 — "TLS 서비스 존재"만 노출 |
| 8 | IPv6 경로로 Mac 직접 노출 | 공유기 IPv6 방화벽 확인 + Mac IPv6 inbound 차단 + Agent/Enrollment는 IPv4 LAN 주소에만 bind | 낮음 |

mTLS는 인증되지 않은 API 접근을 매우 강하게 차단하지만 DDoS/회선 소모까지 방지하지는 못한다.

개인용 서비스의 공격 가능성과 복잡도를 고려했을 때 현재 구조는 수용 가능한 위험 수준을 목표로 한다.

---

# 14. watchOS UI/UX

## 디자인 방향

**Apple Music watchOS의 interaction grammar를 기반으로 하되 41mm에 최적화한다.**

핵심 원칙:

- Black background
- System typography
- SF Symbols
- 큰 Touch Target
- 한 화면 한 목적
- Artwork 중심
- 최소 텍스트
- Navigation depth 최대 약 3
- Digital Crown 적극 활용
- 정상 연결 상태는 숨김
- 오류만 명확히 표시

---

## 15. Navigation

```text
Playlists
   │
   ▼
Playlist / Tracks
   │
   ▼
Now Playing
   │
   └── Queue
```

### 앱 시작

```text
현재 음악 재생 중
→ Now Playing 바로 진입

재생 중이 아님
→ Playlists 진입
```

불필요한 Home 화면을 제거하여 조작 단계를 줄인다.

---

## 16. Playlists 화면

Playlist는 artwork를 적극적으로 사용한다.

```text
‹ Playlists

┌────┐
│ART │  Running
└────┘  42곡

┌────┐
│ART │  Night
└────┘  31곡

┌────┐
│ART │  Coding
└────┘  68곡
```

41mm에서는 한 화면에 많은 항목을 욱여넣지 않는다.

Digital Crown을 통한 빠른 스크롤을 기본 탐색 방식으로 사용한다.

---

## 17. Playlist 상세

Track list에서는 artwork를 제거하여 정보 밀도를 높인다.

```text
‹ Running

┌──────────────────┐
│   ▶ 전체 재생     │
└──────────────────┘

01  Someday
    The Strokes

02  Yellow
    Coldplay

03  Dreams
    The Cranberries
```

Row 전체가 하나의 큰 Touch Target이다.

초기 버전에서는 곡별 좋아요/메뉴 등 부가 버튼을 넣지 않는다.

---

## 18. Now Playing

가장 중요한 화면이다.

```text
┌─────────────────────┐
│ ‹                 ⋯ │
│                     │
│      ┌────────┐     │
│      │ Album  │     │
│      │  Art   │     │
│      └────────┘     │
│                     │
│       Someday       │
│    The Strokes      │
│                     │
│   ⏮     ❚❚     ⏭   │
│                     │
└─────────────────────┘
```

### Controls

- Previous
- Play / Pause — 가장 큰 Primary Action
- Next

초기 버전에서는 seek/progress bar를 필수로 넣지 않는다.

Mac이 실제 Player이고 41mm 공간을 고려하면 조작 버튼 크기와 가독성이 더 중요하다.

### Digital Crown

Now Playing에서는 Crown을 **Volume Control**에 사용한다.

```text
Digital Crown
      ↓
Watch audio volume
```

---

## 19. Queue

```text
‹ Playing Next

▶ Someday
  The Strokes

  Yellow
  Coldplay

  Dreams
  The Cranberries
```

곡을 선택하면 해당 Track으로 즉시 이동한다.

---

## 20. 네트워크 상태 UX

정상 상태에서는 네트워크 기술 정보를 노출하지 않는다.

표시하지 않는 정보:

- LTE
- mTLS
- AAC
- Server RTT

오류 발생 시에만 사용자에게 의미 있는 상태를 보여준다.

### Mac 연결 실패

```text
       ⚠︎

Mac에 연결할 수 없습니다.

       재시도
```

### Audio 연결 중

```text
Someday
The Strokes

Connecting…

⏮     ❚❚     ⏭
```

---

## 21. Optimistic UI

네트워크 응답을 기다린 뒤 화면을 변경하지 않는다.

### Track 선택

```text
Track Tap
   │
   ├─ 즉시 Now Playing 전환
   │
   └─ POST /player/tracks/{id}
                ↓
              성공
                │
              유지

              실패
                ↓
             오류 표시
```

### Next

```text
Tap ⏭
   ↓
다음 Track metadata 즉시 표시
   ↓
POST /next
   ↓
Mac Player 변경
   ↓
Audio Stream에서 실제 다음 곡 수신
```

단, 실제 Player State가 최종 Source of Truth이므로 optimistic state는 이후 Mac 상태와 reconcile한다.

---

# 22. 상태 모델

연결과 재생을 한 축에 섞지 않는다. Watch는 다음 축들을 **독립적으로** 관리한다.

```text
ControlLinkState          # REST 연결
- ok | degraded | down

AudioStreamState          # /audio/live 연결
- disconnected | connecting | streaming | stalled

PlaybackState             # Mac player 상태 (polling 결과)
- stopped | playing | paused

OutputRoute               # Watch 오디오 출력
- none | bluetooth

PlayerState               # 서버 상태 스냅샷
- stateVersion            # 단조 증가 — polling 응답 역전 방지 (§5)
- currentTrack
- queue (position 포함)
```

- `volume`은 Watch 로컬 출력 볼륨이며 Crown이 제어한다 — 서버 상태(PlayerState)에 속하지 않는다
- Mac의 실제 상태와 Watch의 optimistic state를 분리하고, stateVersion 비교로 reconcile한다
- optimistic 전환 실패 시 rollback 목적지는 **마지막으로 확인된 서버 상태**이다

---

# 23. MVP 범위

## Phase 0 — Kill-Risk PoC (다른 모든 Phase에 선행)

이 프로젝트를 폐기시킬 수 있는 가정들을 **실기기에서 먼저** 검증한다. 하나라도 실패하면 이후 Phase에 착수하지 않고 아키텍처를 재검토한다. 검증에 필요한 CA·스트림 서버·플레이어는 **버릴 각오의 최소 프로토타입**으로 만든다 (이름은 PoC지만 실공수가 가장 큰 Phase다).

- Watch 실기기: background audio + Cellular 단독 + continuous AAC 수신 + mTLS `SecIdentity`를 **한 묶음으로** 검증 (Simulator로 대체 불가)
- Secure Enclave 키 생성 → 인증서 결합 → URLSession client 인증이 watchOS에서 실제 동작하는지 확인
- Mac: Chrome 오디오 캡처 검증 — 캡처 API 선정, TCC 권한, 화면 잠금 상태 캡처, launchd 비관리자 실행과의 양립

## Phase 1 — Mac Player Control

- Mac Agent 실행
- YouTube Music 제어
- REST API
- Play/Pause/Next/Previous
- 특정 Track 재생

## Phase 2 — Library

- Playlist 조회
- Track 조회
- Metadata Cache

## Phase 3 — Audio

- Mac system/app audio capture (Phase 0 검증 결과 기반)
- AAC encode + discontinuity 마커 (§6 스트림 프로토콜)
- `/audio/live`
- Watch 커스텀 플레이어 (URLSession + AudioConverter + AVAudioEngine)
- 버퍼 flush / live-edge 재접속
- AirPods 출력

## Phase 4 — Security

- Private CA 구축 (Root + Server/Client Leaf)
- DuckDNS DDNS (Mac launchd 업데이터)
- Port Forwarding
- Caddy (TLS 1.3 + mTLS)
- Watch Secure Enclave 키 / Keychain
- LAN Enrollment 플로우
- 무인증서 접속 차단 자가 테스트 (§10.8)

## Phase 5 — watchOS UI

- Playlists
- Playlist Detail
- Now Playing
- Queue
- Crown Volume
- 오류 상태

## Phase 6 — Stability

- buffering tuning
- reconnect
- LTE ↔ Wi‑Fi handover
- background playback
- 60분 이상 soak test
- latency 측정 (p95 기준)
- 장애 복구 시나리오: Mac 재부팅, 공유기 재부팅, WAN IP 변경 후 자동 복구

---

# 24. MVP 성공 기준

다음 조건을 만족하면 1차 성공으로 본다. 기준은 측정 가능해야 한다.

1. iPhone 없이 Apple Watch Cellular만 사용
2. 외부 LTE에서 집 Mac에 안전하게 연결
3. Watch에서 Playlist 탐색 가능
4. Track 선택 가능
5. Play/Pause/Previous/Next 정상 동작 — 재시도 시 중복 실행 없음 (commandId 검증)
6. Mac YouTube Music 오디오가 Watch/AirPods에서 재생
7. 곡 전환 latency **p95 ≤ 2초** (Next 입력 → 다음 곡 오디오 청취)
8. 화면 OFF 후에도 재생 유지
9. 60분 연속 재생에서 자동 복구되지 않는 disconnect 0회, stall 누적 30초 미만
10. 보안 자가 점검 통과: §10.8 3항목 + 잘못된 hostname/다른 CA/만료 인증서 거부 + Enrollment 포트 WAN 접근 불가 + IPv6 직접 접근 불가
11. Mac 재부팅 후 사용자 개입 없이 전체 스택(Agent/Caddy/Chrome) 자동 복구

---

# 25. 현재 확정 사항과 미확정 사항

## 확정

- Mac을 실제 Player로 사용
- 별도 Cloud Application Server 없음
- DuckDNS DDNS (Mac launchd 업데이터)
- 단일 Port Forwarding
- Caddy reverse proxy
- HTTPS + mTLS
- Private CA 일원화 (Public CA / ACME 미사용)
- 서버 신뢰는 앱 내장 CA 앵커 기준 (= CA pinning)
- Watch 키는 Secure Enclave 생성·비추출
- 인증서 배포는 LAN 전용 1회 Enrollment
- Revocation은 CA rotation 방식
- Agent localhost bind
- Control REST / Audio 별도 stream
- 지속 Audio Stream + discontinuity 마커 / live-edge 재접속 (§6 스트림 프로토콜)
- Watch 오디오 플레이어는 URLSession 기반 커스텀 구현 (AVPlayer는 mTLS client identity 미지원)
- 명령 멱등성: commandId + stateVersion (§5)
- Apple Music 기반 41mm UX
- Playlist artwork 사용
- Track list artwork 제거
- Now Playing artwork 중심
- Crown volume

## PoC 후 확정

- Continuous AAC 최종 채택 여부
- 적정 audio bitrate
- 적정 buffer duration
- WebSocket 사용 여부
- 정확한 Player State polling interval
- Mac의 특정 앱 오디오 캡처 구현 방식
- YouTube Music metadata/controller 구현체

---

# 26. 최종 요약

이 프로젝트의 핵심은 YouTube Music을 Watch에서 직접 실행하는 것이 아니다.

**Mac의 로그인된 YouTube Music을 실제 Player로 유지하면서 Apple Watch를 초경량 Remote Music Client로 만드는 것**이다.

```text
             Control
Watch ───────────────────► Mac

             State
Watch ◄────────────────── Mac

             Audio
Watch ◄══════════════════ Mac
```

Watch는 사용자 경험만 담당하고 Mac은 복잡한 음악 재생, 인증 세션, 브라우저 제어 및 오디오 처리를 담당한다.

이 역할 분리를 통해 watchOS의 제한된 CPU/메모리/배터리 환경에서도 빠르고 단순한 앱을 만들 수 있으며, mTLS와 단일 공개 포트를 통해 개인용 서비스에 필요한 수준의 보안 경계도 유지한다.

최종 목표 UX는 **“Apple Music Watch 앱을 사용하는 것처럼 자연스럽지만 실제 재생 엔진은 집의 YouTube Music인 Remote Player”**이다.

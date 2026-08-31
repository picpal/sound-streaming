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
    @Published private(set) var browserDown = false      // §20 — serve는 살아있는데 Chrome/YTM 탭이 죽음
    @Published private(set) var recovering = false       // 복구 요청 후 browserOk 회복 대기 중
    @Published var banner: String?

    let host = "youtumu.duckdns.org"     // NAT loopback 확인 → 내외부 단일 주소 (Phase 3 확정)
    let player = HLSPlayer()

    private var overlay: OptimisticOverlay?
    private var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?

    init() {
        player.onStreaming = { [weak self] in
            Task { @MainActor in self?.stream = .streaming }
        }
        player.onEnded = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.stream == .streaming || self.stream == .connecting { self.banner = "오디오 연결 끊김" }
                self.stream = .disconnected
            }
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

    /// §20 재시도 — 다음 tick을 기다리지 않고 즉시 1회 재조회
    func retryNow() {
        Task { await refresh() }
    }

    /// §20 자가 복구 — 사용자가 선택했을 때만 트리거. 완료는 폴링의 browserOk가 알려준다.
    func recoverBrowser() {
        guard !recovering else { return }
        recovering = true
        Task {
            do { _ = try await ApiClient.recoverBrowser(host: host) }
            catch { recovering = false; banner = "복구 요청 실패"; return }
            try? await Task.sleep(for: .seconds(30))     // Chrome 재기동 대기 상한 — 초과 시 버튼 복귀
            if browserDown { recovering = false }
        }
    }

    private func refresh() async {
        do {
            let s = try await ApiClient.player(host: host)
            consecutiveFailures = 0
            let trackChanged = s.trackId != serverState?.trackId
            // stateVersion 낮은 응답으로 덮지 않는다 (§5)
            if s.stateVersion >= (serverState?.stateVersion ?? 0) { serverState = s }
            browserDown = (s.browserOk == false)         // nil(구버전 Agent)은 정상 취급
            if !browserDown { recovering = false }       // 복구 완료 감지
            if trackChanged { Task { await refreshQueue() } }   // ▶ 마커·인접 곡 메타 신선도 (§19·§21)
        } catch {
            consecutiveFailures += 1
        }
        link = Reconcile.linkState(consecutiveFailures: consecutiveFailures)
        applyReconcile()
        player.updateNowPlaying(title: display.title, artist: display.artist)
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
                try await player.start(host: host)
                // .streaming 전환은 onStreaming 콜백(첫 오디오 프레임)이 담당 — start() 반환은 TLS 연결 성립 이전
            } catch {
                stream = .disconnected
                banner = "오디오 연결 실패"
            }
        }
    }

    // MARK: 명령 (§21 optimistic)

    private func applyOverlay(playback: PlaybackState?, title: String?, artist: String?,
                              trackId: String? = nil) {
        overlay = OptimisticOverlay(playback: playback, title: title, artist: artist,
                                    baseStateVersion: serverState?.stateVersion ?? 0, appliedAt: Date(),
                                    trackId: trackId)
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

    /// 트랙 전환 명령 성공 후: 새 곡 오디오가 세그먼트로 나올 시간을 준 뒤 라이브 엣지로 점프
    private func nudgeToLiveEdgeSoon() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            player.seekToLiveEdge()
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
        applyOverlay(playback: .playing, title: meta?.title, artist: meta?.artist,
                     trackId: meta?.trackId)
        send("/api/player/next")
        nudgeToLiveEdgeSoon()
    }

    func previous() {
        let meta = adjacentQueueMeta(offset: -1)
        applyOverlay(playback: .playing, title: meta?.title, artist: meta?.artist,
                     trackId: meta?.trackId)
        send("/api/player/previous")
        nudgeToLiveEdgeSoon()
    }

    /// §21 Next: queue에서 인접 곡 메타를 즉시 표시
    private func adjacentQueueMeta(offset: Int) -> QueueItem? {
        guard let items = queue?.items,
              let cur = items.firstIndex(where: { $0.current }) else { return nil }
        let idx = cur + offset
        return items.indices.contains(idx) ? items[idx] : nil
    }

    func playTrack(id: String, title: String, artist: String, playlistId: String? = nil) {
        applyOverlay(playback: .playing, title: title, artist: artist, trackId: id)
        ensureStream()
        Task {
            do {
                _ = try await ApiClient.playTrack(host: host, id: id, listId: playlistId)
                nudgeToLiveEdgeSoon()
            }
            catch { overlay = nil; applyReconcile(); banner = "재생 실패" }
        }
    }

    func playPlaylist(id: String) {
        applyOverlay(playback: .playing, title: nil, artist: nil)
        ensureStream()
        Task {
            do {
                _ = try await ApiClient.playPlaylist(host: host, id: id)
                nudgeToLiveEdgeSoon()
            }
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
        do {
            _ = try await ApiClient.jumpQueue(host: host, position: position, stateVersion: sv)
            nudgeToLiveEdgeSoon()
        }
        catch let e as ApiError where e.status == 409 {
            overlay = nil; applyReconcile()
            banner = "큐가 바뀌었어요"
            await refreshQueue()                          // 새 큐 표시, 자동 재시도 없음 (설계 결정 9)
        } catch { overlay = nil; applyReconcile(); banner = "명령 실패" }
    }
}

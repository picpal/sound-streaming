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

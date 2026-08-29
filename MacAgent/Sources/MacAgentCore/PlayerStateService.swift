import Foundation
import YoutumuKit

/// 실제 YT Music 플레이어 상태가 Source of Truth (spec §8) — Mac에서 직접 조작해도 폴링으로 반영.
public final class PlayerStateService {
    private let lock = NSLock()
    // 재시작 시 이전 프로세스보다 큰 값에서 시작 — Watch의 stateVersion 역전 가드가 동결되지 않게 (spec §5)
    private var current = PlayerState(stateVersion: UInt64(Date().timeIntervalSince1970),
                                      playback: .stopped, trackId: "",
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

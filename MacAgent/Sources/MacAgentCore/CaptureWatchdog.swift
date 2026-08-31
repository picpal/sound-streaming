import Foundation

/// SCStream 무증상 사망 감지 (실측 2회: Chrome 재기동 후 필터 고정, 원인불명 사망).
/// 살아있는 캡처는 무음에서도 PCM 콜백이 계속 온다(실측: 무음 시 ~4.5KB/6s AAC) —
/// 수신자가 연결돼 있는데 PCM이 10초 이상 완전 침묵이면 죽은 것으로 판정하고 재시작한다.
/// 수신자가 없으면 아무것도 하지 않는다 (디스플레이 웨이크를 동반하므로 청취 중일 때만).
public final class CaptureWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPCM = Date()
    private static let staleAfter: TimeInterval = 10

    public init() {}

    public func notePCM() {
        lock.lock(); lastPCM = Date(); lock.unlock()
    }

    private func isStale() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastPCM) > Self.staleAfter
    }

    public func start(hasReceiver: @escaping () -> Bool, restart: @escaping () async -> Void) {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if hasReceiver(), self.isStale() {
                    print("CaptureWatchdog: 수신자 연결 중 PCM \(Int(Self.staleAfter))s+ 침묵 — 캡처 재시작")
                    await restart()
                    self.notePCM()                       // 재시작 직후 중복 트리거 방지
                }
            }
        }
    }
}

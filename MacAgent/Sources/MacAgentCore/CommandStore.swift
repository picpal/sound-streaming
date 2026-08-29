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

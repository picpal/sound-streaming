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
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            guard let task = ws else {
                lock.unlock()
                cont.resume(throwing: CDPError.disconnected)
                return
            }
            let id = nextId; nextId += 1
            pending[id] = cont
            lock.unlock()
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

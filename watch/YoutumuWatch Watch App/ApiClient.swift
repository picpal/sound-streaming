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

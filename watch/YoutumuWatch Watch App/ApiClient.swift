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

    /// listId가 있으면 그 곡부터 재생목록 순서로 큐가 이어진다 (§17 문맥 재생); 없으면 곡 기반 라디오 큐.
    static func playTrack(host: String, id: String, listId: String? = nil) async throws -> CommandResponse {
        if let listId {
            return try await post(host: host, path: "/api/player/playlists/\(listId)/tracks/\(id)")
        }
        return try await post(host: host, path: "/api/player/tracks/\(id)")
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

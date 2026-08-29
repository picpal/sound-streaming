import Foundation
import YoutumuKit

public struct ApiRequest {
    public let method: String
    public let path: String
    public let body: Data
    public init(method: String, path: String, body: Data) {
        self.method = method; self.path = path; self.body = body
    }
}

public struct ApiResponse {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
    static func error(_ status: Int, _ msg: String) -> ApiResponse {
        ApiResponse(status: status, body: try! JSONEncoder().encode(["error": msg]))
    }
}

/// mTLS 뒤에서도 애플리케이션 계층이 한 번 더 막는다 (spec §11 심층 방어).
public final class ControlAPI {
    private let store: CommandStore
    private let svc: PlayerStateService
    private let controller: PlayerControlling
    private static let trackIdPattern = try! Regex(#"^[A-Za-z0-9_-]{1,64}$"#)   // spec §11

    public init(store: CommandStore, svc: PlayerStateService, controller: PlayerControlling) {
        self.store = store; self.svc = svc; self.controller = controller
    }

    public func handle(_ req: ApiRequest) async -> ApiResponse {
        switch (req.method, req.path) {
        case ("GET", "/api/player"):
            return ApiResponse(status: 200, body: try! JSONEncoder().encode(svc.state()))
        case ("POST", "/api/player/play"):     return await command(req) { try await self.controller.play() }
        case ("POST", "/api/player/pause"):    return await command(req) { try await self.controller.pause() }
        case ("POST", "/api/player/next"):     return await command(req) { try await self.controller.next() }
        case ("POST", "/api/player/previous"): return await command(req) { try await self.controller.previous() }
        case ("POST", let p) where p.hasPrefix("/api/player/tracks/"):
            let trackId = String(p.dropFirst("/api/player/tracks/".count))
            guard trackId.wholeMatch(of: Self.trackIdPattern) != nil else {
                return .error(400, "invalid trackId")
            }
            return await command(req) { try await self.controller.playTrack(videoId: trackId) }
        default:
            return .error(404, "unknown endpoint")   // allow-list 외 전부 거부
        }
    }

    private func command(_ req: ApiRequest, _ exec: () async throws -> Void) async -> ApiResponse {
        // body는 정확히 {"commandId": "<uuid>"} — 정의되지 않은 필드는 거부 (spec §11)
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              obj.count == 1,
              let id = obj["commandId"] as? String,
              UUID(uuidString: id) != nil else {
            return .error(400, "body must be exactly {\"commandId\": \"<uuid>\"}")
        }
        if let dup = store.cached(id) {
            return ApiResponse(status: 200, body: try! JSONEncoder().encode(dup))   // 재실행 없음 (spec §5)
        }
        do { try await exec() } catch {
            return .error(502, "browser control failed")   // 실행 여부 불명 — 캐시하지 않음
        }
        svc.noteCommand()
        let resp = CommandResponse(stateVersion: svc.state().stateVersion, duplicate: false)
        store.record(id, resp)
        return ApiResponse(status: 200, body: try! JSONEncoder().encode(resp))
    }
}

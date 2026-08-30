import Foundation
import YoutumuKit

public struct ApiRequest {
    public let method: String
    public let path: String
    public let body: Data
    public let query: [String: String]
    public init(method: String, path: String, body: Data, query: [String: String] = [:]) {
        self.method = method; self.path = path; self.body = body; self.query = query
    }
}

public struct ApiResponse {
    public let status: Int
    public let body: Data
    public let contentType: String
    public init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status; self.body = body; self.contentType = contentType
    }
    static func error(_ status: Int, _ msg: String) -> ApiResponse {
        ApiResponse(status: status, body: try! JSONEncoder().encode(["error": msg]))
    }
}

/// mTLS 뒤에서도 애플리케이션 계층이 한 번 더 막는다 (spec §11 심층 방어).
public final class ControlAPI {
    private let store: CommandStore
    private let svc: PlayerStateService
    private let controller: PlayerControlling
    private let library: LibraryProviding
    private let cache: MetadataCache
    private let artwork: ArtworkService
    private static let idPattern = try! Regex(#"^[A-Za-z0-9_-]{1,64}$"#)   // trackId·playlistId·artwork id 공통 (spec §11)

    public init(store: CommandStore, svc: PlayerStateService, controller: PlayerControlling,
                library: LibraryProviding, cache: MetadataCache, artwork: ArtworkService) {
        self.store = store; self.svc = svc; self.controller = controller
        self.library = library; self.cache = cache; self.artwork = artwork
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
            guard trackId.wholeMatch(of: Self.idPattern) != nil else {
                return .error(400, "invalid trackId")
            }
            return await command(req) { try await self.controller.playTrack(videoId: trackId) }

        case ("GET", "/api/playlists"):
            do {
                let infos = try await cache.playlists { try await self.library.listPlaylists() }
                for p in infos { artwork.register(id: p.playlistId, url: p.thumbnailUrl) }
                let out = infos.map { PlaylistSummary(playlistId: $0.playlistId, title: $0.title, trackCount: $0.trackCount) }
                return ApiResponse(status: 200, body: try! JSONEncoder().encode(out))
            } catch { return .error(502, "library fetch failed") }

        case ("GET", let p) where p.hasPrefix("/api/playlists/"):
            let id = String(p.dropFirst("/api/playlists/".count))
            guard id.wholeMatch(of: Self.idPattern) != nil else { return .error(400, "invalid playlistId") }
            let offset = max(0, Int(req.query["offset"] ?? "") ?? 0)
            let limit = min(200, max(1, Int(req.query["limit"] ?? "") ?? 100))
            do {
                let all = try await cache.tracks(playlistId: id) { try await self.library.playlistTracks(playlistId: id) }
                for t in all where !t.trackId.isEmpty { artwork.registerTrack(id: t.trackId) }
                let page = PlaylistPage(items: Array(all.dropFirst(offset).prefix(limit)), total: all.count, offset: offset)
                return ApiResponse(status: 200, body: try! JSONEncoder().encode(page))
            } catch { return .error(502, "library fetch failed") }

        case ("GET", "/api/queue"):
            do {
                let items = try await library.queueItems()
                let snap = QueueSnapshot(stateVersion: svc.state().stateVersion, items: items)
                return ApiResponse(status: 200, body: try! JSONEncoder().encode(snap))
            } catch { return .error(502, "queue fetch failed") }

        case ("POST", let p) where p.hasPrefix("/api/player/playlists/"):
            let id = String(p.dropFirst("/api/player/playlists/".count))
            guard id.wholeMatch(of: Self.idPattern) != nil else { return .error(400, "invalid playlistId") }
            return await command(req) { try await self.library.playPlaylist(playlistId: id) }

        case ("POST", let p) where p.hasPrefix("/api/queue/"):
            guard let pos = Int(p.dropFirst("/api/queue/".count)), (0..<1000).contains(pos) else {
                return .error(400, "invalid position")
            }
            return await queueJump(req, position: pos)

        case ("GET", let p) where p.hasPrefix("/api/artwork/"):
            let id = String(p.dropFirst("/api/artwork/".count))
            guard id.wholeMatch(of: Self.idPattern) != nil else { return .error(400, "invalid artwork id") }
            if let jpeg = await artwork.image(id: id) {
                return ApiResponse(status: 200, body: jpeg, contentType: "image/jpeg")
            }
            return .error(404, "unknown artwork")

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

    /// spec §5: body에 기대 stateVersion 포함, 불일치 시 409. body는 정확히 {"commandId", "stateVersion"} 두 필드.
    private func queueJump(_ req: ApiRequest, position: Int) async -> ApiResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              obj.count == 2,
              let id = obj["commandId"] as? String, UUID(uuidString: id) != nil,
              let n = obj["stateVersion"] as? NSNumber, let expected = UInt64(exactly: n) else {
            return .error(400, "body must be exactly {\"commandId\": \"<uuid>\", \"stateVersion\": <n>}")
        }
        if let dup = store.cached(id) {
            return ApiResponse(status: 200, body: try! JSONEncoder().encode(dup))   // 재실행 없음 (spec §5)
        }
        guard expected == svc.state().stateVersion else {
            return .error(409, "stateVersion mismatch")     // 자동 곡 전환과의 경합 — 엉뚱한 곡 이동 방지
        }
        do {
            guard try await library.jumpQueue(position: position) else {
                return .error(409, "queue position gone")   // 검사 통과 후 DOM이 변한 경합 — 같은 의미의 409
            }
        } catch { return .error(502, "browser control failed") }   // 실행 여부 불명 — 캐시하지 않음
        svc.noteCommand()
        let resp = CommandResponse(stateVersion: svc.state().stateVersion, duplicate: false)
        store.record(id, resp)
        return ApiResponse(status: 200, body: try! JSONEncoder().encode(resp))
    }
}

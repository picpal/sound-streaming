import Foundation

public struct YTMSnapshot: Decodable, Equatable {
    public let videoId: String
    public let title: String
    public let byline: String
    public let paused: Bool
    public let position: Double
    public let duration: Double
    public let hasVideo: Bool

    /// byline("Artist • Album • Year")에서 artist만 추출
    public static func artist(fromByline byline: String) -> String {
        byline.components(separatedBy: "•").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

public protocol PlayerControlling {
    func play() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func playTrack(videoId: String) async throws
}

public final class BrowserController: PlayerControlling {
    private let cdp: CDPClient
    public init(cdp: CDPClient) { self.cdp = cdp }

    /// 연결이 죽어 있으면 1회 재연결 후 재시도 (Chrome 재시작·탭 리로드 대응)
    private func eval(_ js: String) async throws -> String? {
        do { return try await cdp.evaluate(js) }
        catch { try await cdp.connect(); return try await cdp.evaluate(js) }
    }

    public func play() async throws { _ = try await eval(YTM.play) }
    public func pause() async throws { _ = try await eval(YTM.pause) }
    public func next() async throws { _ = try await eval(YTM.next) }
    public func previous() async throws { _ = try await eval(YTM.previous) }
    public func playTrack(videoId: String) async throws { _ = try await eval(YTM.playTrack(videoId: videoId)) }

    public func snapshot() async throws -> YTMSnapshot {
        guard let json = try await eval(YTM.snapshot),
              let snap = try? JSONDecoder().decode(YTMSnapshot.self, from: Data(json.utf8))
        else { throw CDPError.badResponse }
        return snap
    }

    @discardableResult
    public func dismissYouTherePopup() async throws -> Bool {
        try await eval(YTM.dismissYouThere) == "true"
    }
}

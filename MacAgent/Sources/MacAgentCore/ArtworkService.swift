import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Watch는 Google CDN에 직접 접근하지 않는다 — Agent가 원본을 받아 128px JPEG로 리사이즈·캐시 후 서빙 (spec §9).
/// 조회 시점에 등록된 id만 서빙한다 (open proxy 방지, spec §11 심층 방어).
public final class ArtworkService {
    private let lock = NSLock()
    private var urls: [String: String] = [:]       // id → 원본 URL
    private var cache: [String: Data] = [:]        // id → 리사이즈된 JPEG
    private var order: [String] = []               // LRU (최근 사용이 뒤)
    private let maxEntries: Int
    private let session: URLSession

    public init(session: URLSession = .shared, maxEntries: Int = 256) {
        self.session = session; self.maxEntries = maxEntries
    }

    public func register(id: String, url: String) {
        guard !url.isEmpty else { return }
        lock.lock(); urls[id] = url; lock.unlock()
    }

    public func registerTrack(id: String) {
        register(id: id, url: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }

    func registeredURL(id: String) -> String? {    // 테스트용 (internal)
        lock.lock(); defer { lock.unlock() }
        return urls[id]
    }

    public func image(id: String) async -> Data? {
        // Check cache under lock (synchronous helper)
        if let hit = getCachedImageAndUpdateLRU(id: id) {
            return hit
        }

        // Get registered URL under lock (synchronous helper)
        guard let urlString = getRegisteredURL(id: id),
              let url = URL(string: urlString) else { return nil }

        // Fetch from network (no lock held)
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let jpeg = Self.resizeJPEG(data, maxPx: 128) else { return nil }

        // Store in cache under lock (synchronous helper)
        storeCachedImage(jpeg, forID: id)
        return jpeg
    }

    // MARK: - Synchronous helpers (may hold lock directly)

    /// Check if image is in cache and update LRU order if found.
    /// Lock is held throughout.
    private func getCachedImageAndUpdateLRU(id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        if let hit = cache[id] {
            order.removeAll { $0 == id }
            order.append(id)
            return hit
        }
        return nil
    }

    /// Get the registered URL for an id.
    /// Lock is held throughout.
    private func getRegisteredURL(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return urls[id]
    }

    /// Store a resized image in cache and evict old entries if needed.
    /// Lock is held throughout.
    private func storeCachedImage(_ data: Data, forID id: String) {
        lock.lock()
        defer { lock.unlock() }

        cache[id] = data
        order.append(id)
        while order.count > maxEntries {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    // MARK: - Static utilities

    static func resizeJPEG(_ data: Data, maxPx: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPx,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

import ImageIO
import SwiftUI
import YoutumuKit

/// /api/artwork/{id} 프록시의 클라이언트 캐시 (§9 — 서버가 128px JPEG로 리사이즈 완료).
/// 404(미등록)·실패는 nil → placeholder. 재시도는 화면 재진입 시 자연 발생 (in-flight dedup은 YAGNI).
@MainActor
final class ArtworkStore: ObservableObject {
    static let shared = ArtworkStore()
    private let cache = NSCache<NSString, CGImageBox>()
    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    func image(id: String, host: String) async -> CGImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit.image }
        guard let data = try? await ApiClient.artwork(host: host, id: id),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cache.setObject(CGImageBox(img), forKey: id as NSString)
        return img
    }
}

/// artwork 사각형 — 로드 전/실패 시 음표 placeholder (§16·§18)
struct ArtworkView: View {
    let id: String
    let size: CGFloat
    @EnvironmentObject private var model: PlayerModel
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
        .task(id: id) {
            image = nil
            guard !id.isEmpty else { return }
            image = await ArtworkStore.shared.image(id: id, host: model.host)
        }
    }
}

import SwiftUI
import YoutumuKit

/// §18 — 가장 중요한 화면. artwork 중심, Play/Pause가 Primary, Crown은 볼륨.
struct NowPlayingView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var crownVolume: Double = 0.7

    var body: some View {
        VStack(spacing: 6) {
            ArtworkView(id: model.display.trackId, size: 70)         // overlay 우선 — optimistic artwork 전환 (§21)

            VStack(spacing: 1) {                                                  // 제목·가수 밀착 — 컨트롤을 위로
                Text(model.display.title.isEmpty ? "—" : model.display.title)
                    .font(.headline).lineLimit(1)
                Text(model.display.artist)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }

            HStack(spacing: 14) {
                Button { model.previous() } label: { Image(systemName: "backward.fill") }
                    .buttonStyle(.plain)
                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.display.playback == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))                                   // Primary Action (§18)
                }
                .buttonStyle(.plain)
                Button { model.next() } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(.plain)
            }
        }
        .blur(radius: model.stream == .connecting ? 5 : 0)                        // §20 — 텍스트 대신 블러+스피너 (레이아웃 불변)
        .overlay {
            if model.stream == .connecting {
                ProgressView().tint(.white).scaleEffect(1.4)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // .automatic은 watchOS 26에서 artwork를 덮는 대형 오버레이로 렌더링됨 (시뮬레이터 확인)
            // — 10+에서는 topBarTrailing, 9에서만 fallback
            if #available(watchOS 10.0, iOS 17.0, *) {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { QueueView() } label: { Image(systemName: "list.bullet") }
                }
            } else {
                ToolbarItem(placement: .automatic) {
                    NavigationLink { QueueView() } label: { Image(systemName: "list.bullet") }
                }
            }
        }
        #if os(watchOS)
        .focusable(true)
        .digitalCrownRotation($crownVolume, from: 0, through: 1, by: 0.05,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownVolume) { v in model.player.volume = Float(v) }        // §18 Crown → 로컬 볼륨
        #endif
        .onAppear {
            crownVolume = Double(model.player.volume)
            model.ensureStream()                                                  // 설계 결정 5
            Task { await model.refreshQueue() }                                   // §21 Next 메타 준비
        }
    }
}

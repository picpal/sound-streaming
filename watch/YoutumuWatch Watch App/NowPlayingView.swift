import SwiftUI
import YoutumuKit

/// §18 — 가장 중요한 화면. artwork 중심, Play/Pause가 Primary, Crown은 볼륨.
struct NowPlayingView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var crownVolume: Double = 0.7

    var body: some View {
        VStack(spacing: 6) {
            ArtworkView(id: model.serverState?.trackId ?? "", size: 70)

            Text(model.display.title.isEmpty ? "—" : model.display.title)
                .font(.headline).lineLimit(1)
            Text(model.display.artist)
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)

            if model.stream == .connecting {
                Text("Connecting…").font(.footnote).foregroundStyle(.secondary)   // §20
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
        .navigationBarTitleDisplayMode(.inline)
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

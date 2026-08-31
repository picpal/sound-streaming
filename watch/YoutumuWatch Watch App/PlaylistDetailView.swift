import SwiftUI
import YoutumuKit

/// §17 — artwork 없는 고밀도 트랙 목록 + 전체 재생. Row 전체가 Touch Target.
struct PlaylistDetailView: View {
    @EnvironmentObject private var model: PlayerModel
    let playlist: PlaylistSummary
    let onPlay: () -> Void
    @State private var page: PlaylistPage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let page {
                List {
                    // 전체 재생 버튼 제거 — 트랙 탭이 재생목록 문맥을 유지하므로 1번 곡 탭과 동일 (사용자 결정)
                    ForEach(Array(page.items.enumerated()), id: \.offset) { i, t in
                        Button {
                            guard !t.unavailable, !t.trackId.isEmpty else { return }
                            // §21 즉시 전환 + 재생목록 문맥 유지 (이후 큐 = 재생목록 순서)
                            model.playTrack(id: t.trackId, title: t.title, artist: t.artist,
                                            playlistId: playlist.playlistId)
                            onPlay()
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Text(String(format: "%02d", i + 1))
                                    .font(.footnote).foregroundStyle(.tertiary)
                                VStack(alignment: .leading) {
                                    Text(t.title).font(.body).lineLimit(1)
                                    Text(t.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .opacity(t.unavailable ? 0.4 : 1)
                        }
                        .disabled(t.unavailable)
                    }
                }
            } else if loadFailed {
                ErrorRetryView { await load() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(playlist.title)
        .task { await load() }
    }

    private func load() async {
        loadFailed = false
        do { page = try await ApiClient.playlistTracks(host: model.host, id: playlist.playlistId) }
        catch { loadFailed = true }
    }
}

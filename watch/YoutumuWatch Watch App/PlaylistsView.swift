import SwiftUI
import YoutumuKit

/// §16 — artwork 행 목록. Crown 스크롤은 List 기본 동작.
struct PlaylistsView: View {
    @EnvironmentObject private var model: PlayerModel
    let onPlay: () -> Void                                  // 재생 시작 → NowPlaying push (T8)
    @State private var playlists: [PlaylistSummary]?
    @State private var loadFailed = false

    /// YouTube Charts 공식 자동 갱신 "한국 인기곡 Top100" — 항상 최상단 고정 행에서 재생
    private static let kpopChartId = "PL4fGSI1pDJn6jXS_Tv_N9B8Z0HTRVJE0m"

    var body: some View {
        Group {
            if let playlists {
                List {
                    Button {
                        model.playPlaylist(id: Self.kpopChartId)
                        onPlay()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(LinearGradient(colors: [.red, .orange],
                                                           startPoint: .top, endPoint: .bottom),
                                            in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text("KPOP 트렌드").font(.body).lineLimit(1)
                                Text("인기곡 Top100").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(playlists, id: \.playlistId) { p in
                        NavigationLink(value: p) {
                            HStack(spacing: 8) {
                                ArtworkView(id: p.playlistId, size: 36)
                                VStack(alignment: .leading) {
                                    Text(p.title).font(.body).lineLimit(1)
                                    Text("\(p.trackCount)곡").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else if loadFailed {
                ErrorRetryView { await load() }              // §20 — T8에서 정의
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Playlists")
        .task { await load() }
    }

    private func load() async {
        loadFailed = false
        do { playlists = try await ApiClient.playlists(host: model.host) }
        catch { loadFailed = true }
    }
}

/// §20 오류 상태 — 정상일 땐 절대 보이지 않는다.
struct ErrorRetryView: View {
    let retry: () async -> Void
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.title3)
            Text("Mac에 연결할 수 없습니다.").font(.footnote).multilineTextAlignment(.center)
            Button("재시도") { Task { await retry() } }
        }
    }
}

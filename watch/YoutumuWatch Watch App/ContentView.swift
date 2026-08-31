import SwiftUI
import YoutumuKit

/// 앱 루트: enrollment 게이트 → 시작 라우트 결정(§15) → NavigationStack.
/// 정상 상태에서는 연결 정보를 보여주지 않는다 (§20).
struct ContentView: View {
    @StateObject private var model = PlayerModel()
    @State private var enrolled = KeyStore.identity() != nil
    @State private var path = NavigationPath()
    @State private var routed = false
    // 중복 push 방지: NavigationPath는 내용 검사가 불가하므로 push 시점의 depth를 기록해 추적.
    // path.count가 그 depth 아래로 줄어들면(= NowPlaying보다 얕은 곳으로 이동) 플래그를 초기화한다.
    // (단순 isEmpty 체크는 Detail로 swipe-back 후 다른 트랙 재생 시 stuck 되는 버그가 있었음 — depth 비교로 교체)
    @State private var pushedNowPlaying = false
    @State private var nowPlayingDepth: Int?

    private enum Route: Hashable { case nowPlaying }

    var body: some View {
        if !enrolled {
            EnrollView { enrolled = true }
        } else {
            NavigationStack(path: $path) {
                PlaylistsView(onPlay: { pushNowPlaying() })
                    .navigationDestination(for: PlaylistSummary.self) { p in
                        PlaylistDetailView(playlist: p, onPlay: { pushNowPlaying() })
                    }
                    .navigationDestination(for: Route.self) { _ in NowPlayingView() }
            }
            .onChange(of: path) { newPath in
                if let d = nowPlayingDepth, newPath.count < d {
                    nowPlayingDepth = nil
                    pushedNowPlaying = false
                }
            }
            .overlay(alignment: .bottom) {
                if let msg = model.banner {
                    Text(msg).font(.footnote).padding(6)
                        .background(.red.opacity(0.8), in: Capsule())
                        .task { try? await Task.sleep(for: .seconds(2)); model.banner = nil }
                }
            }
            .overlay {
                if model.link == .down {                      // §20 Mac 연결 실패 — 전면 오류만
                    ZStack {
                        Rectangle().fill(.black)
                        ErrorRetryView { model.retryNow() }
                    }
                }
            }
            .environmentObject(model)
            .task {
                model.startPolling()
                // §15: 첫 상태 확인 후 재생 중이면 Now Playing 직행 (1회만)
                for _ in 0..<10 where model.serverState == nil {
                    try? await Task.sleep(for: .seconds(1))
                }
                if !routed {
                    routed = true
                    if StartRoute.decide(model.serverState) == .nowPlaying { pushNowPlaying() }
                }
            }
        }
    }

    private func pushNowPlaying() {
        guard !pushedNowPlaying else { return }
        path.append(Route.nowPlaying)
        pushedNowPlaying = true
        nowPlayingDepth = path.count
    }
}

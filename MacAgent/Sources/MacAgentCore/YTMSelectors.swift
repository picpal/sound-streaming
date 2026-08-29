import Foundation

/// YouTube Music DOM 접점 전부. 셀렉터가 깨지면 이 파일만 고친다.
/// 검증 방법: launch-chrome-ytm.sh로 띄운 뒤 DevTools 콘솔에서 각 스니펫 실행 (Task 7 체크포인트).
enum YTM {
    /// 상태 스냅샷 — JSON 문자열 반환
    static let snapshot = """
    (() => {
      const v = document.querySelector('video');
      const bar = document.querySelector('ytmusic-player-bar');
      const u = new URL(location.href);
      return JSON.stringify({
        videoId: u.pathname === '/watch' ? (u.searchParams.get('v') || '') : '',
        title: bar?.querySelector('.title')?.textContent?.trim() || '',
        byline: bar?.querySelector('.byline')?.textContent?.trim() || '',
        paused: v ? v.paused : true,
        position: v ? v.currentTime : 0,
        duration: v && isFinite(v.duration) ? v.duration : 0,
        hasVideo: !!v && !!bar
      });
    })()
    """

    /// 이미 재생 중이면 no-op (멱등)
    static let play = """
    (() => { const v = document.querySelector('video');
      if (v && v.paused) document.querySelector('#play-pause-button')?.click(); })()
    """

    static let pause = """
    (() => { const v = document.querySelector('video');
      if (v && !v.paused) document.querySelector('#play-pause-button')?.click(); })()
    """

    static let next = "document.querySelector('ytmusic-player-bar .next-button')?.click()"
    static let previous = "document.querySelector('ytmusic-player-bar .previous-button')?.click()"

    /// videoId는 호출 전에 ^[A-Za-z0-9_-]{1,64}$ 검증 필수 — JS 인젝션 표면 차단 (spec §11)
    static func playTrack(videoId: String) -> String {
        "location.href = 'https://music.youtube.com/watch?v=\(videoId)'"
    }

    /// "계속 시청하시겠어요?" 자동 일시정지 팝업 해제 — 눌렀으면 "true" 반환 (poc-results 백로그)
    static let dismissYouThere = """
    (() => {
      const d = document.querySelector('ytmusic-you-there-renderer');
      if (!d || d.offsetParent === null) return JSON.stringify(false);
      const b = d.querySelector('button');
      if (b) { b.click(); return JSON.stringify(true); }
      return JSON.stringify(false);
    })()
    """
}

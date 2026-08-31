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

    /// videoId·playlistId는 호출 전에 ^[A-Za-z0-9_-]{1,64}$ 검증 필수 — JS 인젝션 표면 차단 (spec §11)
    /// playlistId가 있으면 그 곡부터 재생목록 순서로 큐가 이어진다 (&list= 문맥); 없으면 곡 기반 라디오 큐.
    static func playTrack(videoId: String, playlistId: String? = nil) -> String {
        if let pid = playlistId {
            return "location.href = 'https://music.youtube.com/watch?v=\(videoId)&list=\(pid)'"
        }
        return "location.href = 'https://music.youtube.com/watch?v=\(videoId)'"
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

    /// innertube fetch용 SAPISIDHASH 인증 헤더 조각 — 없으면 로그아웃 취급되어 라이브러리가 빈 응답
    /// (지역에 따라 "Premium 전용" 거절, T9 실측). cfg가 스코프에 있는 async IIFE 안에서만 사용.
    private static let innertubeAuthJS = """
      const sapisid = (document.cookie.split('; ').find(c => c.startsWith('SAPISID=')) ||
                       document.cookie.split('; ').find(c => c.startsWith('__Secure-3PAPISID=')) || '').split('=')[1] || '';
      const ts = Math.floor(Date.now() / 1000);
      const sigBuf = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(ts + ' ' + sapisid + ' ' + location.origin));
      const sig = [...new Uint8Array(sigBuf)].map(b => b.toString(16).padStart(2, '0')).join('');
      const authHeaders = {'Content-Type': 'application/json',
        'Authorization': 'SAPISIDHASH ' + ts + '_' + sig,
        'X-Goog-AuthUser': String(cfg.SESSION_INDEX || '0'),
        'X-Origin': location.origin};
    """

    /// 라이브러리 플레이리스트 목록 — 페이지 컨텍스트에서 innertube browse 호출 (네비게이션 없음 = 재생 무중단).
    /// 반환: {"playlists":[{playlistId,title,trackCount,thumbnailUrl}]} 또는 {"error":"..."}
    static let listPlaylists = """
    (async () => {
      const cfg = (window.ytcfg && ytcfg.data_) || (window.yt && yt.config_);
      if (!cfg || !cfg.INNERTUBE_API_KEY) return JSON.stringify({error: 'no ytcfg'});
    \(innertubeAuthJS)
      const res = await fetch('/youtubei/v1/browse?key=' + cfg.INNERTUBE_API_KEY, {
        method: 'POST', headers: authHeaders,
        body: JSON.stringify({context: cfg.INNERTUBE_CONTEXT, browseId: 'FEmusic_liked_playlists'})
      });
      const j = await res.json();
      const found = [];
      (function walk(o) {
        if (!o || typeof o !== 'object') return;
        if (o.musicTwoRowItemRenderer) {
          const r = o.musicTwoRowItemRenderer;
          const bid = (r.navigationEndpoint && r.navigationEndpoint.browseEndpoint && r.navigationEndpoint.browseEndpoint.browseId) || '';
          if (bid.startsWith('VL')) {
            const sub = ((r.subtitle && r.subtitle.runs) || []).map(x => x.text).join('');
            const m = sub.match(/(\\d+)/);
            const th = (r.thumbnailRenderer && r.thumbnailRenderer.musicThumbnailRenderer
                        && r.thumbnailRenderer.musicThumbnailRenderer.thumbnail
                        && r.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails) || [];
            found.push({
              playlistId: bid.slice(2),
              title: (r.title && r.title.runs && r.title.runs[0] && r.title.runs[0].text) || '',
              trackCount: m ? parseInt(m[1], 10) : 0,
              thumbnailUrl: th.length ? th[th.length - 1].url : ''
            });
          }
        }
        for (const k in o) walk(o[k]);
      })(j);
      return JSON.stringify({playlists: found});
    })()
    """

    /// 플레이리스트 트랙 목록. playlistId는 호출 전에 ^[A-Za-z0-9_-]{1,64}$ 검증 필수 (spec §11).
    /// 첫 browse 응답만 사용 (continuation 미지원 — 계획 설계 결정 2).
    /// 반환: {"tracks":[{trackId,title,artist,durationSec,unavailable}]} 또는 {"error":"..."}
    static func playlistTracks(playlistId: String) -> String {
        """
        (async () => {
          const cfg = (window.ytcfg && ytcfg.data_) || (window.yt && yt.config_);
          if (!cfg || !cfg.INNERTUBE_API_KEY) return JSON.stringify({error: 'no ytcfg'});
        \(innertubeAuthJS)
          const res = await fetch('/youtubei/v1/browse?key=' + cfg.INNERTUBE_API_KEY, {
            method: 'POST', headers: authHeaders,
            body: JSON.stringify({context: cfg.INNERTUBE_CONTEXT, browseId: 'VL\(playlistId)'})
          });
          const j = await res.json();
          const found = [];
          (function walk(o) {
            if (!o || typeof o !== 'object') return;
            if (o.musicResponsiveListItemRenderer) {
              const r = o.musicResponsiveListItemRenderer;
              const cols = r.flexColumns || [];
              const col = i => cols[i] && cols[i].musicResponsiveListItemFlexColumnRenderer
                             && cols[i].musicResponsiveListItemFlexColumnRenderer.text
                             && cols[i].musicResponsiveListItemFlexColumnRenderer.text.runs
                             && cols[i].musicResponsiveListItemFlexColumnRenderer.text.runs[0];
              const videoId = (r.playlistItemData && r.playlistItemData.videoId) || '';
              const durText = (r.fixedColumns && r.fixedColumns[0]
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0]
                               && r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text) || '';
              let dur = 0;
              for (const p of durText.split(':')) { const n = parseInt(p, 10); dur = dur * 60 + (isFinite(n) ? n : 0); }
              found.push({
                trackId: videoId,
                title: (col(0) && col(0).text) || '',
                artist: (col(1) && col(1).text) || '',
                durationSec: dur,
                unavailable: !videoId || r.musicItemRendererDisplayPolicy === 'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT'
              });
            }
            for (const k in o) walk(o[k]);
          })(j);
          return JSON.stringify({tracks: found});
        })()
        """
    }

    /// Playlist 전체 재생. playlistId는 호출 전 검증 필수. Phase 1 playTrack과 동일한 full-navigation 방식 (M1 리스크 공유).
    static func playPlaylist(playlistId: String) -> String {
        "location.href = 'https://music.youtube.com/watch?list=\(playlistId)'"
    }

    /// 현재 Queue — 이미 렌더된 DOM에서 읽는다 (fetch 경로 없음). 반환: {"queue":[{position,title,artist,current}]}
    /// 셀렉터 검증: T9 체크포인트에서 DevTools로 확인 (selected 속성이 현재 곡 표시인지 포함)
    static let queueSnapshot = """
    (() => {
      const items = [...document.querySelectorAll('ytmusic-player-queue ytmusic-player-queue-item')];
      return JSON.stringify({queue: items.map((el, i) => ({
        position: i,
        title: el.querySelector('.song-title')?.textContent?.trim() || '',
        artist: el.querySelector('.byline')?.textContent?.trim() || '',
        current: el.hasAttribute('selected')
      }))});
    })()
    """

    /// Queue의 position번째 곡으로 이동. 반환 "true"/"false"(문자열) — false = 해당 position 없음(경합).
    static func jumpQueue(position: Int) -> String {
        """
        (() => {
          const el = document.querySelectorAll('ytmusic-player-queue ytmusic-player-queue-item')[\(position)];
          if (!el) return JSON.stringify(false);
          (el.querySelector('ytmusic-play-button-renderer') || el).click();
          return JSON.stringify(true);
        })()
        """
    }
}

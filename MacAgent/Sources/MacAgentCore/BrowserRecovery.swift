import Foundation

/// Chrome/YTM 탭 자가 복구 — Watch의 "복구 시도" 버튼이 트리거 (§20 확장).
/// 고정 동작만 수행(입력 파라미터 없음, spec §11 allow-list):
/// - CDP 포트 생존 + YTM 탭 존재하는데 폴링 실패 → 탭이 굳은 것 → 탭 닫고 재생성
/// - CDP 포트 생존 + YTM 탭 없음 → 탭 생성
/// - CDP 포트 죽음 → 전용 프로필(~/.youtumu-chrome) Chrome 재기동 (개인 Chrome은 건드리지 않음)
/// 복구는 비동기로 완결된다 — 호출자는 즉시 응답하고, Watch는 browserOk 폴링으로 완료를 확인.
public enum BrowserRecovery {
    static let ytmURL = "https://music.youtube.com"
    static let devtools = "http://127.0.0.1:9222"

    public static func recover(browserHealthy: Bool) async {
        if browserHealthy { return }                       // 이미 정상 — 할 일 없음
        if let targets = await targetList() {
            // 포트는 살아 있음 → 탭 수준 복구
            if let id = targets.first(where: {
                ($0["type"] as? String) == "page" && (($0["url"] as? String) ?? "").hasPrefix(ytmURL)
            })?["id"] as? String {
                _ = await http(path: "/json/close/\(id)")  // 굳은 탭 정리 (DevTools HTTP는 WS 무관)
                try? await Task.sleep(for: .seconds(1))
            }
            _ = await http(path: "/json/new?url=\(ytmURL)", method: "PUT")
            print("BrowserRecovery: YTM 탭 재생성")
            return
        }
        // 포트 자체가 죽음 → 전용 프로필 Chrome 재기동 (launch-chrome-ytm.sh와 동일 인자)
        print("BrowserRecovery: 전용 프로필 Chrome 재기동")
        run("/usr/bin/pkill", ["-f", ".youtumu-chrome"])   // 프로필 경로 매칭 — 개인 Chrome 미포함
        try? await Task.sleep(for: .seconds(1))
        let profile = FileManager.default.homeDirectoryForCurrentUser.path + "/.youtumu-chrome"
        run("/usr/bin/open", ["-na", "Google Chrome", "--args",
                              "--remote-debugging-port=9222",
                              "--user-data-dir=\(profile)",
                              "--no-first-run", ytmURL])
    }

    private static func targetList() async -> [[String: Any]]? {
        guard let data = await http(path: "/json") else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    private static func http(path: String, method: String = "GET") async -> Data? {
        var req = URLRequest(url: URL(string: devtools + path)!)
        req.httpMethod = method
        req.timeoutInterval = 2
        return try? await URLSession.shared.data(for: req).0
    }

    /// 디스플레이가 잠들어 있으면 SCShareableContent가 비어 cap.start()가 실패한다 (poc-results) — 캡처 재시작 전 호출
    public static func wakeDisplay() {
        run("/usr/bin/caffeinate", ["-u", "-t", "3"])
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

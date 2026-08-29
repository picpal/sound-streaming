import SwiftUI
#if os(watchOS)
import WatchKit
#endif

@main
struct YoutumuWatchApp: App {
    init() {
        #if os(watchOS)
        WKExtension.shared().isFrontmostTimeoutExtended = true   // 손목 내림 후 frontmost 유지 2분 → 8분 (Now Playing 등록의 보조 안전망)
        #endif
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

import SwiftUI
#if os(watchOS)
import WatchKit
#endif
import YoutumuKit

struct ContentView: View {
    // Enrollment UI (Task 8)
    @State private var mac = "172.30.1.15"
    @State private var code = ""
    @State private var enrollStatus = "not enrolled"

    // Playback UI (Task 9)
    @State private var player = StreamPlayer()
    @State private var serverHost = "youtumu.duckdns.org"   // NAT loopback 지원 확인 → 내외부 단일 주소. mTLS는 SNI 필수 — IP 접속은 421
    @State private var lastSeq = "-"
    @State private var playStatus = ""
    @State private var metrics = ""
    @State private var batteryAtPlay: Float = -1
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private func currentBattery() -> Float {
        #if os(watchOS)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        return WKInterfaceDevice.current().batteryLevel
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryLevel
        #endif
    }

    var body: some View {
        ScrollView { VStack(spacing: 12) {
            // Enrollment Section
            VStack(spacing: 8) {
                Text("Enrollment").font(.headline)
                TextField("Mac LAN IP", text: $mac)
                TextField("code", text: $code)
                Button("Enroll") {
                    Task {
                        do { enrollStatus = try await EnrollClient.enroll(macAddr: mac, code: code) ? "identity OK" : "enroll failed" }
                        catch { enrollStatus = "error: \(error.localizedDescription)" }
                    }
                }
                Text(enrollStatus).font(.footnote)
            }

            Divider()

            // Playback Section
            VStack(spacing: 8) {
                Text("Playback").font(.headline)
                TextField("Server Host", text: $serverHost)
                HStack(spacing: 8) {
                    Button("Play") {
                        playStatus = "connecting..."
                        batteryAtPlay = currentBattery()
                        Task {
                            do {
                                try await player.start(url: URL(string: "https://\(serverHost):8443/audio/live")!)
                                await MainActor.run { playStatus = "started" }
                            } catch {
                                await MainActor.run { playStatus = "err: \(error.localizedDescription)" }
                            }
                        }
                    }
                    Button("Stop") {
                        player.stop()
                        playStatus = "stopped"
                    }
                }
                Text("Marker: \(lastSeq)").font(.footnote)
                Text(playStatus).font(.footnote)
                Text(metrics).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding()}
        .onReceive(ticker) { _ in
            let st = player.stats()
            guard st.seconds > 0 else { return }
            let bat = currentBattery()
            let drop = batteryAtPlay >= 0 && bat >= 0 ? String(format: "%.0f%%→%.0f%%", batteryAtPlay*100, bat*100) : "-"
            metrics = String(format: "%dm%02ds  %.1fMB  bat %@", st.seconds/60, st.seconds%60, st.mb, drop)
        }
        .task {
            if KeyStore.identity() != nil { enrollStatus = "enrolled (identity OK)" }
            player.onMarker = { m in Task { @MainActor in lastSeq = "seq \(m.seq)" } }
            player.onEnded = { msg in Task { @MainActor in playStatus = msg } }
        }
    }
}

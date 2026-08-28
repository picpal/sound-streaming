import SwiftUI
import YoutumuKit

struct ContentView: View {
    // Enrollment UI (Task 8)
    @State private var mac = "172.30.1.15"
    @State private var code = ""
    @State private var enrollStatus = "not enrolled"

    // Playback UI (Task 9)
    @State private var player = StreamPlayer()
    @State private var serverHost = "homeui-Macmini.local"   // mTLS는 SNI 필수(Caddy strict SNI) — IP 접속은 421
    @State private var lastSeq = "-"
    @State private var playStatus = ""

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
            }
        }.padding()}
        .task {
            if KeyStore.identity() != nil { enrollStatus = "enrolled (identity OK)" }
            player.onMarker = { m in Task { @MainActor in lastSeq = "seq \(m.seq)" } }
            player.onEnded = { msg in Task { @MainActor in playStatus = msg } }
        }
    }
}

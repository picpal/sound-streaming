import SwiftUI

/// LAN 1회 등록 (spec §10) — identity가 없을 때만 표시.
struct EnrollView: View {
    let onEnrolled: () -> Void
    @State private var mac = "172.30.1.15"
    @State private var code = ""
    @State private var status = ""

    var body: some View {
        ScrollView { VStack(spacing: 8) {
            Text("등록").font(.headline)
            TextField("Mac LAN IP", text: $mac)
            TextField("code", text: $code)
            Button("Enroll") {
                Task {
                    do {
                        if try await EnrollClient.enroll(macAddr: mac, code: code) {
                            status = "완료"; onEnrolled()
                        } else { status = "실패" }
                    } catch { status = "오류: \(error.localizedDescription)" }
                }
            }
            Text(status).font(.footnote)
        }.padding() }
    }
}

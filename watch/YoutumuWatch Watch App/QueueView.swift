import SwiftUI
import YoutumuKit

/// §19 — 현재 곡 표시 + 탭 즉시 이동. artwork 없음.
struct QueueView: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let q = model.queue {
                List(q.items, id: \.position) { item in
                    Button {
                        Task {
                            await model.jumpQueue(to: item.position)
                            dismiss()                       // §19 "즉시 이동" — Now Playing으로 복귀
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                                .opacity(item.current ? 1 : 0)   // ▶ 현재 곡 마커
                            VStack(alignment: .leading) {
                                Text(item.title).font(.body).lineLimit(1)
                                Text(item.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Playing Next")
        .task { await model.refreshQueue() }
    }
}

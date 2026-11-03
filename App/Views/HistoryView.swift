import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse) private var records: [TranscriptRecord]
    @State private var copiedID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No dictations yet",
                        systemImage: "clock",
                        description: Text("Everything you dictate is saved here, only on this iPhone.")
                    )
                } else {
                    List {
                        ForEach(records) { record in
                            Button { copy(record) } label: { row(record) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Copy", systemImage: "doc.on.doc") { copy(record) }
                                    Button("Delete", systemImage: "trash", role: .destructive) { context.delete(record) }
                                }
                        }
                        .onDelete { offsets in
                            for index in offsets { context.delete(records[index]) }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .sensoryFeedback(.success, trigger: copiedID) { _, new in new != nil }
        }
    }

    private func row(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(4)
            HStack(spacing: 6) {
                Text(record.createdAt, format: .relative(presentation: .named))
                Text("·")
                Text(String(format: "%.1fs of audio", record.audioSeconds))
                Spacer()
                if copiedID == record.id {
                    Label("Copied", systemImage: "checkmark")
                        .foregroundStyle(Color.takiAccent)
                        .transition(.opacity)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .animation(.takiSnappy, value: copiedID)
    }

    private func copy(_ record: TranscriptRecord) {
        UIPasteboard.general.string = record.text
        copiedID = record.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedID == record.id { copiedID = nil }
        }
    }
}

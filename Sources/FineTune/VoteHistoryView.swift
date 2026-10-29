import SwiftUI
import TuningCore

extension PreferenceRating {
    var buttonLabel: String {
        switch self {
        case .strongA: return "Strongly\nA"
        case .slightA: return "Slightly\nA"
        case .indistinguishable: return "Can’t tell"
        case .slightB: return "Slightly\nB"
        case .strongB: return "Strongly\nB"
        }
    }
}

@available(macOS 14.2, *)
struct VoteHistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rollback: VoteHistoryEntry?
    private var entries: [VoteHistoryEntry] { model.library.profile?.session?.voteHistory ?? [] }
    private var removedCount: Int { entries.count - (rollback?.id ?? entries.count) }
    private var groups: [VoteHistoryGroup] { VoteHistoryGroup.grouped(entries) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Voting history").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Roll back to before a vote or session. That vote and everything after it will be removed.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(groups.reversed()) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(title(group)).font(.headline)
                                Spacer()
                                Button(group.date == nil ? "Roll back all…" : "Roll back session…") { rollback = group.entries.first }
                            }
                            DisclosureGroup("\(group.entries.count) votes") {
                                ForEach(group.entries.reversed()) { entry in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(entry.id + 1). \(entry.label)")
                                            if let date = entry.date {
                                                Text(date.formatted(date: .omitted, time: .standard))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Button("Roll back…") { rollback = entry }
                                            .accessibilityLabel("Roll back before vote \(entry.id + 1)")
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                        Divider()
                    }
                    if entries.isEmpty { Text("No votes yet.").foregroundStyle(.secondary) }
                }
            }
        }
        .padding(24).frame(width: 580, height: 460)
        .confirmationDialog("Remove \(removedCount) \(removedCount == 1 ? "vote" : "votes")?",
                            isPresented: Binding(get: { rollback != nil }, set: { if !$0 { rollback = nil } }),
                            titleVisibility: .visible, presenting: rollback) { entry in
            Button("Roll back", role: .destructive) { model.rollbackVotes(to: entry.id) }
        } message: { _ in
            Text("Current will return to its state before these votes. This cannot be undone.")
        }
    }
    private func title(_ group: VoteHistoryGroup) -> String {
        guard let date = group.date else { return "Earlier votes · time unavailable" }
        let day: String
        if Calendar.current.isDateInToday(date) { day = "Today" }
        else if Calendar.current.isDateInYesterday(date) { day = "Yesterday" }
        else { day = date.formatted(date: .abbreviated, time: .omitted) }
        return "\(day) · \(date.formatted(date: .omitted, time: .shortened))"
    }
}

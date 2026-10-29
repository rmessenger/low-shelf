import Foundation

public struct VoteHistoryEntry: Identifiable, Sendable {
    public let id: Int
    public let label: String
    public let date: Date?
}

public struct VoteHistoryGroup: Identifiable, Sendable {
    public var id: Int { entries[0].id }
    public private(set) var entries: [VoteHistoryEntry]
    public var date: Date? { entries.first?.date }

    public static func grouped(_ entries: [VoteHistoryEntry], calendar: Calendar = .current) -> [VoteHistoryGroup] {
        var groups = [VoteHistoryGroup]()
        for entry in entries {
            if let last = groups.last?.entries.last, sameSession(last.date, entry.date, calendar: calendar) {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(VoteHistoryGroup(entries: [entry]))
            }
        }
        return groups
    }
    private static func sameSession(_ a: Date?, _ b: Date?, calendar: Calendar) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            let gap = b.timeIntervalSince(a)
            return gap >= 0 && gap <= 30 * 60 && calendar.isDate(a, inSameDayAs: b)
        default: return false
        }
    }
}

extension StereoPreferenceSearch {
    public var voteHistory: [VoteHistoryEntry] {
        let legacy = (legacyHistory?.answers ?? []).enumerated().map { index, answer in
            let label: String
            switch answer.vote {
            case .a: label = "Preferred A (\(answer.confidence.rawValue))"
            case .b: label = "Preferred B (\(answer.confidence.rawValue))"
            case .equal: label = "Equal"
            case .unsure: label = "Unsure"
            }
            return VoteHistoryEntry(id: index, label: label, date: nil)
        }
        return legacy + answers.enumerated().map { index, answer in
            VoteHistoryEntry(id: legacy.count + index, label: answer.rating.label, date: answer.votedAt)
        }
    }
}

public enum ComparisonAudition: String, CaseIterable, Hashable, Sendable {
    case a = "A", current = "Current", b = "B"
}

public struct ComparisonListening: Sendable {
    public private(set) var selection: ComparisonAudition = .current
    public private(set) var heard: Set<ComparisonAudition> = []
    public init() {}
    public var canVote: Bool { heard.contains(.a) && heard.contains(.b) }
    public mutating func select(_ choice: ComparisonAudition, processing: Bool) {
        selection = choice
        if processing { heard.insert(choice) }
    }
    public mutating func processingStarted() { heard = [selection] }
    public mutating func processingStopped() { heard = [] }
    public mutating func reset() { self = ComparisonListening() }
}

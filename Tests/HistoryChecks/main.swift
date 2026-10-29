import Foundation
import TuningCore

struct Failure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }
}
func required<T>(_ value: T?) throws -> T {
    guard let value else { throw Failure(message: "Unexpected nil") }
    return value
}
let encoder = JSONEncoder(), decoder = JSONDecoder()
encoder.outputFormatting = [.sortedKeys]
let epoch = Date(timeIntervalSince1970: 1_700_000_000)

var listening = ComparisonListening()
try check(listening.selection == .current && !listening.canVote, "Start on Current with voting locked")
listening.select(.a, processing: false); listening.select(.b, processing: false)
try check(!listening.canVote, "Disabled playback must not count as hearing either candidate")
listening.processingStarted()
try check(!listening.canVote, "Starting playback must not retain earlier selections")
listening.select(.current, processing: true)
try check(!listening.canVote, "Current is not a substitute for A")
listening.select(.a, processing: true)
try check(listening.canVote, "Both candidates unlock voting")
listening.select(.current, processing: true)
try check(listening.canVote, "Voting remains available while listening to Current")
listening.reset()
try check(listening.selection == .current && !listening.canVote, "A new round returns to Current and requires both candidates again")
listening.select(.a, processing: true); listening.select(.b, processing: true)
listening.processingStopped()
try check(!listening.canVote, "Stopping clears listening evidence")
print("PASS  A/Current/B selection and per-round voting eligibility")

var search = StereoPreferenceSearch(seed: 314159)
var snapshots = [StereoPreferenceSearch]()
for index in 0..<45 {
    _ = search.next()
    snapshots.append(search)
    search.answer(PreferenceRating.allCases[index % 5], at: epoch.addingTimeInterval(Double(index * 60)))
}
_ = search.next()
for retained in [0, 1, 19, 20, 21, 39, 40, 44] {
    var restored = try decoder.decode(StereoPreferenceSearch.self, from: encoder.encode(search))
    restored.rollback(to: retained)
    let expected = snapshots[retained]
    try check(restored.mean == expected.mean && restored.covariance == expected.covariance, "Exact posterior before vote \(retained + 1)")
    try check(restored.current == expected.current && restored.answers.count == retained, "Restore the comparison and remove all later votes")
    try check(try encoder.encode(restored) == encoder.encode(expected), "Restore the full serialized state, including random continuation")
    var continuation = expected
    restored.answer(.slightB, at: epoch); continuation.answer(.slightB, at: epoch)
    try check(restored.next() == continuation.next(), "Resuming rollback must reproduce future candidates")
}
var invalid = search
invalid.rollback(to: -1); invalid.rollback(to: 46); invalid.rollback(to: 45)
try check(try encoder.encode(invalid) == encoder.encode(search), "Invalid or empty rollback must leave state unchanged")
print("PASS  Exact arbitrary rollback across refits, serialization, and deterministic continuation")

var legacy = PreferenceSearch(seed: 2718)
var legacySnapshots = [PreferenceSearch]()
let oldRatings: [Vote] = [.a, .b, .equal, .unsure]
for index in 0..<31 {
    _ = legacy.next(); legacySnapshots.append(legacy)
    legacy.answer(oldRatings[index % 4], confidence: .tentative)
}
_ = legacy.next()
var migrated = StereoPreferenceSearch(migrating: legacy)
for index in 0..<25 {
    _ = migrated.next(); migrated.answer(PreferenceRating.allCases[index % 5], at: epoch)
}
for retained in [0, 1, 19, 26, 30] {
    var restored = migrated
    restored.rollback(to: retained)
    let expected = StereoPreferenceSearch(migrating: legacySnapshots[retained])
    try check(restored.mean == expected.mean && restored.covariance == expected.covariance, "Restore legacy curve and uncertainty at \(retained)")
    try check(restored.current == expected.current && restored.completedComparisons == retained && restored.answers.isEmpty, "Crossing migration removes all later stereo and legacy votes")
}
var boundary = migrated
boundary.rollback(to: 31)
try check(boundary.mean == StereoPreferenceSearch(migrating: legacy).mean && boundary.answers.isEmpty, "Restore the exact migration boundary")
print("PASS  Rollback across the shared-ear migration, including skipped votes and refits")

// This is the version-2 schema, before timestamps and random-state checkpoints existed.
struct OldAnswer: Codable {
    let comparison: StereoComparison
    let rating: PreferenceRating
    let direction: [Double]
    let offset: Double
}
struct OldSearch: Codable {
    let mean: [Double]
    let covariance: [[Double]]
    let answers: [OldAnswer]
    let current: StereoComparison?
    let random: SeededRandom
    let priorMean: [Double]
    let priorCovariance: [[Double]]
    let legacyHistory: PreferenceSearch?
}
struct OldProfile: Codable {
    let id: UUID
    let name: String
    let saved: StereoEQCurve
    let session: OldSearch
}
struct OldLibrary: Codable {
    let version: Int
    let profiles: [OldProfile]
    let selected: UUID
}
let oldSearch = try decoder.decode(OldSearch.self, from: encoder.encode(migrated))
let id = UUID()
let oldFile = try encoder.encode(OldLibrary(version: 2, profiles: [OldProfile(id: id, name: "Original headphones", saved: StereoEQCurve(), session: oldSearch)], selected: id))
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("finetune-history-\(UUID())")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let file = folder.appendingPathComponent("profiles.json")
try oldFile.write(to: file)
var library = try ProfileStorage.load(from: file)
try check(try Data(contentsOf: file) == oldFile, "Loading older data must not write to disk")
try check(library.version == 3 && library.selected == id, "Preserve identity and migrate schema")
try check(library.profiles[0].currentCurve == migrated.recommendation, "Current adopts the latest learned curve")
try check(library.profiles[0].session?.answers.allSatisfy { $0.votedAt == nil } == true, "Old votes must not be assigned invented timestamps")
let priorCurrent = library.profiles[0].currentCurve
let priorCount = library.profiles[0].session!.completedComparisons
library.profiles[0].prepareComparison()
try check(library.profiles[0].saved == priorCurrent && library.profiles[0].session?.completedComparisons == priorCount, "Preparing updates the compatibility field without changing votes")
try ProfileStorage.save(library, to: file)
let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("profiles-v2-") }
try check(backups.count == 1, "One original-file backup on migration")
try check(try Data(contentsOf: required(backups.first)) == oldFile, "Preserve the old saved curve and all history in a byte-identical backup")
library.profiles[0].record(.strongB, at: epoch)
try check(library.profiles[0].currentCurve != priorCurrent && library.profiles[0].saved == library.profiles[0].currentCurve, "A vote immediately updates Current")
try ProfileStorage.save(library, to: file)
var reloaded = try ProfileStorage.load(from: file)
try check(reloaded.profiles[0].currentCurve == library.profiles[0].currentCurve && reloaded.profiles[0].session?.current == library.profiles[0].session?.current, "Relaunch retains Current and the pending pair")
try check(reloaded.profiles[0].session?.answers.last?.votedAt == epoch, "Persist vote timestamps")
reloaded.profiles[0].rollback(to: priorCount)
try check(reloaded.profiles[0].currentCurve == priorCurrent && reloaded.profiles[0].saved == priorCurrent, "Rollback immediately restores Current")
try ProfileStorage.save(reloaded, to: file)
let rolledBack = try ProfileStorage.load(from: file)
try check(rolledBack.profiles[0].session?.completedComparisons == priorCount, "Rolled-back votes stay removed after relaunch")
try check(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("profiles-v2-") }.count == 1, "Do not duplicate migration backups")
var oldRollback = try required(rolledBack.profiles[0].session)
oldRollback.rollback(to: 32)
var expectedOld = migrated
expectedOld.rollback(to: 32)
try check(oldRollback.mean == expectedOld.mean && oldRollback.covariance == expectedOld.covariance, "Undated version-2 votes still roll back exactly")
try FileManager.default.removeItem(at: folder)
print("PASS  Version-2 migration, original-file backup, immediate adoption, persistence, and old-history replay")

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let day = Date(timeIntervalSince1970: 1_699_920_000)
var grouping = StereoPreferenceSearch(seed: 17)
let dates: [Date?] = [nil, nil, day, day.addingTimeInterval(1800), day.addingTimeInterval(3601), day.addingTimeInterval(86399), day.addingTimeInterval(86401)]
for date in dates { _ = grouping.next(); grouping.answer(.indistinguishable, at: date) }
let groups = VoteHistoryGroup.grouped(grouping.voteHistory, calendar: calendar)
try check(groups.map(\.entries.count) == [2, 2, 1, 1, 1], "Group undated votes, use a 30-minute idle threshold, and split midnight")
try check(groups.map(\.id) == [0, 2, 4, 5, 6], "Groups identify the first vote to remove")
let retainedCount = groups[2].id
grouping.rollback(to: retainedCount)
try check(grouping.completedComparisons == retainedCount && grouping.voteHistory.last?.id == retainedCount - 1, "Session rollback removes that session and every newer session")
try check(VoteHistoryGroup.grouped([]).isEmpty, "Empty history is valid")
print("PASS  History session boundaries, unknown dates, and whole-session rollback")

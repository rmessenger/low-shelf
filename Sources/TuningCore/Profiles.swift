import Foundation

public struct HeadphoneProfile: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var saved: StereoEQCurve
    public var session: StereoPreferenceSearch?
    public var slider: SliderSearch?
    public init(name: String) {
        id = UUID(); self.name = name; saved = StereoEQCurve()
    }
    public var currentCurve: StereoEQCurve { slider?.curve ?? session?.recommendation ?? saved }
    public mutating func prepareSlider(seed: UInt64) {
        let initial = currentCurve
        slider = SliderSearch(initial: initial, seed: seed)
        saved = initial
        session = nil
    }
    public mutating func acceptSlider(_ position: Double) {
        slider?.accept(position)
        saved = currentCurve
    }
    @discardableResult
    public mutating func prepareComparison() -> Bool {
        var changed = false
        if session == nil {
            session = StereoPreferenceSearch(initial: saved, seed: UInt64.random(in: 1...UInt64.max))
            changed = true
        }
        if session?.current == nil { _ = session?.next(); changed = true }
        if saved != currentCurve { saved = currentCurve; changed = true }
        return changed
    }
    public mutating func record(_ rating: PreferenceRating, at date: Date = Date()) {
        guard session?.current != nil else { return }
        session?.answer(rating, at: date)
        saved = currentCurve
        _ = session?.next()
    }
    public mutating func rollback(to retainedCount: Int) {
        session?.rollback(to: retainedCount)
        saved = currentCurve
    }
    private enum CodingKeys: String, CodingKey { case id, name, saved, session, slider }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        saved = try container.decode(StereoEQCurve.self, forKey: .saved)
        slider = try container.decodeIfPresent(SliderSearch.self, forKey: .slider)
        guard container.contains(.session), try !container.decodeNil(forKey: .session) else { session = nil; return }
        let sessionDecoder = try container.superDecoder(forKey: .session)
        let fields = try sessionDecoder.container(keyedBy: SessionKeys.self)
        if fields.contains(.priorMean) {
            session = try StereoPreferenceSearch(from: sessionDecoder)
        } else {
            let legacy = try PreferenceSearch(from: sessionDecoder)
            guard legacy.valid else { throw ProfileFailure(message: "Invalid legacy tuning history.") }
            session = StereoPreferenceSearch(migrating: legacy)
        }
    }
    private enum SessionKeys: String, CodingKey { case priorMean }
}
public struct ProfileLibrary: Codable, Sendable {
    public var version = 3
    public var profiles: [HeadphoneProfile] = []
    public var selected: UUID?
    public init() {}
    public var index: Int? { profiles.firstIndex { $0.id == selected } }
    public var profile: HeadphoneProfile? { index.map { profiles[$0] } }
    public mutating func add(name: String) {
        let profile = HeadphoneProfile(name: name)
        profiles.append(profile); selected = profile.id
    }
    public func validate() throws {
        guard (1...3).contains(version), Set(profiles.map(\.id)).count == profiles.count,
              selected == nil || index != nil else { throw ProfileFailure(message: "Unsupported or damaged profile file.") }
        for profile in profiles {
            guard profile.saved.valid, profile.session?.valid != false, profile.slider?.valid != false else {
                throw ProfileFailure(message: "Invalid EQ or tuning history in profile file.")
            }
        }
    }
}
public struct ProfileFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}
public enum ProfileStorage {
    private struct StoredVersion: Decodable { let version: Int }
    public static func load(from url: URL) throws(ProfileFailure) -> ProfileLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return ProfileLibrary() }
        do {
            var result = try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: url))
            try result.validate()
            result.version = 3
            return result
        } catch { throw ProfileFailure(message: "Could not load profiles: \(error.localizedDescription). The existing file has been preserved.") }
    }
    public static func save(_ library: ProfileLibrary, to url: URL) throws(ProfileFailure) {
        do {
            try library.validate()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try Data(contentsOf: url)
                let previous = try JSONDecoder().decode(StoredVersion.self, from: existing)
                guard (1...3).contains(previous.version) else { throw ProfileFailure(message: "Unsupported profile version on disk.") }
                if previous.version < 3 {
                    let backup = url.deletingLastPathComponent().appendingPathComponent("profiles-v\(previous.version)-\(UUID().uuidString).json")
                    try existing.write(to: backup, options: .withoutOverwriting)
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(library).write(to: url, options: .atomic)
        } catch { throw ProfileFailure(message: "Could not save profiles: \(error.localizedDescription)") }
    }
}
extension EQCurve {
    var valid: Bool { gains.count == Self.count && gains.allSatisfy { $0.isFinite && abs($0) <= 12 } }
}

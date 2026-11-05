import Foundation

public enum SliderProfileStorage {
    public static let filename = "profiles-slider.json"
    public static func open(in folder: URL) throws(ProfileFailure) -> ProfileLibrary {
        let experiment = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: experiment.path) {
            let library = try ProfileStorage.load(from: experiment)
            guard library.profiles.allSatisfy({ $0.slider != nil && $0.session == nil }) else {
                throw ProfileFailure(message: "The slider profile file contains an unexpected tuning format. It has been preserved.")
            }
            return library
        }
        let original = folder.appendingPathComponent("profiles.json")
        guard FileManager.default.fileExists(atPath: original.path) else { return ProfileLibrary() }
        do {
            let data = try Data(contentsOf: original)
            var library = try JSONDecoder().decode(ProfileLibrary.self, from: data)
            try library.validate()
            let backup = folder.appendingPathComponent("Backups/BeforeSlider-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try data.write(to: backup.appendingPathComponent("profiles.json"), options: .withoutOverwriting)
            for i in library.profiles.indices {
                library.profiles[i].prepareSlider(seed: UInt64.random(in: 1...UInt64.max))
            }
            library.version = 3
            try ProfileStorage.save(library, to: experiment)
            return library
        } catch { throw ProfileFailure(message: "Could not start the slider experiment: \(error.localizedDescription). Original voting profiles have not been changed.") }
    }
}

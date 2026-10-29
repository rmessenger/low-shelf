// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LowShelf",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LowShelf", targets: ["LowShelf"])],
    targets: [
        .target(name: "BassDSP", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "TuningCore"),
        .executableTarget(name: "TuningChecks", dependencies: ["TuningCore", "BassDSP"], path: "Tests/TuningChecks"),
        .executableTarget(name: "StereoTuningChecks", dependencies: ["TuningCore", "BassDSP"], path: "Tests/StereoTuningChecks"),
        .target(name: "HotKeySupport", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HotKeyChecks", dependencies: ["HotKeySupport"], path: "Tests/HotKeyChecks", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "LowShelf", dependencies: ["BassDSP", "HotKeySupport", "TuningCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "DSPChecks", dependencies: ["BassDSP"], path: "Tests/BassDSPTests")
    ]
)

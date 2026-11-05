// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FineTune",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FineTune", targets: ["FineTune"])],
    targets: [
        .target(name: "BassDSP", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "TuningCore"),
        .executableTarget(name: "TuningChecks", dependencies: ["TuningCore", "BassDSP"], path: "Tests/TuningChecks"),
        .executableTarget(name: "StereoTuningChecks", dependencies: ["TuningCore", "BassDSP"], path: "Tests/StereoTuningChecks"),
        .executableTarget(name: "HistoryChecks", dependencies: ["TuningCore"], path: "Tests/HistoryChecks"),
        .executableTarget(name: "SliderChecks", dependencies: ["TuningCore"], path: "Tests/SliderChecks"),
        .target(name: "HotKeySupport", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "HotKeyChecks", dependencies: ["HotKeySupport"], path: "Tests/HotKeyChecks", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FineTune", dependencies: ["BassDSP", "HotKeySupport", "TuningCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "DSPChecks", dependencies: ["BassDSP"], path: "Tests/BassDSPTests")
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LowShelf",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LowShelf", targets: ["LowShelf"])],
    targets: [
        .target(name: "BassDSP", linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(name: "LowShelf", dependencies: ["BassDSP"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "DSPChecks", dependencies: ["BassDSP"], path: "Tests/BassDSPTests")
    ]
)

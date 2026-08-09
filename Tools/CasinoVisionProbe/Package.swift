// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CasinoVisionProbe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CasinoVisionProbe",
            path: "Sources/CasinoVisionProbe"
        )
    ]
)

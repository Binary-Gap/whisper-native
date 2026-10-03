// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicPause",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MusicPause", targets: ["MusicPause"]),
    ],
    targets: [
        .target(name: "MusicPause"),
        .testTarget(name: "MusicPauseTests", dependencies: ["MusicPause"]),
    ]
)

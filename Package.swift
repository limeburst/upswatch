// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "upswatch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "upswatch", path: "Sources/upswatch"),
    ]
)

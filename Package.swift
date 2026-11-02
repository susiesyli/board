// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Board",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Board", path: "Sources/Board")
    ]
)

// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Tapper",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Tapper", path: "Sources/Tapper")]
)

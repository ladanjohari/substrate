// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SubstrateBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SubstrateBar", path: "Sources/SubstrateBar")
    ]
)

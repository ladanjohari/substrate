// swift-tools-version:5.9
import PackageDescription

// One package, three products, one core.
//
// The store used to be Python talking to Swift over HTTP, which meant the two
// could disagree about a rule, and twice they did. As a library that both the
// app and the command line link, there is one copy of every rule and the
// compiler checks it.
let package = Package(
    name: "Substrate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SubstrateCore", targets: ["SubstrateCore"]),
        .executable(name: "SubstrateBar", targets: ["SubstrateBar"]),
        .executable(name: "substrate-swift", targets: ["SubstrateCLI"]),
        .executable(name: "substrate-selftest", targets: ["SubstrateSelfTest"]),
    ],
    targets: [
        .target(name: "SubstrateCore", path: "Sources/SubstrateCore"),
        .executableTarget(name: "SubstrateBar", dependencies: ["SubstrateCore"],
                          path: "Sources/SubstrateBar"),
        .executableTarget(name: "SubstrateCLI", dependencies: ["SubstrateCore"],
                          path: "Sources/SubstrateCLI"),
        // Not a testTarget: XCTest needs full Xcode, and this has to run for
        // anyone who can run `swift build`.
        .executableTarget(name: "SubstrateSelfTest", dependencies: ["SubstrateCore"],
                          path: "Sources/SubstrateSelfTest"),
    ]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Imp",
    platforms: [.macOS(.v14)],
    targets: [
        // C, for the parts Swift cannot reach: undeclared libSystem symbols and the wait(2) macros
        .target(name: "CImp"),
        .executableTarget(name: "Imp", dependencies: ["CImp"]),
        .testTarget(name: "ImpTests", dependencies: ["CImp", "Imp"]),
    ]
)

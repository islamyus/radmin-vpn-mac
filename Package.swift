// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RadminVPNMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RadminVPN", targets: ["RadminMac"]),
        .executable(name: "radmin-bridge", targets: ["RadminBridge"]),
        .executable(name: "radmin-research", targets: ["RadminResearch"])
    ],
    targets: [
        .target(name: "RadminCore"),
        .target(name: "CUtun"),
        .executableTarget(name: "RadminMac", dependencies: ["RadminCore"]),
        .executableTarget(name: "RadminBridge", dependencies: ["RadminCore", "CUtun"]),
        .executableTarget(name: "RadminResearch", dependencies: ["RadminCore"]),
        .testTarget(name: "RadminCoreTests", dependencies: ["RadminCore"])
    ]
)

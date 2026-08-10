// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "branch-radar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "branch-radar", targets: ["BranchRadarCLI"]),
        .library(name: "BranchRadarCore", targets: ["BranchRadarCore"])
    ],
    targets: [
        .target(name: "BranchRadarCore"),
        .executableTarget(
            name: "BranchRadarCLI",
            dependencies: ["BranchRadarCore"]
        ),
        .testTarget(
            name: "BranchRadarCoreTests",
            dependencies: ["BranchRadarCore"]
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Voxel",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything real lives here so both the agent and the CLI share one implementation.
        .target(name: "VoxelCore"),

        // The always-running background agent. Ships as CoreAudioHelper.app (LSUIElement).
        .executableTarget(name: "CoreAudioHelper", dependencies: ["VoxelCore"]),

        // Operator CLI: capture a profile, run a leak report.
        .executableTarget(name: "voxel", dependencies: ["VoxelCore"]),
    ]
)

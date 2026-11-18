// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Forkcast",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared Codable models + the `wait`/guard expression language (used by app and CLI).
        .target(name: "ForkcastCore", path: "Sources/ForkcastCore"),
        .executableTarget(
            name: "Forkcast",
            dependencies: ["ForkcastCore"],
            path: "Sources/Forkcast",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The `forkcast` command-line tool (installed as Forkcast.app/Contents/Helpers/forkcast).
        .executableTarget(name: "ForkcastCLI", dependencies: ["ForkcastCore"], path: "Sources/ForkcastCLI"),
    ]
)

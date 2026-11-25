// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PasteTrove",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PasteTrove",
            path: "Sources/PasteTrove",
            // Optimize release builds for size: same search speed, smaller app.
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Carbon")]
        ),
        .testTarget(name: "PasteTroveTests", dependencies: ["PasteTrove"], path: "Tests/PasteTroveTests"),
    ]
)

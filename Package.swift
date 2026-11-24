// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PasteTrove",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PasteTrove",
            path: "Sources/PasteTrove",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Carbon")]
        )
    ]
)

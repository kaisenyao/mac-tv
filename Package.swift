// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacTV",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacTV",
            path: "Sources/MacTV",
            // The phone remote's web page (Features/Remote/RemotePage.swift serves it).
            resources: [.copy("Features/Remote/Page")]
        ),
        .testTarget(name: "MacTVTests", dependencies: ["MacTV"], path: "Tests/MacTVTests")
    ]
)

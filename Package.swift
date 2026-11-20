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
        // Keeps the tests away from Mac TV's real folders, the test runner's own preferences and the real Keychain
        // (Tests/TestSandbox/TestSandbox.m).
        .target(name: "TestSandbox", path: "Tests/TestSandbox", publicHeadersPath: "."),
        .testTarget(name: "MacTVTests", dependencies: ["MacTV", "TestSandbox"], path: "Tests/MacTVTests")
    ]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacTV",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacTV",
            path: "Sources/MacTV",
            // The phone remote's web page (Features/Remote/RemotePage.swift serves it), and Jasmine's start and end
            // sounds (PianaSoul's cue-active.mp3 and cue-end.mp3: Features/Assistant/Core/Chimes.swift plays them).
            resources: [.copy("Features/Remote/Page"), .copy("Features/Assistant/Sounds")]
        ),
        // Keeps the tests away from Mac TV's real folders, the test runner's own preferences and the real Keychain
        // (Tests/TestSandbox/TestSandbox.m).
        .target(name: "TestSandbox", path: "Tests/TestSandbox", publicHeadersPath: "."),
        .testTarget(name: "MacTVTests", dependencies: ["MacTV", "TestSandbox"], path: "Tests/MacTVTests")
    ]
)

import AppKit

/// Every action Mac TV takes on the Mac itself passes here first: turning the display off or waking it, sleeping
/// the Mac, keeping it or its display awake, the lid's sleep switch, the output's volume and mute and which output
/// plays, a display's DDC volume, keys posted to another app, the login item, and opening System Settings. In a
/// test run none of them reach the real Mac: each is refused, logged and recorded instead (`refused`), so a test can
/// check it was asked for and a missed fake can never act. (Navigation sounds and haptics simply stay off in a test
/// run: see Feedback.play.)
///
/// A test run is: TestSandbox's MACTV_SYSTEM=fake (set as the test bundle loads, before any test runs),
/// MACTV_DATA_DIR (the tests' data folder; a development run with it set is kept off the real Mac too), or a test
/// bundle loaded in the process.
enum SystemGuard {
    static let fake: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["MACTV_SYSTEM"] == "fake" || environment["MACTV_DATA_DIR"] != nil
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
            || NSClassFromString("XCTestCase") != nil
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []

    /// True when `action` may act on the real Mac. In a test run: false, after logging and recording it.
    static func allows(_ action: String) -> Bool {
        guard fake else { return true }
        lock.withLock { log.append(action) }
        Log.system.notice("Test run: refused \(action, privacy: .public)")
        return false
    }

    /// What a test run asked of the Mac and was refused, oldest first.
    static var refused: [String] { lock.withLock { log } }
    static func forgetRefused() { lock.withLock { log = [] } }

    /// Opens a System Settings page (or any address that leaves Mac TV for another app).
    static func open(_ url: URL) {
        guard allows("open \(url.absoluteString)") else { return }
        NSWorkspace.shared.open(url)
    }
}

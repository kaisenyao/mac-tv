import Foundation
import IOKit.pwr_mgt

/// Reports nearby user activity to power management without injecting input into an app.
enum DisplayPower {
    typealias Declare = (inout IOPMAssertionID) -> IOReturn
    typealias Release = @Sendable (IOPMAssertionID) -> Void
    typealias Schedule = (@escaping @Sendable () -> Void) -> Void

    /// Success means macOS accepted the request, not that an external display powered on.
    /// The short-lived assertion is released after the wake request has had time to propagate.
    @discardableResult
    static func wake(
        declare: Declare = { assertion in
            IOPMAssertionDeclareUserActivity("Mac TV remote display wake" as CFString, kIOPMUserActiveLocal, &assertion)
        },
        release: @escaping Release = { _ = IOPMAssertionRelease($0) },
        schedule: Schedule = { action in DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: action) }
    ) -> Bool {
        var assertion: IOPMAssertionID = 0
        guard declare(&assertion) == kIOReturnSuccess else { return false }
        let acquired = assertion
        schedule { release(acquired) }
        return true
    }
}

/// 遥控器（手机、Siri Remote）的按键不经过系统的输入事件（Siri Remote 的按键被 Mac TV 独占了），
/// 系统不知道有人在用，屏幕会按系统设置的时间自己熄掉。有输入时报告一次用户活动，几秒最多一次。
struct RemoteActivity {
    static let interval: TimeInterval = 5
    private var lastReport: TimeInterval = -.infinity

    /// True when this input should be reported (the last report was long enough ago).
    mutating func shouldReport(at time: TimeInterval) -> Bool {
        guard time - lastReport >= Self.interval else { return false }
        lastReport = time
        return true
    }

    @MainActor private static var shared = RemoteActivity()

    /// Called for each remote input; tells power management someone is using the Mac.
    @MainActor static func note(_ time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if shared.shouldReport(at: time) { DisplayPower.wake() }
    }
}

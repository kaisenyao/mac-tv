import Testing
@testable import MacTV

/// 手机遥控器的转盘：手机把还没送到的格数攒在一起送，Mac 收到几格就走几格
@Suite
struct RemoteWheelTests {
    private func steps(_ d: Any?) -> Int? {
        var json: [String: Any] = ["a": "wheel"]
        if let d { json["d"] = d }
        guard case .wheel(let steps)? = RemoteCommand(json: json) else { return nil }
        return steps
    }

    @Test
    func wheelKeepsTheStepsItWasSent() {
        #expect(steps(3) == 3)
        #expect(steps(-2) == -2)
        #expect(steps(nil) == 1)        // 老版本的网页不带格数：一格
        #expect(steps(40) == 16)        // 一次最多 16 格
        #expect(steps(-40) == -16)
        #expect(steps(0) == nil)        // 0 格不算一条指令
    }
}

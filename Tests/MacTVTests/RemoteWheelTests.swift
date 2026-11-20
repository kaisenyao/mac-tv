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

    /// 手机上的 OK 和键盘上的回车是同一个键：点一下是确认，按住是按住确认（卡片菜单、右边的面板）
    @Test
    func okIsTheSameKeyAsReturn() {
        if case .select? = RemoteCommand(json: ["a": "ok"]) {} else { Issue.record("OK 应该是确认") }
        if case .longSelect? = RemoteCommand(json: ["a": "okhold"]) {} else { Issue.record("按住 OK 应该是按住确认") }
    }

    /// 手机上的按键：点一下 / 按住 / 还按着 / 松开，键名、阶段不认识的不算
    @Test
    func pressesCarryKeyAndPhase() {
        if case .press(.right, .hold)? = RemoteCommand(json: ["a": "press", "k": "right", "p": "hold"]) {} else { Issue.record("按住右") }
        if case .press(.select, .tap)? = RemoteCommand(json: ["a": "press", "k": "select", "p": "tap"]) {} else { Issue.record("点 OK") }
        if case .press(.back, .release)? = RemoteCommand(json: ["a": "press", "k": "back", "p": "release"]) {} else { Issue.record("松开返回") }
        #expect(RemoteCommand(json: ["a": "press", "k": "jump", "p": "tap"]) == nil)
        #expect(RemoteCommand(json: ["a": "press", "k": "up", "p": "wiggle"]) == nil)
    }

    /// 手机触控板的双指滑动：阶段要认得，移动量有上限（防止一条坏数据把焦点甩飞）
    @Test
    func swipesCarryPhaseAndClampedDeltas() {
        if case .swipe(let dx, let dy, "changed")? = RemoteCommand(json: ["a": "swipe", "p": "changed", "dx": 12.5, "dy": -3.0]) {
            #expect(dx == 12.5 && dy == -3)
        } else { Issue.record("双指滑动") }
        if case .swipe(let dx, _, "momentum")? = RemoteCommand(json: ["a": "swipe", "p": "momentum", "dx": 99999.0]) {
            #expect(dx == 2000)
        } else { Issue.record("惯性") }
        #expect(RemoteCommand(json: ["a": "swipe", "p": "sideways"]) == nil)
        if case .pointerHold? = RemoteCommand(json: ["a": "mousehold"]) {} else { Issue.record("按住不动") }
    }
}

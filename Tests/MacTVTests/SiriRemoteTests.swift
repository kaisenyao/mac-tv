import AppKit
import Foundation
import Testing
@testable import MacTV

/// Siri Remote：按键（和手机遥控器一样报点一下 / 按住 / 还按着 / 松开）、沿外圈转、触控面滑动和惯性
@Suite
struct SiriRemoteTests {
    // MARK: Buttons

    @Test
    func usagesMatchWhatTheRemoteSends() {
        // 在 Mac mini（macOS 27.2.1）上用真遥控器按出来的
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0x42) == .up)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0x43) == .down)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0x44) == .left)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0x45) == .right)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0x80) == .select)
        #expect(SiriRemoteButton(usagePage: 0x01, usage: 0x86) == .back)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0x60) == .tv)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0xCD) == .playPause)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0xE9) == .volumeUp)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0xEA) == .volumeDown)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0xE2) == .mute)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0x04) == .siri)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0x30) == .power)
        #expect(SiriRemoteButton(usagePage: 0x0C, usage: 0x01) == nil)
    }

    @Test
    func buttonsMapToThePhoneRemotesKeys() {
        let keys: [(SiriRemoteButton, PhonePresses.Key)] = [
            (.up, .up), (.down, .down), (.left, .left), (.right, .right),
            (.select, .select), (.back, .back), (.tv, .home),
        ]
        for (button, key) in keys {
            var r = SiriRemoteRecognizer()
            #expect(r.press(button, at: 0) == [])
            #expect(r.release(button, at: 0.1) == [.press(key, .tap)])
        }
    }

    @Test
    func directionsHoldAfterAThirdOfASecondLikeThePhone() {
        var r = SiriRemoteRecognizer()
        #expect(r.press(.up, at: 0) == [])
        #expect(r.nextDeadline == 0.35)
        #expect(r.advance(to: 0.2) == [])
        #expect(r.advance(to: 0.35) == [.press(.up, .hold)])
        #expect(r.advance(to: 0.65) == [.press(.up, .alive)])    // 还按着：每 0.3 秒报一次
        #expect(r.release(.up, at: 0.8) == [.press(.up, .release)])
        #expect(r.nextDeadline == nil)
    }

    @Test
    func selectBackAndTVHoldAfterHalfASecond() {
        for (button, key) in [(SiriRemoteButton.select, PhonePresses.Key.select), (.back, .back), (.tv, .home)] {
            var r = SiriRemoteRecognizer()
            _ = r.press(button, at: 0)
            #expect(r.advance(to: 0.4) == [])
            #expect(r.release(button, at: 0.45) == [.press(key, .tap)])
            _ = r.press(button, at: 1)
            #expect(r.advance(to: 1.5) == [.press(key, .hold)])
            #expect(r.release(button, at: 2.5) == [.press(key, .release)])   // 按住过：松开不算一次"按一下"
        }
    }

    @Test
    func aLateTimerGivesOneUpdateNotABurst() {
        var r = SiriRemoteRecognizer()
        _ = r.press(.right, at: 0)
        #expect(r.advance(to: 2) == [.press(.right, .hold)])
        #expect(r.nextDeadline == 2.3)
    }

    @Test
    func volumeActsOnPressAndRepeatsLikeThePhone() {
        var r = SiriRemoteRecognizer()
        #expect(r.press(.volumeUp, at: 0) == [.volume(6)])
        #expect(r.advance(to: 0.45) == [.volume(6)])
        #expect(r.advance(to: 0.61) == [.volume(6)])
        #expect(r.release(.volumeUp, at: 0.7) == [])
        #expect(r.nextDeadline == nil)
        #expect(r.press(.volumeDown, at: 1) == [.volume(-6)])
        #expect(r.release(.volumeDown, at: 1.1) == [])
    }

    @Test
    func mediaKeysActOnPress() {
        var r = SiriRemoteRecognizer()
        #expect(r.press(.playPause, at: 0) == [.playPause])
        #expect(r.release(.playPause, at: 0.1) == [])
        #expect(r.press(.mute, at: 1) == [.mute])
        #expect(r.press(.power, at: 2) == [.power])
        #expect(r.press(.siri, at: 3) == [])          // Siri 键：先不用
        #expect(r.release(.siri, at: 4) == [])
        #expect(r.nextDeadline == nil)
    }

    @Test
    func disconnectingMidHoldLetsGo() {
        var r = SiriRemoteRecognizer()
        _ = r.press(.down, at: 0)
        _ = r.advance(to: 0.35)
        _ = r.press(.select, at: 0.4)     // 没按到"按住"：不算一次"按一下"
        #expect(r.reset() == [.press(.down, .release)])
        #expect(r.nextDeadline == nil)
        #expect(r.advance(to: 1) == [])
    }

    // MARK: Touch

    private typealias P = SiriRemoteTouch.Point

    /// A finger going around the outer edge, starting at the top.
    private func circle(turns: Double, clockwise: Bool, radius: Double = 0.4) -> [P] {
        let frames = Int(60 * turns)
        return (0...frames).map { i in
            let a = .pi / 2 + (clockwise ? -1 : 1) * 2 * .pi * turns * Double(i) / Double(frames)
            return P(x: 0.5 + radius * cos(a), y: 0.5 + radius * sin(a))
        }
    }

    private func line(from a: P, to b: P, frames: Int = 30) -> [P] {
        (0...frames).map { i in
            let t = Double(i) / Double(frames)
            return P(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// Plays frames 15 ms apart (the remote sends about 67 a second), then lifts the finger.
    private func play(_ points: [P], on r: inout SiriRemoteRecognizer, from start: TimeInterval = 0) -> [SiriRemoteAction] {
        var actions: [SiriRemoteAction] = []
        for (i, p) in points.enumerated() { actions += r.touchFrame(p, at: start + Double(i) * 0.015) }
        actions += r.touchFrame(nil, at: start + Double(points.count) * 0.015)
        return actions
    }

    /// Runs the timer until nothing is left to do.
    private func drain(_ r: inout SiriRemoteRecognizer) -> [SiriRemoteAction] {
        var actions: [SiriRemoteAction] = []
        var guardCount = 0
        while let deadline = r.nextDeadline, guardCount < 1000 {
            actions += r.advance(to: deadline)
            guardCount += 1
        }
        return actions
    }

    private func wheelTotal(_ actions: [SiriRemoteAction]) -> Int {
        actions.reduce(0) { if case .wheel(let s) = $1 { return $0 + s }; return $0 }
    }

    private func phases(_ actions: [SiriRemoteAction]) -> [String] {
        actions.compactMap { if case .swipe(_, _, let phase) = $0 { return phase }; return nil }
    }

    private func moved(_ actions: [SiriRemoteAction], _ phase: String) -> (dx: Double, dy: Double) {
        actions.reduce((0.0, 0.0)) { sum, action in
            guard case .swipe(let dx, let dy, let p) = action, p == phase else { return sum }
            return (sum.0 + dx, sum.1 + dy)
        }
    }

    @Test
    func turningClockwiseIsEightStepsATurn() {
        // 一圈 8 格；开头的 25 度只是"开始转"，不算格数：(360 - 25) / 45 = 7
        var r = SiriRemoteRecognizer()
        let actions = play(circle(turns: 1, clockwise: true), on: &r)
        #expect(wheelTotal(actions) == 7)
        #expect(actions.allSatisfy { $0 == .wheel(1) })
    }

    @Test
    func turningCounterclockwiseGoesBack() {
        var r = SiriRemoteRecognizer()
        let actions = play(circle(turns: 1, clockwise: false), on: &r)
        #expect(wheelTotal(actions) == -7)
        #expect(actions.allSatisfy { $0 == .wheel(-1) })
    }

    @Test
    func swipingAcrossIsASwipeLikeThePhones() {
        // 实测：左滑从 (0.92, 0.41) 到 (0.05, 0.36)
        var r = SiriRemoteRecognizer()
        let left = play(line(from: P(x: 0.92, y: 0.41), to: P(x: 0.05, y: 0.36)), on: &r)
        #expect(wheelTotal(left) == 0)
        #expect(phases(left).first == "began")
        #expect(phases(left).last == "ended")
        #expect(abs(moved(left, "changed").dx - (-0.87 * SiriRemoteTouch.swipeScale)) < 1)

        // 手指离开时还在动：接着是惯性，往同一个方向，慢慢停下
        let glide = drain(&r)
        #expect(phases(glide).last == "momentumEnd")
        #expect(phases(glide).dropLast().allSatisfy { $0 == "momentum" })
        #expect(moved(glide, "momentum").dx < -50)
        #expect(r.nextDeadline == nil)
    }

    @Test
    func upIsNegativeLikeATrackpad() {
        var r = SiriRemoteRecognizer()
        let up = play(line(from: P(x: 0.43, y: 0.03), to: P(x: 0.46, y: 0.77)), on: &r)
        #expect(wheelTotal(up) == 0)
        #expect(moved(up, "changed").dy < 0)
    }

    @Test
    func aSlowDragIsNotASwipe() {
        // 慢慢挪过去（1.2 秒走了直径的 40%）是拇指搭着在动，不是滑
        var r = SiriRemoteRecognizer()
        #expect(play(line(from: P(x: 0.2, y: 0.5), to: P(x: 0.6, y: 0.5), frames: 80), on: &r) == [])
    }

    @Test
    func aSwipeThatStopsBeforeLiftingDoesNotGlide() {
        var r = SiriRemoteRecognizer()
        let swipeThenStop = line(from: P(x: 0.2, y: 0.5), to: P(x: 0.7, y: 0.5), frames: 12) + Array(repeating: P(x: 0.7, y: 0.5), count: 10)
        let actions = play(swipeThenStop, on: &r)
        #expect(phases(actions).first == "began")
        #expect(Array(phases(actions).suffix(2)) == ["ended", "momentumEnd"])
        #expect(r.nextDeadline == nil)
    }

    @Test
    func touchingAgainStopsTheGlide() {
        var r = SiriRemoteRecognizer()
        _ = play(line(from: P(x: 0.9, y: 0.5), to: P(x: 0.1, y: 0.5)), on: &r)
        #expect(r.nextDeadline != nil)
        #expect(r.touchFrame(P(x: 0.5, y: 0.5), at: 1) == [.swipe(dx: 0, dy: 0, phase: "momentumEnd")])
        #expect(r.nextDeadline == nil)
    }

    @Test
    func aRestingFingerDoesNothing() {
        var r = SiriRemoteRecognizer()
        let jitter = (0..<40).map { i in P(x: 0.7 + 0.01 * sin(Double(i)), y: 0.5 + 0.01 * cos(Double(i))) }
        #expect(play(jitter, on: &r) == [])
    }

    @Test
    func clickingThePadIsNotASwipe() {
        var r = SiriRemoteRecognizer()
        // 手指放上去，按下去的时候手指滑了一点
        #expect(r.touchFrame(P(x: 0.5, y: 0.5), at: 0) == [])
        #expect(r.press(.select, at: 0.05) == [])
        #expect(r.touchFrame(P(x: 0.5, y: 0.65), at: 0.1) == [])
        #expect(r.release(.select, at: 0.2) == [.press(.select, .tap)])
        #expect(r.touchFrame(P(x: 0.5, y: 0.8), at: 0.25) == [])
        #expect(r.touchFrame(nil, at: 0.3) == [])
        // 下一次触摸照常
        #expect(wheelTotal(play(circle(turns: 0.5, clockwise: true), on: &r, from: 1)) == 3)
    }

    @Test
    func aClickAlwaysCountsAndStopsTheTurn() {
        // 实测：拇指搭在圆盘上连按"左"，按之前手指总会挪一点；以前被认成转圈，按键全被吞了
        var r = SiriRemoteRecognizer()
        var actions: [SiriRemoteAction] = []
        for (i, p) in circle(turns: 0.5, clockwise: true).prefix(20).enumerated() { actions += r.touchFrame(p, at: Double(i) * 0.015) }
        #expect(wheelTotal(actions) > 0)
        #expect(r.press(.right, at: 0.3) == [])
        #expect(r.release(.right, at: 0.35) == [.press(.right, .tap)])
        // 手指没抬起来之前，再怎么挪都不算转
        #expect(wheelTotal(circle(turns: 0.5, clockwise: true).enumerated().flatMap { r.touchFrame($1, at: 0.4 + Double($0) * 0.015) }) == 0)
    }

    @Test
    func aClickEndsASwipeWithoutAGlide() {
        var r = SiriRemoteRecognizer()
        var actions: [SiriRemoteAction] = []
        for (i, p) in line(from: P(x: 0.9, y: 0.5), to: P(x: 0.4, y: 0.5), frames: 10).enumerated() {
            actions += r.touchFrame(p, at: Double(i) * 0.015)
        }
        #expect(phases(actions).first == "began")
        #expect(phases(r.press(.select, at: 0.2)) == ["ended", "momentumEnd"])
        #expect(r.release(.select, at: 0.3) == [.press(.select, .tap)])
    }

    @Test
    func aRestingThumbThatDriftsDoesNothing() {
        // 实测：拇指搭在圆盘上 10 秒，慢慢挪了直径的 8%，以前被认成一次滑动
        var r = SiriRemoteRecognizer()
        let drift = (0..<700).map { i in P(x: 0.55 - 0.1 * Double(i) / 700, y: 0.56 + 0.03 * sin(Double(i) / 50)) }
        #expect(play(drift, on: &r) == [])
        // 慢慢绕着外圈挪也不算转
        let slowArc = (0..<400).map { i in
            let a = .pi / 2 - Double(i) / 400 * .pi / 2
            return P(x: 0.5 + 0.4 * cos(a), y: 0.5 + 0.4 * sin(a))
        }
        #expect(play(slowArc, on: &r, from: 20) == [])
    }

    @Test
    func aPressStopsTheGlide() {
        var r = SiriRemoteRecognizer()
        _ = play(line(from: P(x: 0.9, y: 0.5), to: P(x: 0.1, y: 0.5)), on: &r)
        #expect(r.nextDeadline != nil)
        #expect(r.press(.back, at: 1) == [.swipe(dx: 0, dy: 0, phase: "momentumEnd")])
        _ = r.release(.back, at: 1.1)
        #expect(r.nextDeadline == nil)
    }

    @Test
    func disconnectingMidSwipeEndsIt() {
        var r = SiriRemoteRecognizer()
        var actions: [SiriRemoteAction] = []
        for (i, p) in line(from: P(x: 0.5, y: 0.1), to: P(x: 0.5, y: 0.5), frames: 12).enumerated() {
            actions += r.touchFrame(p, at: Double(i) * 0.015)
        }
        #expect(phases(actions).first == "began")
        #expect(phases(r.reset()) == ["ended", "momentumEnd"])
        #expect(r.touchFrame(P(x: 0.5, y: 0.6), at: 1) == [])
    }
}

/// 遥控器有输入时报告用户活动：几秒最多一次
@Suite
struct RemoteActivityTests {
    @Test
    func reportsAtMostOnceEveryFewSeconds() {
        var activity = RemoteActivity()
        let reports = [100, 101, 104.9, 105, 106].map { activity.shouldReport(at: $0) }
        #expect(reports == [true, false, false, true, false])
    }
}

/// 控制中心、设置这些弹出的面板里：滑一下走一格，方向跟着手指
@Suite
struct SiriRemoteSheetSwipeTests {
    @Test
    func oneStepPerSwipeTheWayTheFingerWent() {
        var s = SiriRemoteSheetSwipe()
        var steps: [RemoteCommand.Direction?] = []
        steps.append(s.feed(dx: 0, dy: 0, phase: "began"))
        steps.append(s.feed(dx: 30, dy: 5, phase: "changed"))
        steps.append(s.feed(dx: 40, dy: 5, phase: "changed"))   // 70 点：走一格
        steps.append(s.feed(dx: 200, dy: 0, phase: "changed"))  // 同一次滑动不再走
        steps.append(s.feed(dx: 300, dy: 0, phase: "momentum")) // 惯性不走
        #expect(steps == [nil, nil, .right, nil, nil])

        var next: [RemoteCommand.Direction?] = []
        next.append(s.feed(dx: 0, dy: 0, phase: "began"))
        next.append(s.feed(dx: 5, dy: -80, phase: "changed"))   // 手指往上
        #expect(next == [nil, .up])
    }
}

/// 控制中心：和 Apple TV 一样，走到边上停住，按返回才关（遥控器一滑容易冲过头）
@Suite @MainActor
struct ControlCenterEdgeTests {
    @Test
    func movingPastTheEdgeKeepsItOpen() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.handle(.controlCenter)
        for _ in 0..<6 { tv.handleControlCenter(.move(.up)) }
        #expect(tv.controlCenter != nil)
        for _ in 0..<6 { tv.handleControlCenter(.move(.down)) }
        #expect(tv.controlCenter != nil)
        tv.handleControlCenter(.back)
        #expect(tv.controlCenter == nil)
    }

    @Test
    func theTVButtonPutsItAway() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.handle(.controlCenter)            // 按住 TV 键：拉下来
        #expect(tv.controlCenter != nil)
        tv.handle(.home)                     // 再按一下：收回去，不做别的
        #expect(tv.controlCenter == nil)
    }
}

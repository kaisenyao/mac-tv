import AppKit
import Foundation
import Testing
@testable import MacTV

/// 遥控器（Siri Remote、手机的点按区）上焦点跟着手指走，像 Apple TV：往右 / 上滑焦点往右 / 上，到处都一样，
/// 甩出去的惯性也接着往这边走。Mac 的触控板和手机触控板上的双指滑动不变：内容跟着手指走（挑选、面板里光标跟着手指走）。
/// 方向只在 TrackpadGestures.towardsNext 一处定
@Suite @MainActor
struct SwipeDirectionTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    private func withTV(_ body: (TVController) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(TVController(library: AppLibrary(folder: folder)))
    }

    /// 一次滑动从哪来
    enum Source: CaseIterable { case siriRemote, clickpad, touchpad, macTrackpad }

    /// 手指往哪滑一次，连同松手后的惯性：dx / dy 往右 / 往下为正
    private func swipe(_ tv: TVController, _ source: Source, dx: Double, dy: Double) {
        switch source {
        case .siriRemote:
            // 触控面上的位置 0–1，原点在左下：手指往上是 y 变大。150 点是触控面的 0.1 到 0.9
            let a = SiriRemoteTouch.Point(x: 0.5 - dx / 375, y: 0.5 + dy / 375)
            let b = SiriRemoteTouch.Point(x: 0.5 + dx / 375, y: 0.5 - dy / 375)
            var r = SiriRemoteRecognizer()
            var actions: [SiriRemoteAction] = []
            for i in 0...12 {
                let t = Double(i) / 12
                actions += r.touchFrame(SiriRemoteTouch.Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), at: Double(i) * 0.015)
            }
            actions += r.touchFrame(nil, at: 0.2)
            while let deadline = r.nextDeadline { actions += r.advance(to: deadline) }
            #expect(actions.contains { if case .swipe(_, _, "momentum") = $0 { return true }; return false }, "it glides")
            for action in actions { tv.siriRemote(action) }
        case .clickpad, .touchpad:
            // 手机送的：点按区上的滑动带着 "focus": true，触控板上的双指滑动不带
            func send(_ phase: String, _ dx: Double = 0, _ dy: Double = 0) {
                var json: [String: Any] = ["a": "swipe", "p": phase, "dx": dx, "dy": dy]
                if source == .clickpad { json["focus"] = true }
                guard let command = RemoteCommand(json: json) else { Issue.record("swipe \(phase)"); return }
                tv.handle(command, from: .remote)
            }
            send("began")
            for _ in 0..<6 { send("changed", dx / 6, dy / 6) }
            send("ended")
            for _ in 0..<10 { send("momentum", dx / 2, dy / 2) }
            send("momentumEnd")
        case .macTrackpad:
            func feed(_ phase: TrackpadGestures.Sample.Phase, _ momentum: TrackpadGestures.Sample.Momentum, _ dx: Double = 0, _ dy: Double = 0) {
                #expect(tv.trackpadGestures.feed(.init(dx: dx, dy: dy, phase: phase, momentum: momentum, precise: true), from: .trackpad))
            }
            feed(.began, .none)
            for _ in 0..<6 { feed(.changed, .none, dx / 6, dy / 6) }
            feed(.ended, .none)
            for _ in 0..<10 { feed(.none, .changed, dx / 2, dy / 2) }
            feed(.none, .ended)
        }
    }

    /// 方向键从这里会走到哪（按一下，再按反方向回来）
    private func keyTarget(_ tv: TVController, _ direction: RemoteCommand.Direction) throws -> TVController.Focus {
        let start = tv.focus
        let back: RemoteCommand.Direction = [.up: .down, .down: .up, .left: .right, .right: .left][direction]!
        tv.handle(.move(direction))
        let target = tv.focus
        tv.handle(.move(back))
        try #require(tv.focus == start, "\(direction) and back")
        try #require(target != start, "\(direction) goes somewhere from \(start)")
        return target
    }

    @Test
    func directionIsChosenInOnePlace() {
        let modules: [TVController.Module] = [.strip, .drawer, .picker]
        for module in modules {
            // 遥控器：往右 / 往下滑（为正）是下一个，不管在哪
            #expect(TrackpadGestures.towardsNext(40, in: module, focusFollowsFinger: true))
            #expect(!TrackpadGestures.towardsNext(-40, in: module, focusFollowsFinger: true))
        }
        // 触控板：长条、区域之间内容跟着手走（往左 / 往上滑是下一个），挑选是光标跟着手走
        #expect(TrackpadGestures.towardsNext(-40, in: .strip, focusFollowsFinger: false))
        #expect(TrackpadGestures.towardsNext(-40, in: .drawer, focusFollowsFinger: false))
        #expect(!TrackpadGestures.towardsNext(40, in: .strip, focusFollowsFinger: false))
        #expect(TrackpadGestures.towardsNext(40, in: .picker, focusFollowsFinger: false))
    }

    /// 主屏那几排：遥控器往右滑焦点往右，往上滑焦点往上（上到 Top Shelf），往下滑回来；惯性不多走、不往回走
    @Test(arguments: [Source.siriRemote, .clickpad])
    func remotesMoveFocusTheFingersWayOnHome(_ source: Source) throws {
        try withTV { tv in
            try #require(tv.mode == .launcher && tv.activeSheet == nil)
            let right = try keyTarget(tv, .right)
            swipe(tv, source, dx: 150, dy: 4)
            #expect(tv.focus == right, "finger right: focus right")
            let up = try keyTarget(tv, .up)
            swipe(tv, source, dx: -3, dy: -150)
            #expect(tv.focus == up, "finger up: focus up")
            let down = try keyTarget(tv, .down)
            swipe(tv, source, dx: 2, dy: 150)
            #expect(tv.focus == down, "finger down: focus down")
            let left = try keyTarget(tv, .left)
            swipe(tv, source, dx: -150, dy: 0)
            #expect(tv.focus == left, "finger left: focus left")
        }
    }

    /// 触控板（Mac 的、手机上的双指）不变：图标一排里光标跟着手走（往右滑往右），上下是内容跟着手走（往下滑上到 Top Shelf）
    @Test(arguments: [Source.touchpad, .macTrackpad])
    func touchpadsKeepContentFollowingTheFingerOnHome(_ source: Source) throws {
        try withTV { tv in
            try #require(tv.mode == .launcher && tv.activeSheet == nil)
            let right = try keyTarget(tv, .right)
            swipe(tv, source, dx: 150, dy: 4)
            #expect(tv.focus == right, "picker: the cursor follows the finger, as before")
            let up = try keyTarget(tv, .up)
            swipe(tv, source, dx: 2, dy: 150)
            #expect(tv.focus == up, "finger down: the content comes down, focus goes up")
            let down = try keyTarget(tv, .down)
            swipe(tv, source, dx: -3, dy: -150)
            #expect(tv.focus == down, "finger up: back down")
        }
    }

    /// 长条（哔哩哔哩的视频排）：遥控器往左滑焦点往左（第一张上就进左边栏）；
    /// 触控板往左滑是内容往左、焦点往右（第一张上不进左边栏），往右滑才进左边栏
    @Test(arguments: Source.allCases)
    func onAStripRemotesGoTheFingersWayAndTouchpadsTheContents(_ source: Source) throws {
        let remote = source == .siriRemote || source == .clickpad
        let rows = BilibiliStore.Focus.rows, sidebar = BilibiliStore.Focus.sidebar
        try withTV { tv in
            tv.bilibiliOpen = true
            try #require(tv.module(horizontal: true) == .strip && tv.bilibiliStore.focus == rows)
            swipe(tv, source, dx: -150, dy: 3)
            #expect(tv.bilibiliStore.focus == (remote ? sidebar : rows), "finger left")
        }
        try withTV { tv in
            tv.bilibiliOpen = true
            swipe(tv, source, dx: 150, dy: -3)
            #expect(tv.bilibiliStore.focus == (remote ? rows : sidebar), "finger right")
        }
    }

    /// 弹出的面板（控制中心）：谁来的都一样，光标跟着手指走，一次滑动一格，下面的主屏不动
    @Test(arguments: Source.allCases)
    func panelsAreTheSameForEverySource(_ source: Source) throws {
        try withTV { tv in
            let home = tv.focus
            tv.handle(.controlCenter)
            #expect(tv.controlCenter?.item == .audio)
            swipe(tv, source, dx: 4, dy: 150)        // 手指往下：下一格，惯性不再走
            #expect(tv.controlCenter?.item == .phone)
            swipe(tv, source, dx: 0, dy: -150)       // 往上
            #expect(tv.controlCenter?.item == .audio)
            swipe(tv, source, dx: -150, dy: 20)      // 往左
            #expect(tv.controlCenter?.item == .sleepMac)
            #expect(tv.focus == home)
        }
    }

    /// 拖进度不走 towardsNext：谁来的移动量都原样交给它（手指往右为正 = 往前）。
    /// 遥控器那边没有把移动量反过来：Siri Remote 往右滑是正的，手机点按区送的也是
    @Test
    func scrubbingGetsTheFingersOwnMovement() {
        var r = SiriRemoteRecognizer()
        var actions: [SiriRemoteAction] = []
        for i in 0...12 {
            actions += r.touchFrame(SiriRemoteTouch.Point(x: 0.1 + 0.8 * Double(i) / 12, y: 0.5), at: Double(i) * 0.015)
        }
        let moved = actions.reduce(0.0) { if case .swipe(let dx, _, "changed") = $1 { return $0 + dx }; return $0 }
        #expect(moved > 0, "finger right is positive, the way scrubbing reads it")
        if case .swipe(let dx, _, _, true)? = RemoteCommand(json: ["a": "swipe", "p": "changed", "dx": 30.0, "focus": true]) {
            #expect(dx == 30)
        } else { Issue.record("clickpad swipe") }
    }
}

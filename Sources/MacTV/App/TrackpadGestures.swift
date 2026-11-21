import AppKit

/// 双指滑动（规则见 TVController.Module）：一次滑动从手指放上去到惯性停下。
///
/// Mac 的触控板、鼠标滚轮，手机遥控器触控板上的双指滑动、点按区上的滑动，和 Siri Remote 上的滑动，都走这一处——
/// 同样的门槛、同样的惯性、同样的声音和震动。触控板来的是系统的滚动事件（main.swift 把它换成 Sample），
/// 手机和 Siri Remote 来的是它们自己量出来的手指移动和惯性（RemoteCommand.swipe）。
/// 只有方向分两种（见 towardsNext）：遥控器上焦点跟着手指走，触控板上内容跟着手指走。
@MainActor
final class TrackpadGestures {
    /// 一下滚动：移动了多少（点；往左 / 往上为负，和 Mac 的"自然滚动"一样），手指在哪个阶段、惯性在哪个阶段
    struct Sample {
        enum Phase { case none, began, changed, ended }
        enum Momentum { case none, changed, ended }
        var dx: Double
        var dy: Double
        var phase: Phase
        var momentum: Momentum
        /// 触控板（有阶段、有精确的移动量）；滚轮是 false
        var precise: Bool
        /// 遥控器（Siri Remote、手机的点按区）：焦点跟着手指走，像 Apple TV 的 Siri Remote（见 towardsNext）
        var focusFollowsFinger = false
    }

    /// 方向只在这里定：这一段移动（往右 / 往下为正）算不算往"下一个"（往右 / 往下）走。
    /// - 遥控器（focusFollowsFinger）：焦点跟着手指走，像 Apple TV 的 Siri Remote——往右 / 往下滑是下一个，
    ///   长条、区域之间、挑选、面板里都一样，手指离开后的惯性也接着往这边走
    /// - Mac 的触控板、滚轮、手机触控板上的双指滑动：长条和区域之间是内容跟着手走，往左 / 往上滑（为负）是下一个；
    ///   挑选是光标跟着手走，往右 / 往下滑（为正）是下一个
    /// 拖进度不走这里：谁来的都是手指往右往前
    static func towardsNext(_ moved: CGFloat, in module: TVController.Module, focusFollowsFinger: Bool) -> Bool {
        focusFollowsFinger || module == .picker ? moved > 0 : moved < 0
    }

    private weak var tv: TVController?
    private var scrollTotal: CGFloat = 0
    private var scrollReadyAt = Date.distantPast
    /// 这一次滑动已经走过格子了
    private var swipedInGesture = false
    /// 这一次滑动是横着还是竖着：刚开始滑时按哪个方向动得多来定，滑完之前不变（斜着滑不会两个方向都走）
    private var scrollHorizontal: Bool?
    /// 这一次滑动在当前界面算哪一类，和方向一起定下来
    private var swipeModule: TVController.Module = .drawer
    /// 甩出去以后已经走了几格：越往后每一格要的距离越长，慢慢停下
    private var flungSteps = 0

    init(tv: TVController) { self.tv = tv }

    /// 这一下归不归这里管：应用里（主屏、哔哩哔哩、网易云……）和弹出的面板归这里；网页播放器这些不归，
    /// 交给原来的处理（比如网页里滚动页面）。
    /// 弹出的面板（控制中心、设置、添加应用、配对、设置向导、"谁在看"……）是"挑选"（见 module(horizontal:)）：
    /// 一次滑动走一格，方向跟着手指，惯性不走。Mac 的触控板、手机、Siri Remote 都一样，滑动不会漏到面板下面去
    func feed(_ s: Sample, from source: Feedback.Source) -> Bool {
        // 网页里的滑动是滚动网页；浏览器的工具栏、总览开着时归这里（在里面挑、换卡片）
        guard let tv, tv.mode == .launcher || tv.browserChromeUp else { return false }

        tv.suppressHover = true
        PointerActivity.shared.set(false)

        let flicking = scrollHorizontal != nil && swipeModule == .strip

        // 一次滑动的开始和结束。长条上的滑动在手指离开后还有惯性，惯性停了才算完
        if s.phase == .began {
            scrollTotal = 0
            swipedInGesture = false
            scrollHorizontal = nil
            swipeModule = .drawer
            flungSteps = 0
        }
        if s.momentum == .ended {
            scrollHorizontal = nil
            return true
        }
        if s.momentum == .changed, !flicking { return true }
        if s.phase == .ended {
            if scrollHorizontal == true, swipeModule == .scrub { tv.endScrub() }   // 拖进度：手指抬起才跳过去
            if !flicking { scrollHorizontal = nil }
            return true
        }

        let dx = CGFloat(s.dx), dy = CGFloat(s.dy)
        if !s.precise {
            // 滚轮没有"一次滑动"：每一格自己定方向，和长条一样一格一格走
            scrollHorizontal = abs(dx) > abs(dy)
            let style = tv.module(horizontal: abs(dx) > abs(dy))
            swipeModule = style == .off || style == .scrub ? style : .drawer   // 滚轮拖进度：一格快进 / 快退（多少秒各应用自己定）
        } else if scrollHorizontal == nil, max(abs(dx), abs(dy)) > 0.5 {
            scrollHorizontal = abs(dx) > abs(dy)
            swipeModule = tv.module(horizontal: abs(dx) > abs(dy))
        }
        guard let horizontal = scrollHorizontal, swipeModule != .off else { return true }
        let delta = horizontal ? dx : dy
        let next: RemoteCommand.Direction = horizontal ? .right : .down
        let previous: RemoteCommand.Direction = horizontal ? .left : .up
        // 往哪走（遥控器焦点跟着手指，触控板内容跟着手指；见 towardsNext）
        let module = swipeModule
        let toward = { (moved: CGFloat) -> RemoteCommand.Direction in
            Self.towardsNext(moved, in: module, focusFollowsFinger: s.focusFollowsFinger) ? next : previous
        }

        if s.precise, swipeModule == .scrub {
            // 拖进度：手指滑多远，进度就跟着走多远（往右滑往前），手指抬起才跳过去
            tv.scrubMove(points: Double(delta))
        } else if !s.precise {
            guard Date() >= scrollReadyAt else { return true }
            scrollTotal += delta
            if abs(scrollTotal) >= 1.0 {
                // 拖进度的地方（视频、音乐、听书播放中），滚轮左右一格是快进 / 快退（多少秒各应用自己定）；别的地方是走一格
                tv.handle(swipeModule == .scrub ? .seek(forward: scrollTotal > 0) : .move(toward(scrollTotal)), from: source)
                scrollTotal = 0
                scrollReadyAt = Date().addingTimeInterval(0.32)
            }
        } else if swipeModule == .strip {
            // 长条：手指还在时一段一格地跟着走；手指离开后的惯性照样走，甩得越用力走得越远，
            // 每走一格下一格要的距离就长一点，慢慢停下（像 Safari）。轻轻一拨只走一格
            scrollTotal += delta
            let threshold: CGFloat = !swipedInGesture ? 30
                : (s.momentum == .none ? 150 : 170 + 35 * CGFloat(flungSteps))
            if abs(scrollTotal) >= threshold {
                let direction = toward(scrollTotal)
                scrollTotal += scrollTotal < 0 ? threshold : -threshold
                // 第一格照常（可以走到别的区域，比如在第一张上往左拨进左边栏）；
                // 接着走的只在这一条里，到头就停
                if !swipedInGesture || tv.flickCanMove(direction) { tv.handle(.move(direction), from: source) }
                swipedInGesture = true
                if s.momentum != .none { flungSteps += 1 }
            }
        } else {
            // 光标、区域之间：一次滑动只走一格
            guard !swipedInGesture else { return true }
            scrollTotal += delta
            if abs(scrollTotal) >= 28 {
                tv.handle(.move(toward(scrollTotal)), from: source)
                scrollTotal = 0
                swipedInGesture = true
            }
        }
        return true
    }
}

extension TrackpadGestures.Sample {
    /// 系统的滚动事件（触控板、鼠标滚轮）
    init(_ event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas || !event.phase.isEmpty
        dx = Double(precise ? event.scrollingDeltaX : (event.deltaX != 0 ? event.deltaX : event.scrollingDeltaX))
        dy = Double(precise ? event.scrollingDeltaY : (event.deltaY != 0 ? event.deltaY : event.scrollingDeltaY))
        phase = event.phase.contains(.began) ? .began
            : (event.phase.contains(.ended) || event.phase.contains(.cancelled)) ? .ended
            : event.phase.isEmpty ? .none : .changed
        momentum = (event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)) ? .ended
            : event.momentumPhase.isEmpty ? .none : .changed
        self.precise = precise
    }
}

/// Views that scroll themselves under the pointer (the browser's tab strip): a mouse wheel or trackpad scroll over one,
/// while the pointer is in use, goes to it before Mac TV's own scroll rules (TrackpadGestures), so a long row of tabs
/// follows the hand anywhere — on the Start Page and with focus in the bar too. main.swift's scroll monitor asks first.
@MainActor
enum ScrollClaims {
    private static var handlers: [ObjectIdentifier: (NSEvent) -> Bool] = [:]

    /// `handler` takes a scroll (true) when it's over its view.
    static func add(_ owner: AnyObject, _ handler: @escaping (NSEvent) -> Bool) { handlers[ObjectIdentifier(owner)] = handler }
    static func remove(_ owner: AnyObject) { handlers[ObjectIdentifier(owner)] = nil }

    /// A view under the pointer took this scroll.
    static func take(_ event: NSEvent) -> Bool {
        guard PointerActivity.shared.active else { return false }
        return handlers.values.contains { $0(event) }
    }
}

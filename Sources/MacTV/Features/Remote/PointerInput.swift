import AppKit

// The phone's touchpad as a pointer in Mac TV's window, and remote presses passed on as keys to a
// Mac app or Steam game Mac TV opened.
extension TVController {
    /// 手机触控板送来的一包移动：不直接跳过去，交给 PointerGlide 跟着屏幕刷新一帧一帧走
    func movePointer(dx: Double, dy: Double) {
        guard let window else { return }
        pointerGlide.add(dx: dx, dy: dy, in: window)
    }

    /// 光标停下了：把停下的位置告诉界面（走的途中一秒只告诉 30 次，最后这一下不能省）
    func pointerStopped() {
        guard let pointer else { return }
        lastHoverEvent = CACurrentMediaTime()
        postMouse(.mouseMoved, at: pointer)
    }

    /// 光标真的挪一下（PointerGlide 每一帧调一次）
    func applyPointerMove(dx: Double, dy: Double) {
        guard let window, let bounds = window.contentView?.bounds else { return }
        var point = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        point.x = min(max(point.x + dx, 0), bounds.width - 1)
        point.y = min(max(point.y - dy, 0), bounds.height - 1)
        pointer = point

        let onScreen = window.convertPoint(toScreen: point)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y))
        NSCursor.setHiddenUntilMouseMoves(false)
        // 和真的动了鼠标一样：鼠标停在哪张卡片上就轻轻浮起（按键、滑动时收起，见 PointerActivity）。
        // 光标每一帧都挪，"鼠标动了"这件事告诉界面一秒 30 次就够（浮起的卡片跟得上，界面少算一半）
        suppressHover = false
        PointerActivity.shared.set(true)
        let now = CACurrentMediaTime()
        if now - lastHoverEvent >= 1.0 / 30 {
            lastHoverEvent = now
            postMouse(.mouseMoved, at: point)
        }
    }

    func clickPointer() {
        pointerGlide.finish()
        guard let window, let bounds = window.contentView?.bounds else { return }
        let point = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        postMouse(.leftMouseDown, at: point)
        postMouse(.leftMouseUp, at: point)
    }

    /// 手机触控板上按住不动：和按住鼠标一样（按下、过一会儿再松开），长按出菜单的地方就出菜单
    func holdPointer() {
        pointerGlide.finish()
        guard let window, let bounds = window.contentView?.bounds else { return }
        let point = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        postMouse(.leftMouseDown, at: point)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated { self?.postMouse(.leftMouseUp, at: point) }
        }
    }

    private func postMouse(_ type: NSEvent.EventType, at point: CGPoint) {
        guard let window, let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
            pressure: type == .leftMouseDown ? 1 : 0)
        else { return }
        window.sendEvent(event)
    }

    // MARK: Keys for Mac apps and Steam games

    func forwardToFrontApp(_ command: RemoteCommand) {
        let code: CGKeyCode
        switch command {
        case .move(.left): code = 123
        case .move(.right): code = 124
        case .move(.down): code = 125
        case .move(.up): code = 126
        case .select: code = 36
        case .back: code = 53
        case .playPause: code = 49
        case .deleteBackward: code = 51
        case .text(let text):
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            for character in text {
                var units = Array(String(character).utf16)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    event.postToPid(pid)
                }
            }
            return
        default: return
        }
        SystemControl.postKeyToFrontApp(code)
    }
}

/// 手机触控板的鼠标移动是从网上一包一包到的（一秒几十包、间隔不匀），每包直接跳过去，光标看着一顿一顿的，
/// 像回报率很低的鼠标。这里把收到的移动先记着，跟着屏幕刷新一帧走一截，每一帧都在动：
/// - 一帧走多少按"包和包之间隔多久"来定：包来得密（一帧一包）就一帧走完，来得稀（两三帧一包）就摊到这几帧里，
///   光标速度是匀的，不会走一下、停一下；
/// - 间隔用最近几包平滑着估，偶尔晚到的一包不会让光标忽快忽慢；
/// - 静止时第一包马上走第一截，不等下一帧。
/// 只多出最多一个包间隔的延迟（网好时不到一帧）。没有要走的就把屏幕刷新的回调停掉，不占 CPU
@MainActor
final class PointerGlide: NSObject {
    private var pending = CGVector.zero
    private var link: CADisplayLink?
    /// 包和包之间平均隔多久（秒），和上一包什么时候到的
    private var interval: CFTimeInterval = 1.0 / 60
    private var lastArrival: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    /// 这一次滑动收到几包、最长隔了多久没来（记日志用：看手机到 Mac 这一路顺不顺）
    private var packets = 0
    private var longestGap: CFTimeInterval = 0
    private let move: (Double, Double) -> Void
    /// 走完了（光标停下）
    private let ended: () -> Void

    init(move: @escaping (Double, Double) -> Void, ended: @escaping () -> Void) {
        self.move = move
        self.ended = ended
    }

    func add(dx: Double, dy: Double, in window: NSWindow) {
        let now = CACurrentMediaTime()
        let gap = now - lastArrival
        lastArrival = now
        // 停了一会儿再动（隔了 0.1 秒以上）不算进平均：那是手指停了，不是网慢
        if gap < 0.1 {
            interval += (min(max(gap, 1.0 / 120), 0.05) - interval) * 0.25
            longestGap = max(longestGap, gap)
        }
        packets += 1
        pending.dx += dx
        pending.dy += dy
        guard link == nil else { return }
        let link = window.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastFrame = now
        step(fraction: min(1, (1.0 / 60) / interval))   // 静止后第一包：马上走第一截
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let frame = min(max(now - lastFrame, 1.0 / 240), 0.05)
        lastFrame = now
        // 这一帧走"一帧占一个包间隔的几分之几"，至少走剩下的三成五，免得越积越多
        step(fraction: min(1, max(0.35, frame / interval)))
    }

    private func step(fraction: Double) {
        // 剩下不到半个点：一次走完，停掉屏幕刷新的回调
        let done = abs(pending.dx) < 0.5 && abs(pending.dy) < 0.5
        let dx = done ? pending.dx : pending.dx * fraction, dy = done ? pending.dy : pending.dy * fraction
        pending.dx -= dx
        pending.dy -= dy
        if dx != 0 || dy != 0 { move(dx, dy) }
        if done { stop() }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        if packets >= 20 {
            Log.remote.info("""
                phone touchpad: \(self.packets, privacy: .public) moves, about \(Int(self.interval * 1000), privacy: .public) ms apart, \
                longest gap \(Int(self.longestGap * 1000), privacy: .public) ms
                """)
        }
        packets = 0
        longestGap = 0
        ended()
    }

    /// 还没走完的一次走完（点击、按住之前：点在手指最后停的地方）
    func finish() {
        if pending != .zero { move(pending.dx, pending.dy) }
        pending = .zero
        if link != nil { stop() }
    }
}

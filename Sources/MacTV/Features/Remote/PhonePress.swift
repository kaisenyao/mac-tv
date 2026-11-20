import AppKit

/// 手机遥控器上的按键：和键盘上的同一个键是一样的意思（按一下、按住都一样）。
///
/// 手机自己判断这一下是"点了一下"还是"按住了"（它知道手指按了多久，不受网络快慢影响），
/// 发来四种消息：tap 点了一下、hold 按住了（开始）、alive 还按着、release 松开了。
/// Mac 这边按键盘的规矩来做（规矩和 main.swift 里键盘那一套一样，用的是同样的几个动作）：
///
/// | 键 | 点一下 | 按住 |
/// |---|---|---|
/// | 上下左右 | 走一格 | 按 Mac 的按键重复速度一直走；网易云播放界面里左右是快退 / 快进，松手从那里接着放 |
/// | OK（确认） | 确认 | 卡片菜单、看视频时右边的面板；没有菜单的地方松手时是一次确认 |
/// | 返回 | 返回 | 回主屏（和按住 Esc 一样） |
/// | 主屏 | 回主屏 | 控制中心（和 Siri Remote 上按住电视键一样） |
///
/// 按住时手机每隔一会儿发一次 alive；万一"松开"在网络上丢了，Mac 一秒多收不到就当松开了，不会一直走下去
@MainActor
final class PhonePresses {
    enum Key: String { case up, down, left, right, select, back, home }
    enum Phase: String { case tap, hold, alive, release }

    private weak var tv: TVController?
    /// 正按住的键：按住时在做什么
    private enum Holding { case repeating(Timer), scrubbing, menu, selectOnRelease(Feedback.Source), done }
    private var holding: [Key: Holding] = [:]
    private var watchdogs: [Key: Timer] = [:]

    init(tv: TVController) { self.tv = tv }

    func handle(_ key: Key, _ phase: Phase, from source: Feedback.Source) {
        guard let tv else { return }
        switch phase {
        case .tap:
            release(key)
            switch key {
            case .select: tv.handle(.select, from: source)
            case .back: tv.handle(.back, from: source)
            case .home: tv.handle(.home, from: source)
            default: if let direction = Self.direction(key) { tv.handle(.move(direction), from: source) }
            }
        case .hold:
            release(key)
            begin(key, tv: tv, source: source)
            feed(key)
        case .alive:
            if holding[key] != nil { feed(key) }
        case .release:
            release(key)
        }
    }

    private func begin(_ key: Key, tv: TVController, source: Feedback.Source) {
        switch key {
        case .back:
            tv.handle(.home, from: source)                      // 按住返回 = 回主屏
            holding[key] = .done
        case .home:
            tv.handle(.controlCenter, from: source)             // 按住主屏 = 控制中心
            holding[key] = .done
        case .select:
            if tv.openHoldMenu() {
                tv.feedback.play(.select, from: source)
                holding[key] = .menu
            } else {
                holding[key] = .selectOnRelease(source)                 // 没有菜单的地方：松手时是一次普通的确认（和回车一样）
            }
        case .left, .right, .up, .down:
            guard let direction = Self.direction(key) else { return }
            if key == .left || key == .right, tv.mode == .launcher, tv.neteaseOpen, tv.activeSheet == nil,
               tv.neteaseStore.canHoldSeek {
                tv.neteaseStore.beginHold(forward: key == .right)   // 网易云播放界面：按住左右 = 快退 / 快进
                holding[key] = .scrubbing
                return
            }
            if key == .left || key == .right, tv.mode == .launcher, tv.dedaoOpen, tv.activeSheet == nil,
               tv.dedaoStore.canHoldSeek {
                tv.dedaoStore.beginHold(forward: key == .right)     // 得到的播放界面：和网易云一样
                holding[key] = .scrubbing
                return
            }
            // 别的地方：和按住键盘方向键一样，按 Mac 设置里的按键重复速度一直走
            tv.handle(.move(direction), from: source)
            let interval = min(0.2, max(0.04, NSEvent.keyRepeatInterval))
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self, weak tv] _ in
                MainActor.assumeIsolated {
                    guard let self, let tv, case .repeating? = self.holding[key] else { return }
                    tv.handle(.move(direction), from: source)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            holding[key] = .repeating(timer)
        }
    }

    private func release(_ key: Key) {
        watchdogs.removeValue(forKey: key)?.invalidate()
        guard let state = holding.removeValue(forKey: key), let tv else { return }
        switch state {
        case .repeating(let timer): timer.invalidate()
        case .scrubbing: if tv.dedaoOpen { tv.dedaoStore.endHold() } else { tv.neteaseStore.endScrub() }
        case .selectOnRelease(let source): tv.handle(.select, from: source)
        case .menu, .done: break
        }
    }

    /// 还按着：重新计时。1.2 秒没收到就当松开了
    private func feed(_ key: Key) {
        watchdogs[key]?.invalidate()
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.release(key) }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogs[key] = timer
    }

    private static func direction(_ key: Key) -> RemoteCommand.Direction? {
        switch key {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        default: nil
        }
    }
}

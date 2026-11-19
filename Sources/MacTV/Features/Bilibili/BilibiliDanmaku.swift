@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// 一条弹幕：第几秒出现、怎么走（从右往左飘，或者停在顶上 / 底下）、大小、颜色、内容
struct BiliDanmaku: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case scroll, top, bottom }
    let time: Double
    let kind: Kind
    /// 相对大小：1 是普通，小号 0.8，大号 1.3
    let size: Double
    /// 0xRRGGBB
    let color: UInt32
    let text: String

    /// 从哔哩哔哩的弹幕 XML 里读出来，按出现时间排好。高级弹幕、代码弹幕（7、8）不显示
    static func parse(_ xml: String) -> [BiliDanmaku] {
        guard let pattern = try? NSRegularExpression(pattern: "<d p=\"([^\"]*)\">([^<]*)</d>") else { return [] }
        let source = xml as NSString
        var items: [BiliDanmaku] = []
        for match in pattern.matches(in: xml, range: NSRange(location: 0, length: source.length)) {
            let fields = source.substring(with: match.range(at: 1)).split(separator: ",")
            guard fields.count >= 4, let time = Double(fields[0]), let mode = Int(fields[1]) else { continue }
            let kind: Kind
            switch mode {
            case 1, 2, 3, 6: kind = .scroll
            case 5: kind = .top
            case 4: kind = .bottom
            default: continue
            }
            let text = source.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\n", with: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let fontSize = Double(fields[2]) ?? 25
            items.append(BiliDanmaku(time: time, kind: kind, size: fontSize < 25 ? 0.8 : (fontSize > 25 ? 1.3 : 1),
                                     color: UInt32(fields[3]) ?? 0xFFFFFF, text: text))
        }
        return items.sorted { $0.time < $1.time }
    }
}

/// 弹幕怎么显示：和哔哩哔哩播放器的弹幕设置一样的几项（显示区域、字号、速度、不透明度、按类型屏蔽固定和彩色弹幕）。
/// 记在本机，设置页和看视频时右边的面板里都能改，改了马上按新的样子重新排
struct BiliDanmakuStyle: Equatable, Sendable {
    enum Area: Int, CaseIterable, Sendable {
        case quarter, half, threeQuarters, full
        var title: String { ["1/4", "半屏", "3/4", "满屏"][rawValue] }
        var fraction: Double { [0.25, 0.5, 0.75, 1.0][rawValue] }
    }
    enum Size: Int, CaseIterable, Sendable {
        case small, standard, large
        var title: String { ["小", "标准", "大"][rawValue] }
        var scale: Double { [0.85, 1.0, 1.18][rawValue] }
    }
    /// 飘过整个屏幕用几秒（"适中"是哔哩哔哩全屏时的 9 秒）
    enum Speed: Int, CaseIterable, Sendable {
        case slow, normal, fast
        var title: String { ["较慢", "适中", "较快"][rawValue] }
        var duration: Double { [11.0, 9.0, 7.0][rawValue] }
    }
    enum Opacity: Int, CaseIterable, Sendable {
        case full, high, medium, low
        var title: String { ["100%", "90%", "70%", "50%"][rawValue] }
        var value: Double { [1.0, 0.9, 0.7, 0.5][rawValue] }
    }

    var area = Area.quarter
    var size = Size.standard
    var speed = Speed.normal
    var opacity = Opacity.high
    /// 停在顶上、底下的弹幕（哔哩哔哩叫"固定弹幕"）
    var fixed = true
    /// 不是白色的弹幕
    var colored = true

    private static let key = "bilibiliDanmakuStyle"

    static func load() -> BiliDanmakuStyle {
        var style = BiliDanmakuStyle()
        guard let saved = UserDefaults.standard.dictionary(forKey: key) else { return style }
        style.area = (saved["area"] as? Int).flatMap(Area.init) ?? style.area
        style.size = (saved["size"] as? Int).flatMap(Size.init) ?? style.size
        style.speed = (saved["speed"] as? Int).flatMap(Speed.init) ?? style.speed
        style.opacity = (saved["opacity"] as? Int).flatMap(Opacity.init) ?? style.opacity
        style.fixed = saved["fixed"] as? Bool ?? style.fixed
        style.colored = saved["colored"] as? Bool ?? style.colored
        return style
    }

    func save() {
        UserDefaults.standard.set(["area": area.rawValue, "size": size.rawValue, "speed": speed.rawValue,
                                   "opacity": opacity.rawValue, "fixed": fixed, "colored": colored], forKey: Self.key)
    }

    /// 按类型屏蔽：不要固定弹幕、不要彩色弹幕时先挑掉
    func keeps(_ item: BiliDanmaku) -> Bool {
        if !fixed, item.kind != .scroll { return false }
        if !colored, item.color & 0xFFFFFF != 0xFFFFFF { return false }
        return true
    }
}

/// 弹幕排在哪一行：加载时（或改了弹幕设置时）一次排好，看的时候只按时间算位置，不用每一帧重新排。
///
/// 参数照哔哩哔哩自己开源的弹幕引擎 DanmakuFlameMaster（它的 App 用的就是这个）：
/// 飘的弹幕都是同样的时间从右边飘到左边（所以长的飘得快一点）——原版播放器 682 宽时是 3.8 秒，
/// 按画面宽度放大、最长 9 秒，全屏电视上就是 9 秒；顶上 / 底下的弹幕停 3.8 秒。
/// 一条新弹幕找最上面一行能放的：前一条的尾巴已经完全进了屏幕、而且新的这条到左边之前追不上它；
/// 哪一行都放不下就不显示（宁可少几条，也不叠在一起看不清）。
/// 坐标按 1920×1080 的电视画面算，画的时候按实际大小缩放
struct BiliDanmakuLayout: Equatable, Sendable {
    struct Placed: Hashable, Sendable {
        let item: BiliDanmaku
        let lane: Int
        let width: Double
    }

    static let screenWidth = 1920.0
    static let screenHeight = 1080.0
    /// 标准字号：三米外看电视正好，又不至于一行占太多
    static let standardFont = 34.0
    static let fixedDuration = 3.8
    static let topInset = 28.0
    /// 同一行前后两条之间至少空这么宽
    static let spacing = 36.0

    var fontSize = standardFont
    var scrollDuration = 9.0
    /// 显示区域里放得下几行
    var lanes = 5
    var laneHeight: Double { (fontSize * 1.32).rounded() }

    init(style: BiliDanmakuStyle = BiliDanmakuStyle()) {
        fontSize = Self.standardFont * style.size.scale
        scrollDuration = style.speed.duration
        lanes = max(1, Int((Self.screenHeight * style.area.fraction - Self.topInset) / (fontSize * 1.32).rounded()))
    }

    /// 估一下这条弹幕有多宽：汉字一个字宽，英文数字大约半个字宽
    func width(of text: String, size: Double) -> Double {
        text.reduce(0.0) { $0 + ($1.isASCII ? 0.55 : 1.0) } * fontSize * size
    }

    /// 第几行（从上往下）离屏幕顶上多远；底下的弹幕从离底边 150 的地方往上排
    func top(of entry: Placed) -> Double {
        entry.item.kind == .bottom
            ? Self.screenHeight - 150 - Double(entry.lane + 1) * laneHeight
            : Self.topInset + Double(entry.lane) * laneHeight
    }

    func place(_ items: [BiliDanmaku], screen: Double = screenWidth) -> [Placed] {
        var scrolling: [(time: Double, width: Double)?] = Array(repeating: nil, count: lanes)
        var top: [Double] = Array(repeating: -.infinity, count: lanes)
        var bottom: [Double] = Array(repeating: -.infinity, count: lanes)
        var placed: [Placed] = []
        placed.reserveCapacity(items.count)
        for item in items {
            let width = self.width(of: item.text, size: item.size)
            switch item.kind {
            case .scroll:
                let speed = (screen + width) / scrollDuration
                let lane = scrolling.firstIndex { last in
                    guard let last else { return true }
                    let lastSpeed = (screen + last.width) / scrollDuration
                    let tailIn = item.time >= last.time + (last.width + Self.spacing) / lastSpeed
                    let neverCatches = item.time + screen / speed >= last.time + scrollDuration
                    return tailIn && neverCatches
                }
                if let lane {
                    scrolling[lane] = (item.time, width)
                    placed.append(Placed(item: item, lane: lane, width: width))
                }
            case .top:
                if let lane = top.firstIndex(where: { $0 <= item.time }) {
                    top[lane] = item.time + Self.fixedDuration
                    placed.append(Placed(item: item, lane: lane, width: width))
                }
            case .bottom:
                if let lane = bottom.firstIndex(where: { $0 <= item.time }) {
                    bottom[lane] = item.time + Self.fixedDuration
                    placed.append(Placed(item: item, lane: lane, width: width))
                }
            }
        }
        return placed
    }

    /// 这一刻在屏幕上的那几条（从排好的列表里按时间二分找，不用每一帧从头扫）
    func visible(_ placed: [Placed], at now: Double) -> ArraySlice<Placed> {
        var low = 0, high = placed.count
        let from = now - scrollDuration
        while low < high {
            let mid = (low + high) / 2
            if placed[mid].item.time < from { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < placed.count, placed[end].item.time <= now { end += 1 }
        return placed[low..<end]
    }
}

/// 画弹幕。每条弹幕是一张事先画好的小图（字带一圈淡淡的黑影），从右到左的移动交给系统的
/// "跟着视频时间走的动画层"（AVSynchronizedLayer）：动画按视频的时间轴排好，暂停就停、倍速就跟着快、
/// 拖进度就跳到对的位置，全由系统在显卡上合成——不用每一帧自己重画整个屏幕（那样会卡，也不顺）。
/// 只给"前后几秒内"的弹幕建图层，走过去的就拿掉，图层数量一直很少。
struct BilibiliDanmakuSurface: NSViewRepresentable {
    @ObservedObject var player: BilibiliNativePlayer

    func makeNSView(context: Context) -> BiliDanmakuView { BiliDanmakuView() }

    func updateNSView(_ view: BiliDanmakuView, context: Context) {
        view.update(player: player.player, placed: player.danmaku, layout: player.danmakuLayout,
                    opacity: player.danmakuStyle.opacity.value, visible: player.danmakuOn && player.showing)
    }
}

final class BiliDanmakuView: NSView {
    private let sync = AVSynchronizedLayer()
    private var placed: [BiliDanmakuLayout.Placed] = []
    private var grid = BiliDanmakuLayout()
    private var layers: [Int: CALayer] = [:]
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var timer: Timer?
    private var builtWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(sync)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 播放界面关掉时停掉计时
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { timer?.invalidate(); timer = nil }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 点画面照常是暂停 / 继续

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sync.frame = bounds
        CATransaction.commit()
        if abs(bounds.width - builtWidth) > 1 { clear() }   // 窗口大小变了：位置、字号都按新的宽度重建
        refresh()
    }

    func update(player: AVPlayer, placed: [BiliDanmakuLayout.Placed], layout: BiliDanmakuLayout, opacity: Double, visible: Bool) {
        self.player = player
        // 换了视频、改了弹幕设置（重新排过）：已经建好的图层按新的重来
        if layout != grid || placed.count != self.placed.count || placed.first != self.placed.first || placed.last != self.placed.last {
            clear()
            self.placed = placed
            grid = layout
        }
        sync.opacity = Float(opacity)
        if placed.isEmpty {
            // 这个视频没有弹幕（或还没取到）：放开上一个视频，不让它一直占着内存
            sync.playerItem = nil
            item = nil
        }
        isHidden = !visible
        if visible, !placed.isEmpty {
            if timer == nil {
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.values.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        layers = [:]
        builtWidth = bounds.width
    }

    /// 让"前 9 秒到后 6 秒"之间的弹幕都有图层，这之外的拿掉
    private func refresh() {
        guard let player, bounds.width > 0, !placed.isEmpty else { return }
        if player.currentItem !== item {
            clear()
            item = player.currentItem
            sync.playerItem = item
        }
        guard let item else { return }
        let now = item.currentTime().seconds
        guard now.isFinite else { return }
        // 只提前 2 秒建图层（图层按视频时间自己出场）；拖进度后屏幕上该有的那些一次补上
        let from = now - grid.scrollDuration - 1, to = now + 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in layers where placed[index].item.time < from - 2 || placed[index].item.time > to + 6 {
            layer.removeFromSuperlayer()
            layers[index] = nil
        }
        var low = 0, high = placed.count
        while low < high {
            let mid = (low + high) / 2
            if placed[mid].item.time < from { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < placed.count, placed[index].item.time <= to {
            if layers[index] == nil { layers[index] = makeLayer(placed[index]) }
            index += 1
        }
        CATransaction.commit()
    }

    private func makeLayer(_ entry: BiliDanmakuLayout.Placed) -> CALayer {
        let width = Double(bounds.width), height = Double(bounds.height)
        let scale = width / BiliDanmakuLayout.screenWidth
        let backing = window?.backingScaleFactor ?? 2
        let item = entry.item
        let image = Self.image(item.text, size: grid.fontSize * item.size * scale, color: item.color)
        let layer = CALayer()
        layer.contentsScale = image.recommendedLayerContentsScale(backing)
        layer.contents = image.layerContents(forContentsScale: layer.contentsScale)
        layer.anchorPoint = .zero
        layer.bounds = CGRect(origin: .zero, size: image.size)
        let begin = max(item.time, AVCoreAnimationBeginTimeAtZero)
        // 图层的坐标原点在左下角：从屏幕顶上往下数的位置换算过来
        let fromTop = { (top: Double) in height - top - Double(image.size.height) }
        switch item.kind {
        case .scroll:
            // 速度按排行时算的宽度来（同一行不会追上前一条）；终点按实际画出来的宽度，保证完全出了屏幕
            let speed = (width + entry.width * scale) / grid.scrollDuration
            let travel = width + max(entry.width * scale, Double(image.size.width))
            let y = fromTop(grid.top(of: entry) * scale)
            layer.position = CGPoint(x: -Double(image.size.width), y: y)
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = width
            move.toValue = width - travel
            move.duration = travel / speed
            move.beginTime = begin
            move.timingFunction = CAMediaTimingFunction(name: .linear)
            move.fillMode = .both
            move.isRemovedOnCompletion = false
            layer.add(move, forKey: "move")
        case .top, .bottom:
            let y = fromTop(grid.top(of: entry) * height / BiliDanmakuLayout.screenHeight)
            layer.position = CGPoint(x: (width - Double(image.size.width)) / 2, y: y)
            layer.opacity = 0                    // 平时看不见，只在它那 4 秒里出现
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.duration = BiliDanmakuLayout.fixedDuration
            show.beginTime = begin
            show.isRemovedOnCompletion = false
            layer.add(show, forKey: "show")
        }
        sync.addSublayer(layer)
        return layer
    }

    /// 画好的小图留着：同样的字（"哈哈哈""233"）、大小、颜色再出现时直接用，拖进度回来也不用重画
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    private static func image(_ text: String, size: Double, color: UInt32) -> NSImage {
        let key = "\(color)|\(Int(size * 10))|\(text)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let made = draw(text, size: size, color: color)
        images.setObject(made, forKey: key)
        return made
    }

    /// 一条弹幕画成一张小图。和哔哩哔哩一样是"描边"：字外面一圈清楚的黑边（不是一团模糊的影子），
    /// 亮的画面上也看得清；黑色的弹幕用白边
    private static func draw(_ text: String, size: Double, color: UInt32) -> NSImage {
        let red = (color >> 16) & 0xFF, green = (color >> 8) & 0xFF, blue = color & 0xFF
        let fill = NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        let dark = red < 0x20 && green < 0x20 && blue < 0x20
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        // 先画一遍粗一点的边（只画轮廓），再把字盖在上面：边一半被字盖住，露在外面的是细细一圈
        let outline = NSAttributedString(string: text, attributes: [
            .font: font, .strokeColor: (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.85), .strokeWidth: 11,
        ])
        let body = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fill])
        let pad = ceil(size * 0.1)
        let measured = body.size()
        let imageSize = NSSize(width: ceil(measured.width) + pad * 2, height: ceil(measured.height) + pad * 2)
        return NSImage(size: imageSize, flipped: false) { _ in
            outline.draw(at: NSPoint(x: pad, y: pad))
            body.draw(at: NSPoint(x: pad, y: pad))
            return true
        }
    }
}

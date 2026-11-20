import AppKit
import QuartzCore
import SwiftUI

// MARK: 主屏顶部换页的动画，交给 Core Animation
//
// 轮播 8 秒翻一页，一页的动画有一秒多（新的一页弹簧滑进来、背景颜色慢慢变、小点挪过去）。用 SwiftUI 动画的话，
// 这一秒多里每一帧 SwiftUI 都要在主线程把整屏重算一遍：一页一百多帧，主屏闲着也要占一个核的百分之五六。
// 这里换成同一条弹簧（同样的 response、dampingFraction，同一个公式）、同样的距离和先后，只是交给 Core Animation：
// 主线程只在换页那一下排一次，之后每一帧都在渲染进程里画。看起来、动起来和原来一样。

/// SwiftUI 的 `.spring(response:dampingFraction:)`：质量 1 的阻尼弹簧
struct ShelfSpring {
    let response: Double
    let dampingFraction: Double
    /// 走完（差不到千分之一）要多久
    let settlingDuration: Double

    init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
        let probe = CASpringAnimation()
        probe.mass = 1
        probe.stiffness = pow(2 * .pi / response, 2)
        probe.damping = 4 * .pi * dampingFraction / response
        settlingDuration = probe.settlingDuration
    }

    /// 换页（内容、背景颜色、小点）：和 AppShelf.pageAnimation 同一条
    static let page = ShelfSpring(response: 0.55, dampingFraction: 0.9)
    /// 新的一页滑进来：和原来的插入动画同一条（晚 0.14 秒开始）
    static let insert = ShelfSpring(response: 0.5, dampingFraction: 0.9)

    var stiffness: Double { pow(2 * .pi / response, 2) }
    var damping: Double { 4 * .pi * dampingFraction / response }

    func animation(_ keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = stiffness
        spring.damping = damping
        spring.initialVelocity = 0
        spring.duration = settlingDuration
        return spring
    }

    /// 从 0 走到 1 的位置（t 秒时）
    func progress(_ t: Double) -> Double {
        let omega = 2 * .pi / response, zeta = dampingFraction
        guard t > 0 else { return 0 }
        if zeta < 1 {
            let damped = omega * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
        }
        return 1 - exp(-omega * t) * (1 + omega * t)
    }
}

extension Transaction {
    /// 这一次改动带着动画（换页、颜色下好了）：Core Animation 那边也动；没带（取来了新内容、换了应用）就直接换
    var animatesShelf: Bool { animation != nil && !disablesAnimations }
}

// MARK: 滑进滑出的一块

/// 换页时整块滑进滑出的那一块（封面、书、唱片、左边那一栏字）。一直是同一个视图，里面有前后两层（各是一个
/// NSHostingView）：换页时前面那一层往反方向滑 0.6 倍、0.16 秒淡掉（easeIn），后面那一层换上新的一页，晚 0.14 秒
/// 从翻的那边弹簧滑进来、淡进来，然后两层对调。滑动、淡入淡出都是这两层的 Core Animation 动画：
/// 换页时没有视图插进来、拿出去，里面的东西也一帧都不用重算
struct ShelfPage<Content: View>: NSViewRepresentable {
    /// 往哪边、多远（翻的方向 × 距离）
    let offset: CGFloat
    /// 哪一页：变了就是换页（带动画时滑过去，不带就直接换）
    let id: AnyHashable
    /// 里面画的东西取决于什么（这一页、标签、暂停没有……）：只是这个变了，就在原地重画，不滑。
    /// 都没变就不让里面重算一遍；里面自己盯着的东西（播放进度这些）照常自己更新
    let key: AnyHashable
    @ViewBuilder let content: () -> Content

    struct Hosted: View {
        let content: Content
        let environment: EnvironmentValues
        var body: some View { content.environment(\.self, environment).ignoresSafeArea() }
    }

    final class Coordinator {
        var id: AnyHashable?
        var key: AnyHashable?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ShelfPageView<Hosted> {
        context.coordinator.id = id
        context.coordinator.key = key
        return ShelfPageView(Hosted(content: content(), environment: context.environment))
    }

    func updateNSView(_ view: ShelfPageView<Hosted>, context: Context) {
        let coordinator = context.coordinator
        if coordinator.id != id {
            coordinator.id = id
            coordinator.key = key
            let hosted = Hosted(content: content(), environment: context.environment)
            if context.transaction.animatesShelf { view.turn(to: hosted, offset: offset) } else { view.replace(with: hosted) }
        } else if coordinator.key != key {
            // 同一页，里面的东西变了（暂停了、标签换了）：原地重画。翻页时整个顶部会重算几次（先定方向、再换页），
            // 这一块的内容没变就不动它，省得里面整个再排一遍
            coordinator.key = key
            view.update(Hosted(content: content(), environment: context.environment))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShelfPageView<Hosted>, context: Context) -> CGSize? {
        nsView.size(for: proposal)
    }
}

final class ShelfPageView<Hosted: View>: NSView {
    /// 一层：一个放 NSHostingView 的盒子（动画加在盒子的图层上）
    @MainActor final class Layer {
        let controller: NSHostingController<Hosted>
        let box = NSView()
        init(_ hosted: Hosted) {
            controller = NSHostingController(rootView: hosted)
            controller.sizingOptions = []          // 大小由外面这一层定（sizeThatFits），不靠 Auto Layout
            controller.safeAreaRegions = []
            box.wantsLayer = true
            box.clipsToBounds = false              // 影子画在框外面
            controller.view.clipsToBounds = false
            controller.view.autoresizingMask = [.width, .height]
            box.addSubview(controller.view)
        }
    }

    /// 看得见的那一层，和等着下一页的那一层（第一次翻页时才建）
    private(set) var front: Layer
    private(set) var back: Layer?
    /// 还没换进前面那一层的内容（见 turn）
    private var pending: Hosted?
    private var pendingTurn = 0
    /// 量过的大小（同一份内容，一帧里 SwiftUI 会按几种宽高问好几次；每一次都要把里面整个排一遍）
    private var sizes: [SizeKey: CGSize] = [:]
    struct SizeKey: Hashable { let width: Double?, height: Double? }

    init(_ hosted: Hosted) {
        front = Layer(hosted)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        addSubview(front.box)
        // 第二层趁闲着的时候先建好（一秒以后），第一次翻页那一帧就不用现建一个 NSHostingView
        ShelfPageSchedule.later(1) { [weak self] in
            guard let self, self.back == nil else { return }
            let spare = Layer(self.front.controller.rootView)
            spare.box.layer?.opacity = 0
            spare.box.frame = self.bounds
            spare.controller.view.frame = spare.box.bounds
            self.addSubview(spare.box, positioned: .below, relativeTo: self.front.box)
            self.back = spare
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        for layer in [front, back].compactMap({ $0 }) {
            layer.box.frame = bounds
            layer.controller.view.frame = layer.box.bounds
        }
    }

    /// 只有看得见的那一层接鼠标
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return front.box.hitTest(convert(local, to: front.box.superview)) ?? nil
    }

    func size(for proposal: ProposedViewSize) -> CGSize? {
        let key = SizeKey(width: proposal.width.map(Double.init), height: proposal.height.map(Double.init))
        if let known = sizes[key] { return known }
        let size = front.controller.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity, height: proposal.height ?? .infinity))
        sizes[key] = size
        return size
    }

    /// 不带动画地换成这一页（取来了新内容、换了人）
    func replace(with hosted: Hosted) {
        pending = nil
        for layer in [front, back].compactMap({ $0 }) { layer.box.layer?.removeAllAnimations() }
        back?.box.layer?.opacity = 0
        front.box.layer?.opacity = 1
        front.controller.rootView = hosted
        sizes = [:]
    }

    /// 同一页里的东西变了：在原地重画
    func update(_ hosted: Hosted) {
        if pending != nil { pending = hosted; return }
        front.controller.rootView = hosted
        sizes = [:]
    }

    /// 翻页：前面那一层滑走、淡掉；后面那一层换上新的一页，晚 0.14 秒从 offset 那边弹簧滑进来、淡进来
    func turn(to hosted: Hosted, offset: CGFloat) {
        let leaving = front
        slideOut(leaving, offset: offset)
        let coming: Layer
        if let back {
            coming = back
            // 新的一页 0.14 秒以后才露出来：里面的内容晚一两帧再换（几块错开，一帧一块），换页那一帧不用一下子
            // 把整页排完、画完。同一个位置的每一页一样大，这之前照上一页量好的大小排
            pending = hosted
            pendingTurn += 1
            let turn = pendingTurn
            ShelfPageSchedule.next { [weak self] in
                guard let self, self.pendingTurn == turn, let hosted = self.pending else { return }
                self.pending = nil
                coming.controller.rootView = hosted
            }
        } else {
            coming = Layer(hosted)
            coming.box.frame = bounds
            coming.controller.view.frame = coming.box.bounds
            addSubview(coming.box)
            pending = nil
        }
        // 滑进来的那一层放在上面
        addSubview(coming.box, positioned: .above, relativeTo: leaving.box)
        back = leaving
        front = coming
        slideIn(coming, offset: offset)
    }

    private func slideIn(_ layer: Layer, offset: CGFloat) {
        guard let caLayer = layer.box.layer else { return }
        caLayer.removeAllAnimations()
        caLayer.opacity = 1
        let start = caLayer.convertTime(CACurrentMediaTime(), from: nil) + 0.14
        let move = ShelfSpring.insert.animation("transform.translation.x")
        move.fromValue = offset
        move.toValue = 0
        move.isAdditive = true
        let fade = ShelfSpring.insert.animation("opacity")
        fade.fromValue = 0
        fade.toValue = 1
        for animation in [move, fade] {
            animation.beginTime = start
            animation.fillMode = .backwards
            caLayer.add(animation, forKey: "in-" + (animation.keyPath ?? ""))
        }
    }

    /// 从现在画到的样子（换到一半又翻一页时，也是从那里）滑走、淡掉，之后一直看不见
    private func slideOut(_ layer: Layer, offset: CGFloat) {
        guard let caLayer = layer.box.layer else { return }
        let shown = caLayer.presentation()
        let fromX = (shown?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        let fromOpacity = shown?.opacity ?? caLayer.opacity
        caLayer.removeAllAnimations()
        caLayer.opacity = 0
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = fromX
        move.toValue = -offset * 0.6
        move.isAdditive = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = 0
        for animation in [move, fade] {
            animation.duration = 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            caLayer.add(animation, forKey: "out-" + (animation.keyPath ?? ""))
        }
    }
}

/// 一帧做一件：第一件下一帧，第二件再下一帧……（换页时几块内容错开换，见 ShelfPageView.turn）
@MainActor enum ShelfPageSchedule {
    /// 过多久做（平时是主队列；测试里自己挑时候）
    static var later: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
    private static var waiting = 0

    static func next(_ work: @escaping @MainActor () -> Void) {
        waiting += 1
        later(Double(waiting) / 90) {
            waiting -= 1
            work()
        }
    }
}

// MARK: 出现时滑进来的一块

/// 一出现就从 distance 那边沿一条弹簧滑到原位（晚 delay 秒开始），像 `.onAppear { withAnimation { … } }` 那样，
/// 只是滑动交给 Core Animation：里面的东西画一次，滑的每一帧都不用 SwiftUI 重画（唱片的纹路、影子很费）
struct ShelfSlideIn<Content: View>: NSViewRepresentable {
    let distance: CGFloat
    let delay: Double
    let spring: ShelfSpring
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ShelfSlideView<Content> {
        ShelfSlideView(NSHostingView(rootView: content()), distance: distance, delay: delay, spring: spring)
    }

    func updateNSView(_ view: ShelfSlideView<Content>, context: Context) {
        view.host.rootView = content()
    }
}

final class ShelfSlideView<Content: View>: NSView {
    let host: NSHostingView<Content>
    private let distance: CGFloat, delay: Double, spring: ShelfSpring
    private var slid = false

    init(_ host: NSHostingView<Content>, distance: CGFloat, delay: Double, spring: ShelfSpring) {
        self.host = host
        self.distance = distance
        self.delay = delay
        self.spring = spring
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        host.clipsToBounds = false
        host.sizingOptions = []
        host.safeAreaRegions = []
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !slid, let layer else { return }
        slid = true
        let move = spring.animation("transform.translation.x")
        move.fromValue = distance
        move.toValue = 0
        move.isAdditive = true
        move.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        move.fillMode = .backwards
        layer.add(move, forKey: "slide-in")
    }
}

// MARK: 背景

/// 背景的一层（铺满整屏）：一片颜色、线性渐变或圆形渐变。和 SwiftUI 的 Color、LinearGradient、RadialGradient 画出来一样
struct ShelfGradient: Equatable {
    enum Kind: Equatable {
        case solid
        case linear(start: UnitPoint, end: UnitPoint)
        case radial(center: UnitPoint, radius: CGFloat)
    }
    var kind: Kind
    var colors: [Color]
    var locations: [CGFloat]? = nil
}

/// 换页时颜色跟着变的那几层背景：Core Animation 的渐变层，颜色变化是同一条弹簧、同样在线性颜色里插值
///（SwiftUI 动 Color 也是这样），一帧都不用 SwiftUI 重画
struct ShelfBackdrop: NSViewRepresentable {
    let layers: [ShelfGradient]

    func makeNSView(context: Context) -> ShelfBackdropView {
        let view = ShelfBackdropView()
        view.show(resolved(context), animated: false)
        return view
    }

    func updateNSView(_ view: ShelfBackdropView, context: Context) {
        view.show(resolved(context), animated: context.transaction.animatesShelf)
    }

    private func resolved(_ context: Context) -> [ShelfBackdropView.Layer] {
        layers.map { gradient in
            ShelfBackdropView.Layer(kind: gradient.kind, colors: gradient.colors.map { ShelfColor($0.resolve(in: context.environment)) },
                                    locations: gradient.locations)
        }
    }
}

/// 一个颜色，线性 sRGB（SwiftUI 动画颜色就在这里插值）
struct ShelfColor: Equatable {
    var red: Double, green: Double, blue: Double, opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }
    init(_ resolved: Color.Resolved) {
        self.init(red: Double(resolved.linearRed), green: Double(resolved.linearGreen), blue: Double(resolved.linearBlue),
                  opacity: Double(resolved.opacity))
    }

    func mixed(with other: ShelfColor, _ p: Double) -> ShelfColor {
        ShelfColor(red: red + (other.red - red) * p, green: green + (other.green - green) * p,
                   blue: blue + (other.blue - blue) * p, opacity: opacity + (other.opacity - opacity) * p)
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static func encoded(_ linear: Double) -> Double {
        let magnitude = abs(linear)
        let value = magnitude <= 0.0031308 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return linear < 0 ? -value : value
    }
    /// 普通 sRGB（0…1）的分量：扩展 sRGB 的颜色会让渐变层改用 16 位的图层、在主线程上一点点画出来
    var sRGB: [Double] {
        func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
        return [clamped(Self.encoded(red)), clamped(Self.encoded(green)), clamped(Self.encoded(blue)), clamped(opacity)]
    }
    var cgColor: CGColor { Self.cgColor(sRGB) }
    static func cgColor(_ components: [Double]) -> CGColor { CGColor(colorSpace: space, components: components.map { CGFloat($0) })! }
}

final class ShelfBackdropView: NSView {
    struct Layer: Equatable {
        var kind: ShelfGradient.Kind
        var colors: [ShelfColor]
        var locations: [CGFloat]?
    }

    private var shown: [Layer] = []
    private var sublayers: [CALayer] = []
    /// 每一层正在变的颜色：从哪儿、到哪儿、什么时候开始（换到一半又翻一页时，从现在画到的颜色接着变）
    private var motion: [(from: [ShelfColor], start: CFTimeInterval)?] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ layers: [Layer], animated: Bool) {
        guard layers != shown, let root = layer else { return }
        let rebuild = layers.map(\.kind) != shown.map(\.kind) || layers.map(\.colors.count) != shown.map(\.colors.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rebuild {
            sublayers.forEach { $0.removeFromSuperlayer() }
            sublayers = layers.map { spec in
                switch spec.kind {
                case .solid: return CALayer()
                case .linear: let gradient = CAGradientLayer(); gradient.type = .axial; return gradient
                case .radial: let gradient = CAGradientLayer(); gradient.type = .radial; return gradient
                }
            }
            sublayers.forEach(root.addSublayer)
            motion = Array(repeating: nil, count: layers.count)
        }
        let now = CACurrentMediaTime()
        for (index, spec) in layers.enumerated() {
            let sublayer = sublayers[index]
            let keyPath = spec.kind == .solid ? "backgroundColor" : "colors"
            if animated, !rebuild, spec.colors != shown[index].colors {
                let from = current(index, now: now)
                motion[index] = (from, now)
                Self.animate(sublayer, keyPath: keyPath, from: from, to: spec.colors, locations: spec.locations)
            } else if !animated {
                motion[index] = nil
                sublayer.removeAnimation(forKey: keyPath)
            }
            if let gradient = sublayer as? CAGradientLayer {
                let stops = Self.stops(spec.colors, spec.locations)
                gradient.colors = stops.colors
                gradient.locations = stops.locations
            } else {
                sublayer.backgroundColor = spec.colors.first?.cgColor
            }
        }
        CATransaction.commit()
        shown = layers
        needsLayout = true
    }

    /// 这一层现在画到的颜色
    private func current(_ index: Int, now: CFTimeInterval) -> [ShelfColor] {
        let target = shown[index].colors
        guard let running = motion[index] else { return target }
        let spring = ShelfSpring.page
        let elapsed = now - running.start
        guard elapsed < spring.settlingDuration else { return target }
        let p = spring.progress(elapsed)
        return zip(running.from, target).map { $0.mixed(with: $1, p) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = bounds.size
        // 这一层的坐标原点在左下角；SwiftUI 的 UnitPoint 是从左上角量的
        func flipped(_ point: UnitPoint) -> CGPoint { CGPoint(x: point.x, y: 1 - point.y) }
        for (spec, sublayer) in zip(shown, sublayers) {
            switch spec.kind {
            case .solid:
                sublayer.frame = bounds
            case .linear(let start, let end):
                sublayer.frame = bounds
                // SwiftUI 的等色线和 start→end 在点里垂直；Core Animation 是在 0…1 的方块里（宽高各自拉伸）垂直。
                // 换成在方块里同一个方向、同样快的那个终点：等色线和 SwiftUI 画的一模一样
                let w = max(size.width, 1), h = max(size.height, 1)
                let dx = (end.x - start.x) * w, dy = (end.y - start.y) * h
                let span = dx * dx + dy * dy
                let gx = w * dx / span, gy = h * dy / span   // 在方块里每走 1，SwiftUI 的渐变走多少
                let length = gx * gx + gy * gy
                guard span > 0, length > 0 else { continue }
                (sublayer as? CAGradientLayer)?.startPoint = flipped(start)
                (sublayer as? CAGradientLayer)?.endPoint = flipped(UnitPoint(x: start.x + gx / length, y: start.y + gy / length))
            case .radial(let center, let radius):
                // 圆形渐变：以 center 为中心、边长 2 × radius 的方块里，从正中到四边中点；方块外面是最后一个颜色（透明）
                let middle = CGPoint(x: center.x * size.width, y: (1 - center.y) * size.height)
                sublayer.frame = CGRect(x: middle.x - radius, y: middle.y - radius, width: radius * 2, height: radius * 2)
                (sublayer as? CAGradientLayer)?.startPoint = CGPoint(x: 0.5, y: 0.5)
                (sublayer as? CAGradientLayer)?.endPoint = CGPoint(x: 1, y: 1)
            }
        }
        CATransaction.commit()
    }

    /// 渐变的颜色和位置。SwiftUI 在两个颜色之间是按"预乘透明度"插值的（渐到透明不发灰、半透明的那头不抢颜色），
    /// Core Animation 不是：每两个颜色之间按 SwiftUI 的算法多插几个颜色，画出来一样
    static func stops(_ colors: [ShelfColor], _ locations: [CGFloat]?) -> (colors: [CGColor], locations: [NSNumber]) {
        let at = locations ?? colors.indices.map { colors.count > 1 ? CGFloat($0) / CGFloat(colors.count - 1) : 0 }
        let parts = colors.map(\.sRGB)
        var outColors: [CGColor] = [], outLocations: [NSNumber] = []
        let steps = 6
        for index in parts.indices {
            outColors.append(ShelfColor.cgColor(parts[index].indices.map { component in
                // 完全透明的那一头：颜色取旁边的（透明的点颜色本来就看不见，这样两头之间不会往黑里走）
                if component < 3, parts[index][3] == 0,
                   let neighbour = (parts[..<index].reversed() + parts[(index + 1)...]).first(where: { $0[3] > 0 }) { return neighbour[component] }
                return parts[index][component]
            }))
            outLocations.append(NSNumber(value: Double(at[index])))
            guard index + 1 < parts.count else { break }
            let a = parts[index], b = parts[index + 1]
            for step in 1..<steps {
                let t = Double(step) / Double(steps)
                let alpha = a[3] + (b[3] - a[3]) * t
                let rgb = (0..<3).map { c -> Double in
                    let premultiplied = a[c] * a[3] + (b[c] * b[3] - a[c] * a[3]) * t
                    return alpha > 0 ? min(max(premultiplied / alpha, 0), 1) : (a[3] > 0 ? a[c] : b[c])
                }
                outColors.append(ShelfColor.cgColor(rgb + [alpha]))
                outLocations.append(NSNumber(value: Double(at[index] + (at[index + 1] - at[index]) * CGFloat(t))))
            }
        }
        return (outColors, outLocations)
    }

    /// 颜色沿着换页的弹簧变，在线性颜色里插值（SwiftUI 动画颜色也是这样）：一条关键帧动画，一帧都不经过主线程
    private static func animate(_ layer: CALayer, keyPath: String, from: [ShelfColor], to: [ShelfColor], locations: [CGFloat]?) {
        let spring = ShelfSpring.page
        let duration = spring.settlingDuration
        let steps = 20
        var values: [Any] = []
        values.reserveCapacity(steps + 1)
        for step in 0...steps {
            let p = spring.progress(duration * Double(step) / Double(steps))
            let mixed = zip(from, to).map { $0.mixed(with: $1, p) }
            values.append(keyPath == "backgroundColor" ? mixed[0].cgColor as Any : stops(mixed, locations).colors as Any)
        }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .linear
        layer.add(animation, forKey: keyPath)
    }
}

// MARK: 小点

/// 第几页的那一排小点（现在这一页是长一点的那一段）：画在 Core Animation 的层上，换页时宽度、位置、亮度
/// 跟着同一条弹簧挪过去。点哪一个跳到哪一页，由上面一排看不见的 SwiftUI 方块管
struct ShelfDots: NSViewRepresentable {
    let count: Int
    let current: Int

    static let short: CGFloat = 8, long: CGFloat = 30, gap: CGFloat = 9, height: CGFloat = 8
    static func width(_ index: Int, current: Int) -> CGFloat { index == current ? long : short }
    static func totalWidth(count: Int) -> CGFloat {
        count == 0 ? 0 : long + short * CGFloat(count - 1) + gap * CGFloat(count)
    }

    func makeNSView(context: Context) -> ShelfDotsView {
        let view = ShelfDotsView()
        view.show(count: count, current: current, animated: false)
        return view
    }

    func updateNSView(_ view: ShelfDotsView, context: Context) {
        view.show(count: count, current: current, animated: context.transaction.animatesShelf)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShelfDotsView, context: Context) -> CGSize? {
        CGSize(width: Self.totalWidth(count: count), height: Self.height)
    }
}

final class ShelfDotsView: NSView {
    private var dots: [CALayer] = []
    private var current = -1

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(count: Int, current: Int, animated: Bool) {
        guard let root = layer, count != dots.count || current != self.current else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rebuild = count != dots.count
        if rebuild {
            dots.forEach { $0.removeFromSuperlayer() }
            dots = (0..<count).map { _ in
                let dot = CALayer()
                dot.backgroundColor = .white
                dot.cornerRadius = ShelfDots.height / 2
                root.addSublayer(dot)
                return dot
            }
        }
        var x: CGFloat = 0
        for (index, dot) in dots.enumerated() {
            let width = ShelfDots.width(index, current: current)
            let frame = CGRect(x: x + ShelfDots.gap / 2, y: 0, width: width, height: ShelfDots.height)
            let opacity: Float = index == current ? 0.95 : 0.32
            x += width + ShelfDots.gap
            if animated, !rebuild {
                let shown = dot.presentation() ?? dot
                for (keyPath, from, to) in [("position.x", shown.position.x as Any, frame.midX as Any),
                                            ("bounds.size.width", shown.bounds.width as Any, frame.width as Any),
                                            ("opacity", shown.opacity as Any, opacity as Any)] {
                    let spring = ShelfSpring.page.animation(keyPath)
                    spring.fromValue = from
                    spring.toValue = to
                    dot.add(spring, forKey: keyPath)
                }
            }
            dot.frame = frame
            dot.opacity = opacity
        }
        CATransaction.commit()
        self.current = current
    }
}

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
        spring.duration = spring.settlingDuration
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

    /// 走完（差不到千分之一）要多久
    var settlingDuration: Double { animation("x").settlingDuration }
}

extension Transaction {
    /// 这一次改动带着动画（换页、颜色下好了）：Core Animation 那边也动；没带（取来了新内容、换了应用）就直接换
    var animatesShelf: Bool { animation != nil && !disablesAnimations }
}

// MARK: 滑进滑出的一块

private struct ShelfPageLeavingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 这一块正在被换下去（见 ShelfPage.leaving）
    var shelfPageLeaving: Bool {
        get { self[ShelfPageLeavingKey.self] }
        set { self[ShelfPageLeavingKey.self] = newValue }
    }
}

/// 换下去的那一页在 SwiftUI 里多留的那 0.16 秒：只是让里面知道"在被换下去"，画面上什么都不改（滑走是 Core Animation 的事）
struct ShelfPageLeaving: ViewModifier, Animatable {
    var progress: Double
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View { content.environment(\.shelfPageLeaving, progress < 1) }
}

/// 换页时整块滑进滑出的那一块（封面、书、唱片、左边那一栏字）：画在它自己的一层（一个 NSHostingView）里，
/// 滑动、淡入淡出都是这一层的 Core Animation 动画，里面的东西一帧都不用重算。
/// 新的一页：晚 0.14 秒，从 offset 那边弹簧滑进来、淡进来；换下去的那一页：0.16 秒往反方向滑 0.6 倍、淡掉（easeIn）
struct ShelfPage<Content: View>: NSViewRepresentable {
    /// 往哪边、多远（翻的方向 × 距离）
    let offset: CGFloat
    /// 这一页是换页换出来的（不是整个顶部刚出现时就有的那一页）：滑进来
    let animateIn: Bool
    @ViewBuilder let content: () -> Content

    /// 换下去的那一页：SwiftUI 再留它 0.16 秒（滑走的动画要这么久），这期间它知道自己在被换下去
    static var leaving: AnyTransition {
        .asymmetric(insertion: .identity,
                    removal: .modifier(active: ShelfPageLeaving(progress: 0), identity: ShelfPageLeaving(progress: 1)).animation(.easeIn(duration: 0.16)))
    }

    struct Hosted: View {
        let content: Content
        let environment: EnvironmentValues
        var body: some View { content.environment(\.self, environment).ignoresSafeArea() }
    }

    /// 量大小要用 NSHostingController（NSHostingView 自己不会按给的宽高量）
    final class Coordinator {
        var controller: NSHostingController<Hosted>?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ShelfPageView {
        var environment = context.environment
        environment.shelfPageLeaving = false
        let controller = NSHostingController(rootView: Hosted(content: content(), environment: environment))
        controller.sizingOptions = []          // 大小由外面这一层定（sizeThatFits），不靠 Auto Layout
        controller.safeAreaRegions = []
        context.coordinator.controller = controller
        let view = ShelfPageView(controller.view)
        view.offset = offset
        if animateIn, context.transaction.animatesShelf { view.slideIn() }
        return view
    }

    func updateNSView(_ view: ShelfPageView, context: Context) {
        var environment = context.environment
        environment.shelfPageLeaving = false
        context.coordinator.controller?.rootView = Hosted(content: content(), environment: environment)
        view.offset = offset
        if context.environment.shelfPageLeaving { view.slideOut() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShelfPageView, context: Context) -> CGSize? {
        context.coordinator.controller?.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity, height: proposal.height ?? .infinity))
    }
}

final class ShelfPageView: NSView {
    let hosted: NSView
    var offset: CGFloat = 0
    private var leaving = false

    init(_ hosted: NSView) {
        self.hosted = hosted
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false           // 影子画在框外面
        hosted.clipsToBounds = false
        hosted.autoresizingMask = [.width, .height]
        addSubview(hosted)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        hosted.frame = bounds
    }

    /// 新的一页：晚 0.14 秒，从 offset 那边弹簧滑进来、淡进来（这之前停在那边、看不见）
    func slideIn() {
        guard let layer else { return }
        let start = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.14
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
            layer.add(animation, forKey: "in-" + (animation.keyPath ?? ""))
        }
    }

    /// 换下去：0.16 秒往反方向滑 0.6 倍、淡掉，停在那里（SwiftUI 随后把它拿走）
    func slideOut() {
        guard !leaving, let layer else { return }
        leaving = true
        layer.removeAllAnimations()
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = 0
        move.toValue = -offset * 0.6
        move.isAdditive = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        for animation in [move, fade] {
            animation.duration = 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "out-" + (animation.keyPath ?? ""))
        }
    }

    /// 测试用：在不在滑
    var animationKeys: [String] { layer?.animationKeys() ?? [] }
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
            ShelfBackdropView.Layer(kind: gradient.kind, colors: gradient.colors.map { $0.resolve(in: context.environment) },
                                    locations: gradient.locations)
        }
    }
}

final class ShelfBackdropView: NSView {
    struct Layer: Equatable {
        var kind: ShelfGradient.Kind
        var colors: [Color.Resolved]
        var locations: [CGFloat]?
    }

    private var shown: [Layer] = []
    private var sublayers: [CALayer] = []

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
        }
        for (index, spec) in layers.enumerated() {
            let target = Self.cgColors(spec.colors)
            let sublayer = sublayers[index]
            let keyPath = spec.kind == .solid ? "backgroundColor" : "colors"
            if animated, !rebuild {
                let from = Self.current(sublayer, keyPath: keyPath)
                if from.count == target.count { Self.animate(sublayer, keyPath: keyPath, from: from, to: spec.colors) }
            }
            if let gradient = sublayer as? CAGradientLayer {
                gradient.colors = target
                gradient.locations = spec.locations?.map { NSNumber(value: Double($0)) }
            } else {
                sublayer.backgroundColor = target.first
            }
        }
        CATransaction.commit()
        shown = layers
        needsLayout = true
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
                (sublayer as? CAGradientLayer)?.startPoint = flipped(start)
                (sublayer as? CAGradientLayer)?.endPoint = flipped(end)
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

    /// 透明的那一头（.clear）换成旁边那个颜色的透明版：SwiftUI 渐到透明不会发灰，Core Animation 渐到"透明的黑"会
    private static func cgColors(_ colors: [Color.Resolved]) -> [CGColor] {
        colors.indices.map { index in
            var color = colors[index]
            if color.opacity == 0, let neighbour = (colors[..<index].reversed() + colors[(index + 1)...]).first(where: { $0.opacity > 0 }) {
                color = Color.Resolved(colorSpace: .sRGBLinear, red: neighbour.linearRed, green: neighbour.linearGreen,
                                       blue: neighbour.linearBlue, opacity: 0)
            }
            return color.cgColor
        }
    }

    /// 现在画出来的颜色（换页换到一半又翻一页：从这里接着变）
    private static func current(_ layer: CALayer, keyPath: String) -> [Color.Resolved] {
        let shown = layer.presentation() ?? layer
        let raw: [CGColor]
        if keyPath == "backgroundColor" { raw = shown.backgroundColor.map { [$0] } ?? [] }
        else { raw = ((shown as? CAGradientLayer)?.colors as? [CGColor]) ?? [] }
        return raw.compactMap { cg in NSColor(cgColor: cg).map { Color(nsColor: $0).resolve(in: EnvironmentValues()) } }
    }

    /// 颜色沿着换页的弹簧变，在线性颜色里插值（SwiftUI 动画颜色也是这样）：一条关键帧动画，一帧都不经过主线程
    private static func animate(_ layer: CALayer, keyPath: String, from: [Color.Resolved], to: [Color.Resolved]) {
        let spring = ShelfSpring.page
        let duration = spring.settlingDuration
        let steps = 48
        var values: [Any] = []
        for step in 0...steps {
            let p = spring.progress(duration * Double(step) / Double(steps))
            let colors = zip(from, to).map { a, b in
                Color.Resolved(colorSpace: .sRGBLinear,
                               red: Float(Double(a.linearRed) + (Double(b.linearRed) - Double(a.linearRed)) * p),
                               green: Float(Double(a.linearGreen) + (Double(b.linearGreen) - Double(a.linearGreen)) * p),
                               blue: Float(Double(a.linearBlue) + (Double(b.linearBlue) - Double(a.linearBlue)) * p),
                               opacity: Float(Double(a.opacity) + (Double(b.opacity) - Double(a.opacity)) * p))
            }
            let cg = cgColors(colors)
            values.append(keyPath == "backgroundColor" ? cg[0] as Any : cg as Any)
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

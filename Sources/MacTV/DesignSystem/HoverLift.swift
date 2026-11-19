import SwiftUI

/// 鼠标移上去时轻轻浮起、变亮一点，移开时回去。和键盘移动用同一条焦点曲线，手感一致。
/// 只改它自己的样子，不抢键盘焦点：会滚动的一排里，悬停就移动焦点的话整排会跟着滑，鼠标底下又换成另一张，停不下来。
/// 只在鼠标进出的那一下算一次，平时不占资源。
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.04
    var brighten: Double = 0.06
    @State private var hovering = false
    @ObservedObject private var pointer = PointerActivity.shared

    func body(content: Content) -> some View {
        let shown = hovering && pointer.active
        return content
            .scaleEffect(shown ? scale : 1)
            .brightness(shown ? brighten : 0)
            .animation(Motion.focus, value: pointer.active)
            .onHover { inside in
                withAnimation(Motion.focus) { hovering = inside }
            }
    }
}

/// 鼠标移上去时背后出现一层淡淡的底（列表里的一行用）
struct HoverWash: ViewModifier {
    var radius: CGFloat = 18
    @State private var hovering = false
    @ObservedObject private var pointer = PointerActivity.shared

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white.opacity(hovering && pointer.active ? 0.08 : 0)))
            .animation(Motion.focus, value: pointer.active)
            .onHover { inside in
                withAnimation(Motion.focus) { hovering = inside }
            }
    }
}

/// 鼠标是不是正在用：按键、双指滑动时变成"不在用"，鼠标悬停的效果全部收起（不然键盘焦点移走了，
/// 鼠标底下那一项还亮着，屏幕上就有两个高亮）；鼠标真的动了才回来
@MainActor
final class PointerActivity: ObservableObject {
    static let shared = PointerActivity()
    @Published private(set) var active = true

    func set(_ on: Bool) { if active != on { active = on } }
}

extension View {
    func hoverLift(scale: CGFloat = 1.04, brighten: Double = 0.06) -> some View { modifier(HoverLift(scale: scale, brighten: brighten)) }
    func hoverWash(radius: CGFloat = 18) -> some View { modifier(HoverWash(radius: radius)) }
}

/// 拖进度时的"档位"：每一段至少 5 秒、或者整段的四十分之一（长的那个）。拖过一个档位响一声"嗒"，像拨旋钮
enum ScrubDetent {
    static func size(duration: Double) -> Double { max(5, duration / 40) }
    static func crossed(from before: Double, to after: Double, duration: Double) -> Bool {
        let step = size(duration: duration)
        return Int((before / step).rounded(.down)) != Int((after / step).rounded(.down))
    }
}

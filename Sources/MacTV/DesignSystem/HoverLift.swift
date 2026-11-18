import SwiftUI

/// 鼠标移上去时轻轻浮起、变亮一点，移开时回去。和键盘移动用同一条焦点曲线，手感一致。
/// 只改它自己的样子，不抢键盘焦点：会滚动的一排里，悬停就移动焦点的话整排会跟着滑，鼠标底下又换成另一张，停不下来。
/// 只在鼠标进出的那一下算一次，平时不占资源。
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.04
    var brighten: Double = 0.06
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .brightness(hovering ? brighten : 0)
            .onHover { inside in
                withAnimation(Motion.focus) { hovering = inside }
            }
    }
}

/// 鼠标移上去时背后出现一层淡淡的底（列表里的一行用）
struct HoverWash: ViewModifier {
    var radius: CGFloat = 18
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0)))
            .onHover { inside in
                withAnimation(Motion.focus) { hovering = inside }
            }
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.04, brighten: Double = 0.06) -> some View { modifier(HoverLift(scale: scale, brighten: brighten)) }
    func hoverWash(radius: CGFloat = 18) -> some View { modifier(HoverWash(radius: radius)) }
}

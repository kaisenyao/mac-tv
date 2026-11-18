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

/// 鼠标移到哪，焦点就到哪（和键盘移动是同一个焦点，屏幕上只有一个高亮）。
/// 只有鼠标真的动了才算：焦点一移整排会跟着滑，滑过去的内容碰到静止的鼠标也会触发"移入"，那不算，不然会一直连锁滑下去。
@MainActor
enum PointerFocus {
    private static var last = NSPoint(x: -1, y: -1)

    static func moved() -> Bool {
        let now = NSEvent.mouseLocation
        defer { last = now }
        return now != last
    }
}

extension View {
    /// 鼠标真的移进来时调用 action（用来把焦点挪过来）
    func pointerFocus(_ action: @escaping @MainActor () -> Void) -> some View {
        onHover { inside in
            if inside, PointerFocus.moved() { action() }
        }
    }
}

import SwiftUI
import WebKit

/// 浏览器的网页（见 BrowserStore）：最上面一条标签栏，网页在它下面（不被盖住）。
/// 视频铺满时标签栏收起、网页占满整个屏幕；焦点进标签栏时它盖在视频上面出来（不把视频挤小）。
/// 网页的大小变的那一下不做动画（网页一帧帧地重排很费），只有标签栏自己滑进滑出。
/// 换回一个标签页时，网页画出来之前先铺着它离开时的截图
struct BrowserPageView: View {
    @ObservedObject var store: BrowserStore
    let web: WKWebView
    let failed: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let inset = store.videoMode ? 0 : (BrowserTopBar.height * Self.scale(for: size)).rounded()
            let pageHeight = max(1, size.height - inset)
            ZStack(alignment: .top) {
                Color.black
                WebViewHost(webView: web).id(ObjectIdentifier(web))
                    .frame(width: size.width, height: pageHeight)
                    .padding(.top, inset)
                    .allowsHitTesting(!failed)
                    .accessibilityHidden(failed)
                if let image = store.placeholder {
                    Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: pageHeight, alignment: .top)
                        .clipped()
                        .padding(.top, inset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                TVCanvas { BrowserTopBarLayer(store: store) }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .ignoresSafeArea()
    }

    /// 和 TVCanvas 一样的比例：1920×1080 的画布放到窗口上
    static func scale(for window: CGSize) -> CGFloat {
        let width = max(window.width, 1), height = max(window.height, 1)
        return width / height < 16 / 9 ? width / 1920 : height / 1080
    }
}

/// 标签栏和它下面拉出来的"⋯"菜单（画在 1920×1080 的画布上）
private struct BrowserTopBarLayer: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if store.barShown {
                BrowserTopBar(store: store)
                    .transition(reduceMotion ? .opacity : .offset(y: -(BrowserTopBar.height + 30)).combined(with: .opacity))
            }
            if store.menu != nil {
                BrowserMenu(store: store)
                    .padding(.top, BrowserTopBar.height + 12)
                    .padding(.trailing, 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topTrailing)
        .animation(Motion.slide, value: store.barShown)
        .animation(Motion.appear, value: store.menu != nil)
    }
}

// MARK: 标签栏

/// 像 Safari 的紧凑标签栏，放大到电视上：后退、前进 ｜ 一个个标签 ｜ "+"、"⋯"。按钮和标签一样高，都在栏里上下居中。
/// 正在看的那个标签宽一点、亮一点，它就是地址栏：选中时显示网址，按确认直接改地址、搜索。别的一样宽，标题放不下就截掉。
/// 选中的标签（或者鼠标底下的）网站图标换成 ×，点它关掉这个标签。选中的和 tvOS 一样变白、浮起来一点，
/// 浮起来的大小和影子都留在栏里，不压到旁边的标签、不落到下面的网页上。
/// 标签多了先一起变窄，还放不下就横着滚，选中的那个尽量在中间。无痕标签页是深紫色，整条栏也暗一点，写着 Private。
/// 开始页上也是这一条（开始页自己是最后一个标签）
struct BrowserTopBar: View {
    static let height: CGFloat = 80
    /// 按钮、标签一样高
    static let control: CGFloat = 52
    static let gap: CGFloat = 12
    private static let margin: CGFloat = 32
    private static let groupGap: CGFloat = 20
    static let privateTint = Color(hex: "#5B4BA8")

    @ObservedObject var store: BrowserStore
    /// 跟踪鼠标悬停（开始页上标签栏滑动、收着的时候关掉，见 BrowserStore.startBarSettled）
    var hoverable = true
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let isPrivate = store.barIsPrivate
        let buttons = Self.control * 2 + Self.gap
        let stripWidth = canvas.width - Self.margin * 2 - buttons * 2 - Self.groupGap * 2
        return HStack(spacing: Self.groupGap) {
            HStack(spacing: Self.gap) {
                circle(.back, symbol: "chevron.left", enabled: store.barCanGoBack)
                circle(.forward, symbol: "chevron.right", enabled: store.barCanGoForward)
            }
            strip(width: stripWidth)
            HStack(spacing: Self.gap) {
                circle(.newTab, symbol: "plus", enabled: true)
                circle(.more, symbol: "ellipsis", enabled: true)
            }
        }
        .padding(.horizontal, Self.margin)
        .frame(width: canvas.width, height: Self.height)
        .background {
            ZStack(alignment: .bottom) {
                isPrivate ? Color(hex: "#17141F") : Color(hex: "#1E1F23")
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(Motion.appear, value: isPrivate)
    }

    private func circle(_ item: BrowserStore.BarFocus, symbol: String, enabled: Bool) -> some View {
        BarButton(store: store, item: item, symbol: symbol, enabled: enabled, lit: store.barFocus == item, hoverable: hoverable)
    }

    private func strip(width: CGFloat) -> some View {
        let tabs = store.barTabs
        let currentID = store.barCurrentID
        let widths = Self.tabWidths(count: tabs.count, current: tabs.firstIndex { $0.id == currentID }, available: width)
        let total = widths.reduce(0, +) + Self.gap * CGFloat(max(0, tabs.count - 1))
        // 放不下时横着滚：选中的那个（焦点不在标签上就是正在看的那个）尽量在中间
        var anchorID = currentID
        switch store.barFocus {
        case .tab(let id), .close(let id): anchorID = id
        default: break
        }
        let anchor = tabs.firstIndex { $0.id == anchorID } ?? 0
        let anchorX = widths.prefix(anchor).reduce(0, +) + Self.gap * CGFloat(anchor) + (widths.indices.contains(anchor) ? widths[anchor] / 2 : 0)
        let offset = total <= width ? 0 : min(max(0, anchorX - width / 2), total - width)
        // 选中的标签浮起来会比自己宽一点：遮罩左右多留一点，两头的标签浮起来不被切掉
        let bleed: CGFloat = 8
        return HStack(spacing: Self.gap) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                BrowserTabPill(store: store, tab: tab, width: widths[index], current: tab.id == currentID,
                               lit: store.barFocus == .tab(tab.id), closeLit: store.barFocus == .close(tab.id),
                               startPage: tab.id == BrowserStore.startTabID, hoverable: hoverable)
            }
        }
        .offset(x: -offset)
        .frame(width: width, height: Self.height, alignment: .leading)
        .padding(.horizontal, bleed)
        // 两头被截掉的地方淡出去
        .mask { EdgeFadeMask(leading: offset > 0 ? 48 : 0, trailing: offset < total - width ? 48 : 0) }
        .padding(.horizontal, -bleed)
        .animation(Motion.focus, value: offset)
    }

    /// 标签的宽度（和 Safari 一样占满这一条）：正在看的那个宽一点（放得下网址），别的一样宽；
    /// 别的最宽 480，再多出来的地方都给正在看的那个（只有一个标签时它就是一整条地址栏）。
    /// 标签多了先一起变窄；别的窄到 150、正在看的窄到 420 还放不下，就横着滚
    nonisolated static func tabWidths(count: Int, current: Int?, available: CGFloat, gap: CGFloat = 12) -> [CGFloat] {
        guard count > 0 else { return [] }
        let (currentMin, currentTarget, otherMin, otherMax): (CGFloat, CGFloat, CGFloat, CGFloat) = (420, 720, 150, 480)
        let gaps = gap * CGFloat(count - 1)
        let others = CGFloat(count - (current == nil ? 0 : 1))
        var wide = current == nil ? 0 : min(currentTarget, max(currentMin, available - gaps - others * otherMin))
        let other = others > 0 ? min(otherMax, max(otherMin, (available - gaps - wide) / others)) : 0
        if current != nil { wide = max(wide, available - gaps - other * others) }
        return (0..<count).map { $0 == current ? wide : other }
    }

    /// 标签上显示的网址：网站加路径，不要 https:// 和 www.
    nonisolated static func address(_ url: URL) -> String {
        let host = (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        let path = url.path == "/" ? "" : url.path
        return host + path
    }
}

/// 标签栏两头的圆按钮（后退、前进、"+"、"⋯"）。鼠标停在上面轻轻浮起、变亮一点（和 hoverLift 一样）
private struct BarButton: View {
    let store: BrowserStore
    let item: BrowserStore.BarFocus
    let symbol: String
    let enabled: Bool
    let lit: Bool
    let hoverable: Bool
    @State private var hovering = false

    var body: some View {
        let hovered = hovering && enabled && !lit
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(lit ? .black : .white.opacity(enabled ? 0.9 : 0.25))
            .frame(width: BrowserTopBar.control, height: BrowserTopBar.control)
            .background(Circle().fill(lit ? Color.white : .white.opacity(enabled ? 0.08 : 0.04)))
            .browserLift(focused: lit, in: Circle(), scale: 1.08, shadow: 5)
            .scaleEffect(hovered ? 1.06 : 1)
            .brightness(hovered ? 0.08 : 0)
            .animation(Motion.focus, value: lit)
            .animation(Motion.focus, value: hovered)
            .contentShape(Circle())
            .onTapGesture { if enabled { store.tapBar(item) } }
            .pointerHover($hovering, enabled: hoverable)
    }
}

extension View {
    /// 鼠标（手机触控板的光标）在用时才跟踪悬停。按遥控器时不跟踪：不然标签栏滑进滑出的每一帧，
    /// SwiftUI 都要重算一遍光标底下是谁（实测这一项占了收起、放出标签栏时一半的 CPU）
    fileprivate func pointerHover(_ hovering: Binding<Bool>, enabled: Bool) -> some View {
        modifier(PointerHover(hovering: hovering, enabled: enabled))
    }
}

private struct PointerHover: ViewModifier {
    @Binding var hovering: Bool
    let enabled: Bool
    @ObservedObject private var pointer = PointerActivity.shared

    func body(content: Content) -> some View {
        let tracking = enabled && pointer.active
        Group {
            if tracking { content.onHover { hovering = $0 } } else { content }
        }
        .onChange(of: tracking) { _, tracking in if !tracking { hovering = false } }
    }
}

/// 标签栏上的一个标签：左边网站图标（选中、鼠标在上面时换成 ×），然后标题（正在看的那个被选中时是网址）。
/// 只在焦点、标题、网址变的时候重画；鼠标进出只改它自己
private struct BrowserTabPill: View {
    let store: BrowserStore
    let tab: BrowserTab
    let width: CGFloat
    let current: Bool
    let lit: Bool
    let closeLit: Bool
    let startPage: Bool
    let hoverable: Bool
    @State private var hovering = false

    private static let icon: CGFloat = 32

    var body: some View {
        let focused = lit || closeLit
        let showsClose = focused || hovering
        let shape = Capsule(style: .continuous)
        let fill: Color = focused ? .white
            : tab.isPrivate ? BrowserTopBar.privateTint.opacity(current ? 0.62 : 0.3)
            : .white.opacity(current ? 0.16 : 0.06)
        return HStack(spacing: 12) {
            ZStack {
                siteIcon.opacity(showsClose ? 0 : 1)
                closeButton(focused: focused).opacity(showsClose ? 1 : 0).allowsHitTesting(showsClose)
            }
            .frame(width: Self.icon, height: Self.icon)
            label(focused: focused)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tab.isPrivate { privateMark(focused: focused) }
        }
        .font(.tv(.caption1, emphasized: current))
        .foregroundStyle(focused ? .black : .white.opacity(current ? 1 : 0.62))
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .frame(width: width, height: BrowserTopBar.control)
        .background(shape.fill(fill))
        // 浮起来左右各多 6 点（标签之间留了 12），宽的标签不会放大到压住旁边的
        .browserLift(focused: focused, in: shape, scale: 1 + 12 / max(width, 120), shadow: 5)
        .animation(Motion.focus, value: focused)
        .animation(Motion.focus, value: showsClose)
        .contentShape(shape)
        .onTapGesture { store.tapBar(.tab(tab.id)) }
        .pointerHover($hovering, enabled: hoverable)
    }

    @ViewBuilder
    private var siteIcon: some View {
        if startPage {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 18, weight: .semibold))
        } else {
            SiteTile(page: tab.page, size: Self.icon, corner: 8, minPixels: 16, remember: !tab.isPrivate)
        }
    }

    /// 圆圈里一个 ×：标签选中时淡淡的，× 自己被选中时变成实心的黑圆
    private func closeButton(focused: Bool) -> some View {
        Image(systemName: "xmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(closeLit ? .white : focused ? .black.opacity(0.75) : .white.opacity(0.9))
            .frame(width: Self.icon, height: Self.icon)
            .background(Circle().fill(closeLit ? Color.black : focused ? .black.opacity(0.1) : .white.opacity(0.18)))
            .scaleEffect(closeLit ? 1.12 : 1)
            .contentShape(Circle())
            .onTapGesture { store.tapBar(.close(tab.id)) }
            .accessibilityLabel("Close Tab")
    }

    @ViewBuilder
    private func label(focused: Bool) -> some View {
        if current && focused {
            // 正在看的那个被选中（停在它的 × 上也算，字不跟着跳）：它就是地址栏
            if startPage {
                Text("Search or enter website name").lineLimit(1).opacity(0.55)
            } else {
                Text(BrowserTopBar.address(tab.url)).lineLimit(1).truncationMode(.middle)
            }
        } else {
            Text(startPage ? "Start Page" : tab.page.name).lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func privateMark(focused: Bool) -> some View {
        if current {
            Text("Private")
                .font(.tv(.caption2, emphasized: true))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(focused ? Color.black.opacity(0.08) : .white.opacity(0.18)))
                .fixedSize()
        } else {
            Image(systemName: "hand.raised.fill").font(.system(size: 17, weight: .semibold)).opacity(0.7)
        }
    }
}

// MARK: "⋯"菜单

/// 从"⋯"下面拉出来的菜单（tvOS 菜单的样子：一块圆角板，选中的那一行变白）。缩放的三个按钮在同一行
struct BrowserMenu: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        let isPrivate = store.barIsPrivate
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return VStack(spacing: 6) {
            // 开始页上只有 New Private Tab、Close Tab（见 BrowserStore.menuRows）
            ForEach(store.menuRows, id: \.self) { items in
                if items.count > 1 { zoomRow } else if let item = items.first { row(item) }
            }
        }
        .padding(12)
        .frame(width: 580)
        .background(shape.fill(Color(hex: isPrivate ? "#221D30" : "#2A2B30")))
        .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ item: BrowserStore.MenuItem) -> some View {
        let lit = store.menu == item, shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return HStack(spacing: 20) {
            Image(systemName: item.symbol).font(.system(size: 26, weight: .semibold)).frame(width: 36)
            Text(item.name)
            Spacer(minLength: 0)
        }
        .font(.tv(.callout))
        .foregroundStyle(lit ? .black : .white.opacity(0.9))
        .padding(.horizontal, 24)
        .frame(height: 72)
        .background(shape.fill(lit ? Color.white : .clear))
        .browserLift(focused: lit, in: shape, scale: 1.03, shadow: 12)
        .animation(Motion.focus, value: lit)
        .contentShape(shape)
        .onTapGesture { store.tapMenu(item) }
    }

    private var zoomRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "textformat.size").font(.system(size: 26, weight: .semibold)).frame(width: 36)
            Text("Zoom").padding(.leading, 8)
            Spacer(minLength: 0)
            zoomButton(.zoomOut) { Image(systemName: "minus").font(.system(size: 24, weight: .bold)) }
            zoomButton(.zoomReset, width: 120) { Text(BrowserZoom.percent(store.page.zoom)).monospacedDigit() }
            zoomButton(.zoomIn) { Image(systemName: "plus").font(.system(size: 24, weight: .bold)) }
        }
        .font(.tv(.callout))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 24)
        .frame(height: 72)
    }

    private func zoomButton<Label: View>(_ item: BrowserStore.MenuItem, width: CGFloat = 60,
                                         @ViewBuilder label: () -> Label) -> some View {
        let lit = store.menu == item, shape = Capsule(style: .continuous)
        return label()
            .foregroundStyle(lit ? .black : .white.opacity(0.9))
            .frame(width: width, height: 56)
            .background(shape.fill(lit ? Color.white : .white.opacity(0.1)))
            .browserLift(focused: lit, in: shape, scale: 1.08, shadow: 10)
            .animation(Motion.focus, value: lit)
            .contentShape(shape)
            .onTapGesture { store.tapMenu(item) }
    }
}

extension View {
    /// tvOS 里选中的卡片、按钮：浮起来（放大一点）、底下一片柔和的影子、表面一层斜着的高光。
    /// 都是静态的，只在焦点换的时候过渡一下
    /// 影子只投在那块形状上（垫在后面），不投在里面的每个字、图标上：那样字周围会糊一圈灰
    func browserLift<S: Shape>(focused: Bool, in shape: S, scale: CGFloat = 1.08, shadow: CGFloat = 30) -> some View {
        overlay {
            shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .topLeading, endPoint: .center))
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .background {
            shape.fill(.black)
                .shadow(color: .black.opacity(0.5), radius: shadow, y: shadow * 0.7)
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .scaleEffect(focused ? scale : 1)
    }
}

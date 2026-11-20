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
                TVCanvas { BrowserTopBarLayer(store: store, web: web) }
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
    let web: WKWebView
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if store.barShown {
                BrowserTopBar(store: store, web: web)
                    .transition(reduceMotion ? .opacity : .offset(y: -(BrowserTopBar.height + 30)).combined(with: .opacity))
            }
            if store.menu != nil {
                DimBackdrop(close: { _ = store.closeHoldMenu() })
                    .transition(.opacity)
                BrowserMenu(store: store)
                    .padding(.top, BrowserTopBar.height + 12)
                    .padding(.trailing, 28)
                    .transition(.growing(from: .topTrailing))
            }
            // "⋯"里的 Remove from Favorites：先问
            if store.itemMenu != nil {
                BrowserItemMenuView(store: store).frame(width: canvas.width, height: canvas.height)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topTrailing)
        .animation(Motion.slide, value: store.barShown)
        .animation(Motion.slide, value: store.menu != nil)
        .animation(Motion.appear, value: store.itemMenu != nil)
    }
}

// MARK: 标签栏

/// 像 Safari（macOS 26 起）的标签栏，放大到电视上：后退、前进（有历史才出来）｜ 居中的一条胶囊，裹着标签 ｜ "+"、"⋯"。
/// 只有一个标签时胶囊就是这个标签（720 宽，没有 ×）；标签多了胶囊跟着变长（还是居中），四个左右撑满，再多别的标签变窄。
/// 正在看的那个更宽（560）、显示网站名、描一圈边，页面在加载时底下一条蓝线；别的一样宽，只有图标和标题。
/// 选中的那个和 tvOS 一样变白、浮起来一点；选中的（或者鼠标底下的）标签，网站图标换成 ×（只剩一个时没有）。
/// 选中正在看的那个按确认：它就地变成地址栏（深色、蓝色的框、网址整个选中），后面的胶囊淡掉：框不套在另一个胶囊里。
/// 开新标签它在最后从零宽长出来、关掉它淡掉，旁边的跟着变宽变窄：只是标签栏里几块的位置、大小、透明度的一下动画，
/// 网页和整个画面都不重画。标签多到放不下就横着滚，选中的那个尽量在中间。
/// 无痕标签页是深紫色，整条栏也暗一点。开始页上也是这一条
struct BrowserTopBar: View {
    static let height: CGFloat = 80
    /// 按钮、标签那一条一样高
    static let control: CGFloat = 52
    static let gap: CGFloat = 12
    /// 标签在长胶囊里：上下左右各留 4，标签之间 6
    nonisolated static let inset: CGFloat = 4
    nonisolated static let tabGap: CGFloat = 6
    /// 改地址时地址栏最宽多少（不撑满整条）
    nonisolated static let editWidth: CGFloat = 720
    private static let margin: CGFloat = 32
    private static let groupGap: CGFloat = 16
    static let privateTint = Color(hex: "#5B4BA8")
    /// 标签栏里的变化（开、关、换、改地址）：短短一下，只动标签栏。和焦点的那一下是同一条曲线，标签变宽和它变白一起走
    static let tabMotion = Motion.focus

    @ObservedObject var store: BrowserStore
    /// 网页（开始页上没有）：正在看的那个标签底下的加载进度线跟着它
    var web: WKWebView? = nil
    /// 跟踪鼠标悬停（开始页上标签栏滑动、收着的时候关掉，见 BrowserStore.startBarSettled）
    var hoverable = true
    @Environment(\.canvasSize) private var canvas
    @FocusState private var typing: Bool
    /// 标签栏里没在动（开、关、改地址的那一下动画过去了）：这时才跟踪鼠标悬停。
    /// 标签变宽变窄时还跟踪的话，SwiftUI 每一帧都要重算光标底下是谁（实测用触控板时那一下占到半个核）
    @State private var settled = false

    var body: some View {
        let isPrivate = store.barIsPrivate
        let buttons = Self.control * 2 + Self.gap
        let trackWidth = canvas.width - Self.margin * 2 - buttons * 2 - Self.groupGap * 2
        return HStack(spacing: Self.groupGap) {
            HStack(spacing: Self.gap) {
                circle(.back, symbol: "chevron.left", enabled: store.barCanGoBack)
                circle(.forward, symbol: "chevron.right", enabled: store.barCanGoForward)
            }
            track(width: trackWidth)
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
        .onChange(of: store.focusRequest) { _, _ in if store.editing && store.editingInBar { typing = true } }
    }

    private func circle(_ item: BrowserStore.BarFocus, symbol: String, enabled: Bool) -> some View {
        BarButton(store: store, item: item, symbol: symbol, enabled: enabled, lit: store.barFocus == item,
                  pressed: store.pressed == item, hoverable: hoverable && settled)
    }

    /// 居中的一条胶囊，裹着标签：标签多了跟着变长，撑满了别的标签变窄，再多横着滚。
    /// 只有一个标签、或者在改地址时，胶囊本身不画：一个标签时它就是那个标签，改地址时只剩地址栏的框
    private func track(width: CGFloat) -> some View {
        let tabs = store.barTabs
        let currentID = store.barCurrentID
        let currentIndex = tabs.firstIndex { $0.id == currentID }
        let editingIndex = store.editing && store.editingInBar ? currentIndex : nil
        let lone = tabs.count == 1
        let pad = lone ? 0 : Self.inset
        let inner = width - pad * 2
        let widths = Self.tabWidths(count: tabs.count, current: currentIndex, editing: editingIndex != nil, available: inner, gap: Self.tabGap)
        let total = widths.reduce(0, +) + Self.tabGap * CGFloat(max(0, tabs.count - 1))
        let shown = Self.capsuleWidth(widths: widths, available: width) - pad * 2
        // 放不下时横着滚：选中的那个（焦点不在标签上就是正在看的那个）尽量在中间
        var anchorID = currentID
        switch store.barFocus {
        case .tab(let id), .close(let id): anchorID = id
        default: break
        }
        let anchor = tabs.firstIndex { $0.id == anchorID } ?? 0
        let anchorX = widths.prefix(anchor).reduce(0, +) + Self.tabGap * CGFloat(anchor) + (widths.indices.contains(anchor) ? widths[anchor] / 2 : 0)
        let offset = total <= inner ? 0 : min(max(0, anchorX - inner / 2), total - inner)
        // 标签栏里的东西变了（开、关、换、改地址）就是那一下动画
        let layout = tabs.map(\.id).joined(separator: ",") + "|\(editingIndex ?? -1)|\(currentID ?? "")"
        return HStack(spacing: Self.tabGap) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                // 改地址时还是这一个标签（同一个视图）：它自己从标签的宽度变到地址栏的宽度，字直接换，不叠两层
                BrowserTabPill(store: store, tab: tab, width: widths[index], current: tab.id == currentID,
                               lit: store.barFocus == .tab(tab.id), closeLit: store.barFocus == .close(tab.id),
                               pressed: store.pressed == .tab(tab.id) || store.pressed == .close(tab.id),
                               editing: index == editingIndex, typing: $typing, closable: store.tabsClosable,
                               lone: lone, web: tab.id == currentID ? web : nil, hoverable: hoverable && settled)
                    .frame(width: widths[index])
                    // 新开的从右边滑进来（和旁边让开是同一下），关掉的淡掉（比旁边的撑开快，不叠在一起）
                    .transition(.asymmetric(insertion: .modifier(active: TabGrow(width: widths[index], fraction: 0),
                                                                 identity: TabGrow(width: widths[index], fraction: 1)),
                                            removal: .modifier(active: TabGrow(width: widths[index], fraction: 0),
                                                               identity: TabGrow(width: widths[index], fraction: 1))))
            }
        }
        .offset(x: -offset)
        .frame(width: shown, height: Self.control, alignment: .leading)
        .padding(.horizontal, pad)
        // 两头被截掉的地方淡出去；没截掉的一头遮罩往外多留一点：选中的浮起来（放大、影子）、改地址的框比胶囊高一点，
        // 都不被切掉（只有一个标签时它就是整条胶囊，浮起来两头会出界）
        .mask {
            EdgeFadeMask(leading: offset > 0 ? 48 : 0, trailing: offset < total - inner ? 48 : 0)
                .padding(.vertical, -12)
                .padding(.leading, offset > 0 ? 0 : -Self.maskOutset)
                .padding(.trailing, offset < total - inner ? 0 : -Self.maskOutset)
        }
        .background(Capsule(style: .continuous).fill(.white.opacity(lone || editingIndex != nil ? 0 : 0.06)))
        .frame(width: width, height: Self.control)
        .animation(Self.tabMotion, value: layout)
        .animation(Motion.focus, value: offset)
        // 标签栏里变了：动画那一下不跟踪悬停，过去了再跟踪（一次性的，不是一直在跑的计时）
        .task(id: layout + "|\(Int(offset))") {
            settled = false
            try? await Task.sleep(for: .seconds(0.4))
            if !Task.isCancelled { settled = true }
        }
    }

    /// 标签的宽度（像 macOS 26 起的 Safari）：只有一个是 editWidth（胶囊就是它）；不止一个时正在看的 560、别的 360，
    /// 胶囊裹着它们。放不下时先让正在看的窄到 440，再让别的变窄（窄过 160 只剩图标），最窄 72，再多就横着滚。
    /// 改地址的那个要 editWidth，不让
    nonisolated static let currentWidth: CGFloat = 560
    nonisolated static let currentMinWidth: CGFloat = 440
    nonisolated static let otherWidth: CGFloat = 360
    nonisolated static let otherFloor: CGFloat = 200
    nonisolated static let minWidth: CGFloat = 72

    /// 胶囊多宽（裹着标签，最宽 available）：一个标签时就是它自己（720），不止一个时两头各多 inset
    nonisolated static func capsuleWidth(widths: [CGFloat], available: CGFloat, gap: CGFloat = 6) -> CGFloat {
        guard widths.count > 1 else { return widths.first ?? 0 }
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        return min(total + inset * 2, available)
    }

    /// 选中的标签浮起来放大多少：左右各多 4 点（标签之间留了 6，不压到旁边的）
    nonisolated static func liftScale(width: CGFloat) -> CGFloat { min(1.06, 1 + 8 / max(width, 100)) }
    /// 胶囊两头（没被截掉的那一头）遮罩往外多留的：浮起来多出来的 4 点和影子都在里面
    nonisolated static let maskOutset: CGFloat = 16

    nonisolated static func tabWidths(count: Int, current: Int?, editing: Bool = false, available: CGFloat, gap: CGFloat = 6) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [editWidth] }
        let current = current.flatMap { (0..<count).contains($0) ? $0 : nil }
        let room = available - gap * CGFloat(count - 1)
        let others = CGFloat(current == nil ? count : count - 1)
        var wide: CGFloat = current == nil ? 0 : editing ? editWidth : currentWidth
        var rest = otherWidth
        if wide + others * rest > room {
            if current != nil, !editing { wide = max(currentMinWidth, min(currentWidth, room - others * otherFloor)) }
            rest = max(minWidth, (room - wide) / others)
        }
        return (0..<count).map { $0 == current ? wide : rest }
    }

    /// 标签上显示的网址：网站加路径，不要 https:// 和 www.
    nonisolated static func address(_ url: URL) -> String {
        let host = (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        let path = url.path == "/" ? "" : url.path
        return host + path
    }
}

/// 标签栏两头的圆按钮（后退、前进、"+"、"⋯"）：选中时变白、浮起来；鼠标停在上面亮一点、浮起来一点；
/// 按下去往下一沉再回来（和别处的按钮一样）
private struct BarButton: View {
    let store: BrowserStore
    let item: BrowserStore.BarFocus
    let symbol: String
    let enabled: Bool
    let lit: Bool
    let pressed: Bool
    let hoverable: Bool
    @State private var hovering = false

    var body: some View {
        let hovered = hovering && enabled && !lit
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(lit ? .black : .white.opacity(0.9))
            .frame(width: BrowserTopBar.control, height: BrowserTopBar.control)
            .background(Circle().fill(lit ? Color.white : .white.opacity(hovered ? 0.2 : 0.08)))
            .browserLift(focused: lit, in: Circle(), scale: 1.1, shadow: 5)
            .scaleEffect(pressed ? 0.9 : hovered ? 1.06 : 1)
            // 不能用的（没有历史的后退、前进）不显示，位置留着：胶囊不跟着挪
            .opacity(enabled ? 1 : 0)
            .allowsHitTesting(enabled)
            .animation(Motion.focus, value: lit)
            .animation(Motion.focus, value: hovered)
            .animation(Motion.press, value: pressed)
            .animation(Motion.appear, value: enabled)
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

/// 标签上的小图标：网站自己的，空白标签页是一颗星（和 Safari 的 Start Page 一样）
private struct BarTabIcon: View {
    let tab: BrowserTab
    let size: CGFloat

    var body: some View {
        if tab.isBlank {
            Image(systemName: "star").font(.system(size: size * 0.72, weight: .semibold)).frame(width: size, height: size)
        } else {
            SiteTile(page: tab.page, size: size, corner: size * 0.22, minPixels: 16, remember: !tab.isPrivate)
        }
    }
}

/// 标签的标题：放得下就在正中，放不下就从头开始放（末尾由遮罩淡出去）。标题按自己的宽度画，不截断
private struct TabTitle: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? ideal.width, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let title = subviews.first else { return }
        let ideal = title.sizeThatFits(.unspecified)
        let x = ideal.width <= bounds.width ? bounds.midX - ideal.width / 2 : bounds.minX
        title.place(at: CGPoint(x: x, y: bounds.midY - ideal.height / 2), proposal: ProposedViewSize(ideal))
    }
}

/// 标签栏上的一个标签：网站图标（选中、鼠标在上面时换成 ×）和标题，在标签里居中。
/// 正在看的那个描一圈边、亮一点，标题是网站名（像 Safari）；空白标签页是"Start Page"。
/// 只在焦点、标题、网址变的时候重画；鼠标进出只改它自己
private struct BrowserTabPill: View {
    let store: BrowserStore
    let tab: BrowserTab
    let width: CGFloat
    let current: Bool
    let lit: Bool
    let closeLit: Bool
    let pressed: Bool
    /// 正在这里改地址：变成深色的输入框、蓝色的框（最宽 editWidth，在它那一格里居中），网址整个选中
    let editing: Bool
    let typing: FocusState<Bool>.Binding
    /// 不止一个标签：能关（× 在最前面，换掉网站图标）。只剩一个时没有 ×
    let closable: Bool
    /// 只有这一个标签：它就是那条胶囊（一样高，没有外面那一圈）
    let lone: Bool
    /// 正在看的那个的网页：底下画加载进度
    let web: WKWebView?
    let hoverable: Bool
    @State private var hovering = false

    private static let icon: CGFloat = 26
    /// 窄到放不下标题时只放图标（或 ×），在正中
    private static let narrow: CGFloat = 160

    var body: some View {
        let focused = (lit || closeLit) && !editing
        let showsClose = closable && (focused || (hovering && !editing))
        let shape = Capsule(style: .continuous)
        let fill: Color = editing ? Color(hex: "#2A2B30") : focused ? .white
            : tab.isPrivate ? BrowserTopBar.privateTint.opacity(current ? 0.6 : 0.24)
            : .white.opacity(current ? 0.14 : hovering ? 0.08 : 0)
        let iconOnly = width < Self.narrow
        return ZStack(alignment: .leading) {
            // 标签和地址栏之间直接换字（不淡入淡出，免得两层字叠在一起），框自己变宽
            if editing {
                HStack(spacing: 10) {
                    BarTabIcon(tab: tab, size: Self.icon)
                    addressField
                }
                .transition(.identity)
            } else {
                // 标题在标签正中；放不下时从头开始放、末尾淡出去。标题本身不截断：标签变宽变窄时字不跟着一帧帧地重排、闪
                if !iconOnly {
                    TabTitle {
                        HStack(spacing: 6) {
                            if tab.isPrivate { Image(systemName: "hand.raised.fill").font(.system(size: 16, weight: .semibold)).opacity(0.7) }
                            Text(title).lineLimit(1).fixedSize()
                        }
                    }
                    .padding(.horizontal, Self.icon + 10)   // 两边让出图标那一格，标题在正中
                    .mask { EdgeFadeMask(trailing: 28) }
                    .transition(.identity)
                }
                // 网站图标在最前面；选中、鼠标在上面时（能关的话）换成 ×
                ZStack {
                    BarTabIcon(tab: tab, size: Self.icon).opacity(showsClose ? 0 : 1)
                    closeButton(focused: focused).opacity(showsClose ? 1 : 0).allowsHitTesting(showsClose)
                }
                .frame(width: Self.icon, height: Self.icon)
                .frame(maxWidth: iconOnly ? .infinity : nil)
                .transition(.identity)
            }
        }
        .font(.tv(.caption1))
        .foregroundStyle(focused ? .black : .white.opacity(current || editing ? 1 : 0.66))
        .padding(.horizontal, editing ? 18 : 14)
        .frame(width: editing ? min(width, BrowserTopBar.editWidth) : width,
               height: editing || lone ? BrowserTopBar.control : BrowserTopBar.control - BrowserTopBar.inset * 2)
        .background(shape.fill(fill))
        .overlay { if let web, !focused, !editing { LoadLine(web: web, width: width) } }
        .overlay(PillOutline().strokeBorder(editing ? Color(hex: "#4A8FE7") : .white.opacity(current && !focused ? 0.2 : 0),
                                            lineWidth: editing ? 3 : 1.5))
        // 浮起来左右各多 4 点（标签之间留了 6），不压到旁边的
        .browserLift(focused: focused, in: shape, scale: BrowserTopBar.liftScale(width: width), shadow: 4)
        .scaleEffect(pressed ? 0.94 : 1)
        .animation(Motion.focus, value: focused)
        .animation(Motion.focus, value: showsClose)
        .animation(Motion.press, value: pressed)
        .contentShape(shape)
        .onTapGesture { store.tapBar(.tab(tab.id)) }
        .pointerHover($hovering, enabled: hoverable)
    }

    private var title: String {
        if tab.isBlank { return "Start Page" }
        return current ? tab.page.host : tab.page.name
    }

    /// 地址栏：手机、键盘打的字都进这里（见 BrowserStore.handleEditing、main.swift），回车打开
    private var addressField: some View {
        let text = Binding(get: { store.query }, set: { store.typed($0) })
        return TextField("", text: text, prompt: Text("Search or enter website name").foregroundStyle(.white.opacity(0.45)))
            .textFieldStyle(.plain)
            .foregroundStyle(.white)
            .focused(typing)
            .onSubmit { store.submit() }
            .onAppear {
                typing.wrappedValue = true
                // 网址整个选中：键盘一打字就换掉（手机上打的字也一样，见 BrowserStore.replaceQuery）
                if store.replaceQuery {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                    }
                }
            }
    }

    /// 圆圈里一个 ×：标签选中时淡淡的，× 自己被选中时变成实心的黑圆，鼠标停在上面深一点
    private func closeButton(focused: Bool) -> some View {
        Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(closeLit ? .white : focused ? .black.opacity(0.75) : .white.opacity(0.9))
            .frame(width: Self.icon, height: Self.icon)
            .background(Circle().fill(closeLit ? Color.black : focused ? .black.opacity(0.1) : .white.opacity(0.18)))
            .scaleEffect(closeLit ? 1.15 : 1)
            .contentShape(Circle())
            .onTapGesture { store.tapBar(.close(tab.id)) }
            .accessibilityLabel("Close Tab")
    }
}

/// 新开的标签从它那一格的右边滑进来（像 Safari）：露出来的那一段贴着这一格的右边，从零宽长到整个，
/// 和旁边的让开是同一下动画、同一条曲线，左边那个让到哪儿它就露到哪儿，不叠在一起。
/// 长的时候裁掉多出来的；长完了不裁（选中时浮起来、影子不被切掉）
private struct TabGrow: ViewModifier, Animatable {
    let width: CGFloat
    var fraction: CGFloat
    nonisolated var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: width * fraction, alignment: .leading)
            .mask { Rectangle().padding(fraction < 1 ? 0 : -40) }
            .frame(width: width, alignment: .trailing)
            .opacity(fraction)
    }
}

/// 加载进度（WKWebView 的 estimatedProgress、isLoading）。只有画进度线的那一小块看着它，标签栏别的不跟着重画
@MainActor
private final class PageLoadProgress: ObservableObject {
    @Published private(set) var value: Double = 1
    @Published private(set) var loading = false
    private weak var web: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    func watch(_ web: WKWebView) {
        guard web !== self.web else { return }
        self.web = web
        update(web)
        let changed: @Sendable (WKWebView) -> Void = { [weak self] web in MainActor.assumeIsolated { self?.update(web) } }
        observations = [web.observe(\.estimatedProgress) { web, _ in changed(web) },
                        web.observe(\.isLoading) { web, _ in changed(web) }]
    }

    private func update(_ web: WKWebView) {
        let loading = web.isLoading
        let value = loading ? web.estimatedProgress : 1
        if value != self.value { self.value = value }
        if loading != self.loading { self.loading = loading }
    }
}

/// 正在看的那个标签底下一条细细的蓝线（和地址栏的框一个蓝）：网页在加载时往前走，加载完走满、淡掉
private struct LoadLine: View {
    let web: WKWebView
    let width: CGFloat
    @StateObject private var progress = PageLoadProgress()

    var body: some View {
        Rectangle().fill(Color(hex: "#4A8FE7"))
            .frame(width: width * progress.value, height: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .opacity(progress.loading ? 1 : 0)
            .clipShape(Capsule(style: .continuous))
            .animation(.easeOut(duration: 0.25), value: progress.value)
            .animation(Motion.appear, value: progress.loading)
            .allowsHitTesting(false)
            .onAppear { progress.watch(web) }
            .onChange(of: ObjectIdentifier(web)) { _, _ in progress.watch(web) }
    }
}

extension BrowserTab {
    /// 空白标签页（还没打开网站，Safari 叫它 Start Page）
    var isBlank: Bool { url == BrowserStore.blankURL }
}

/// 网页缩放的三档（WKWebView.pageZoom）：小 150%、中 175%（每个网站的默认）、大 200%
enum BrowserZoomLevel: CaseIterable, Equatable {
    case small, medium, large

    var zoom: Double {
        switch self {
        case .small: 1.5
        case .medium: 1.75
        case .large: 2
        }
    }

    var name: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// 最近的一档（正好在两档中间的算"中"）
    static func nearest(_ zoom: Double) -> BrowserZoomLevel {
        allCases.min { a, b in
            let da = abs(a.zoom - zoom), db = abs(b.zoom - zoom)
            return abs(da - db) < 0.0001 ? a == .medium : da < db
        } ?? .medium
    }

    /// 记下的缩放换成一档：没记过、或者记的是以前的默认值，是"中"；别的取最近的一档
    static func level(stored: Double?, oldDefault: Double) -> BrowserZoomLevel {
        guard let stored, abs(stored - oldDefault) > 0.001 else { return .medium }
        return nearest(stored)
    }
}

// MARK: "⋯"菜单

/// 从"⋯"下面拉出来的菜单（tvOS 菜单的样子：一块圆角板，选中的那一行变白）。
/// 网页缩放是一行"Zoom  ‹ Medium ›"，和设置里的步进行一样：‹ › 只在这一行选中时出来，左右换一档，到头停住
struct BrowserMenu: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        return VStack(spacing: 6) {
            // 开始页上只有 New Private Tab、Close Tab（见 BrowserStore.menuRows）
            ForEach(store.menuRows, id: \.self) { items in
                if let item = items.first { row(item) }
            }
        }
        .padding(12)
        .frame(width: 640)
        .tvPanelSurface(in: shape)
        .tvShadow(.float)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ item: BrowserStore.MenuItem) -> some View {
        let lit = store.menu == item, shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return HStack(spacing: 20) {
            Image(systemName: item.symbol).font(.system(size: 26, weight: .semibold)).frame(width: 36)
            Text(item.name)
            Spacer(minLength: 0)
            if item == .zoom { zoomValue(lit: lit) }
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

    /// "‹ Medium ›"：和设置里的步进行一样的字、一样的换法（名字整段淡入淡出）。‹ › 鼠标也能点
    private func zoomValue(lit: Bool) -> some View {
        let level = store.zoomLevel
        return HStack(spacing: 12) {
            if lit { arrow("chevron.left", step: -1, enabled: BrowserStore.zoomStep(from: level, by: -1) != nil) }
            Text(level.name)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(Motion.press, value: level)
            if lit { arrow("chevron.right", step: 1, enabled: BrowserStore.zoomStep(from: level, by: 1) != nil) }
        }
        .font(.system(size: 22, weight: .semibold))
        .opacity(0.55)
    }

    private func arrow(_ symbol: String, step: Int, enabled: Bool) -> some View {
        Image(systemName: symbol)
            .opacity(enabled ? 1 : 0.35)
            .frame(width: 28, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { store.stepZoom(step) }
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

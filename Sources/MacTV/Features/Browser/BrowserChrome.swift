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

/// 像 Safari 的紧凑标签栏，放大到电视上：后退、前进 ｜ 一个个标签（网站图标、标题；正在看的宽一点、亮一点）｜ "+"、"⋯"。
/// 选中的那一个和 tvOS 一样变白、浮起来。正在看的那个标签被选中时显示网址，按确认改地址、搜索。
/// 标签多了放不下就横着滚，选中的那个尽量在中间。无痕标签页是深紫色，整条栏也暗一点，写着 Private
struct BrowserTopBar: View {
    static let height: CGFloat = 80
    private static let button: CGFloat = 56
    private static let margin: CGFloat = 36
    private static let groupGap: CGFloat = 24
    private static let gap: CGFloat = 12
    private static let currentWidth: CGFloat = 470
    private static let privateTint = Color(hex: "#5B4BA8")

    @ObservedObject var store: BrowserStore
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let isPrivate = store.activeTab?.isPrivate ?? false
        let stripWidth = canvas.width - Self.margin * 2 - (Self.button * 2 + Self.gap) * 2 - Self.groupGap * 2
        return HStack(spacing: Self.groupGap) {
            HStack(spacing: Self.gap) {
                circle(.back, symbol: "chevron.left", enabled: store.page.canGoBack)
                circle(.forward, symbol: "chevron.right", enabled: store.page.canGoForward)
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
        let lit = store.barFocus == item
        return Image(systemName: symbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(lit ? .black : .white.opacity(enabled ? 0.9 : 0.25))
            .frame(width: Self.button, height: Self.button)
            .background(Circle().fill(lit ? Color.white : .white.opacity(0.08)))
            .browserLift(focused: lit, in: Circle(), scale: 1.1, shadow: 10)
            .animation(Motion.focus, value: lit)
            .contentShape(Circle())
            .onTapGesture { if enabled { store.tapBar(item) } }
            .hoverLift(scale: 1.06, brighten: 0.08)
    }

    private func strip(width: CGFloat) -> some View {
        let tabs = store.tabs
        let others = CGFloat(max(1, tabs.count - 1))
        let otherWidth = min(320, max(220, (width - Self.currentWidth - Self.gap * others) / others))
        let widths = tabs.map { $0.id == store.activeID ? Self.currentWidth : otherWidth }
        let total = widths.reduce(0, +) + Self.gap * CGFloat(max(0, tabs.count - 1))
        // 放不下时横着滚：选中的那个（焦点不在标签上就是正在看的那个）尽量在中间
        var anchorID = store.activeID
        if case .tab(let id) = store.barFocus { anchorID = id }
        let anchor = tabs.firstIndex { $0.id == anchorID } ?? 0
        let anchorX = widths.prefix(anchor).reduce(0, +) + Self.gap * CGFloat(anchor) + (widths.indices.contains(anchor) ? widths[anchor] / 2 : 0)
        let offset = total <= width ? 0 : min(max(0, anchorX - width / 2), total - width)
        return HStack(spacing: Self.gap) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                pill(tab, width: widths[index])
            }
        }
        .offset(x: -offset)
        .frame(width: width, height: Self.height, alignment: .leading)
        .mask {
            // 两头被截掉的地方淡出去
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: offset > 0 ? 36 : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: offset < total - width ? 36 : 0)
            }
            .padding(.vertical, -20)
        }
        .animation(Motion.focus, value: offset)
    }

    private func pill(_ tab: BrowserTab, width: CGFloat) -> some View {
        let current = tab.id == store.activeID
        let lit = store.barFocus == .tab(tab.id)
        let shape = Capsule(style: .continuous)
        let fill: Color = lit ? .white
            : tab.isPrivate ? Self.privateTint.opacity(current ? 0.62 : 0.28)
            : .white.opacity(current ? 0.18 : 0.06)
        return HStack(spacing: 12) {
            SiteTile(page: tab.page, size: 32, corner: 8, minPixels: 16, remember: !tab.isPrivate)
            if current && lit {
                // 正在看的那个被选中：显示网址，按确认改地址、搜索
                Text(Self.address(tab.url)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold)).opacity(0.6)
            } else {
                Text(tab.page.name).lineLimit(1)
                Spacer(minLength: 0)
                if tab.isPrivate {
                    if current {
                        Text("Private")
                            .font(.tv(.caption2, emphasized: true))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.18)))
                    } else {
                        Image(systemName: "hand.raised.fill").font(.system(size: 18, weight: .semibold)).opacity(0.7)
                    }
                }
            }
        }
        .font(.tv(.caption1, emphasized: current))
        .foregroundStyle(lit ? .black : .white.opacity(current ? 1 : 0.62))
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .frame(width: width, height: Self.button)
        .background(shape.fill(fill))
        .browserLift(focused: lit, in: shape, scale: 1.05, shadow: 10)
        .animation(Motion.focus, value: lit)
        .contentShape(shape)
        .onTapGesture { store.tapBar(.tab(tab.id)) }
    }

    /// 标签上显示的网址：网站加路径，不要 https:// 和 www.
    nonisolated static func address(_ url: URL) -> String {
        let host = (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        let path = url.path == "/" ? "" : url.path
        return host + path
    }
}

// MARK: "⋯"菜单

/// 从"⋯"下面拉出来的菜单（tvOS 菜单的样子：一块圆角板，选中的那一行变白）。缩放的三个按钮在同一行
struct BrowserMenu: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        let isPrivate = store.activeTab?.isPrivate ?? false
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return VStack(spacing: 6) {
            row(.newPrivateTab)
            row(.reload)
            zoomRow
            row(.closeTab)
            row(.startPage)
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
    func browserLift<S: Shape>(focused: Bool, in shape: S, scale: CGFloat = 1.08, shadow: CGFloat = 30) -> some View {
        overlay {
            shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .topLeading, endPoint: .center))
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: shadow, y: shadow * 0.7)
        .scaleEffect(focused ? scale : 1)
    }
}

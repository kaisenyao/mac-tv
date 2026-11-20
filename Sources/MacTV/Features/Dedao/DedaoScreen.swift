import SwiftUI

/// 得到的页面（见 DedaoStore）。和别的页面一样的规矩：选中的卡片放大一点、加一圈白框，选中的按钮变白；
/// 位置固定（选中的那一排、那一张、那一讲停在同一个地方，内容在底下走），换页顺着方向滑
struct DedaoRoot: View {
    @ObservedObject var store: DedaoStore

    var body: some View {
        TVCanvas { DedaoScreen(store: store) }.ignoresSafeArea()
    }
}

enum DedaoStyle {
    static let accent = Color(hex: "#FF6A00")
    /// 左边留出收起的左边栏那一列（和哔哩哔哩一样）
    static let margin: CGFloat = 176
    /// 列表页没有左边栏
    static let listMargin: CGFloat = 120
    /// 听书的封面是竖的（3:4）
    static let cover = CGSize(width: 216, height: 288)
    static let gap: CGFloat = 40
    /// 一排多高、卡片区从多高开始：选中的那一排停在这里，上面是选中那本书的介绍
    static let rowHeight: CGFloat = 480
    static let rowsTop: CGFloat = 470
    static let listRow: CGFloat = 104
    /// 左边栏展开时，右边整体让开这么多（Apple TV 的做法：内容右移并变暗，而不是被盖住）
    static let sidebarShift: CGFloat = 214
    /// 左边栏一项多高（加上间隔）、最多露出几项（分类多，露不下的跟着高亮滚）
    static let sidebarItem: CGFloat = 66
    static let sidebarStep: CGFloat = 72
    static let sidebarVisible = 11
    /// 左边栏、右边让开时共用的这条带一点弹性的曲线（同哔哩哔哩）
    static let slide = Motion.slide

    @MainActor static var owl: NSImage? { Catalog.services.first { $0.id == DedaoStore.appID }.flatMap(Icons.image(for:)) }
}

struct DedaoScreen: View {
    @ObservedObject var store: DedaoStore
    @Environment(\.canvasSize) private var canvas

    // 换界面（首页、列表、设置、播放界面之间）和网易云一样：旧的先在 0.12 秒里淡出，新的稍后从右边一点淡入。
    // 两层不会半透明地叠在一起
    private static let fadeOut = Animation.easeIn(duration: 0.12)
    private static let fadeIn = Animation.easeOut(duration: 0.28).delay(0.05)
    /// 播放界面收起后，下面那一层整个回来：不再加延迟
    private static let layerIn = Animation.easeOut(duration: 0.25)
    private static let pageSwap = AnyTransition.asymmetric(insertion: .opacity.combined(with: .offset(x: 50)).animation(fadeIn),
                                                           removal: .opacity.animation(fadeOut))
    private static let playerSwap = AnyTransition.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)).animation(fadeIn),
                                                             removal: .opacity.combined(with: .scale(scale: 1.04)).animation(fadeOut))

    /// 首页、分类页露在外面（没进列表、设置）
    private var browseShown: Bool { store.currentPage == nil && !store.settingsOpen }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            switch store.phase {
            case .failed(let text): DedaoFailure(store: store, text: text)
            case .signIn: DedaoSignIn(store: store)
            // 不先放一页"正在打开"：页面马上出来，内容取到一排填一排
            case .loading, .ready:
                ZStack(alignment: .topLeading) {
                    // 首页一直留着（同网易云）：进列表、设置时只是往左退一点淡出，回来时不用重建一整页卡片和背景
                    DedaoBrowse(store: store)
                        .opacity(browseShown ? 1 : 0)
                        .offset(x: browseShown ? 0 : -50)
                        .animation(browseShown ? Self.fadeIn : Self.fadeOut, value: browseShown)
                        .allowsHitTesting(browseShown)
                    if let page = store.currentPage, !store.settingsOpen {
                        DedaoListPage(store: store, page: page)
                            .id(page.item.id)   // 换到另一个列表：旧的整页先出去，新的再进来
                            .transition(Self.pageSwap)
                    }
                    if store.settingsOpen {
                        DedaoSettingsPage(store: store, player: store.player)
                            .transition(Self.pageSwap)
                    }
                }
                // 播放界面出来时，下面这些先淡出；收起时等它淡出了下面才淡入
                .opacity(store.playerOpen ? 0 : 1)
                .animation(store.playerOpen ? Self.fadeOut : Self.layerIn, value: store.playerOpen)
                if store.playerOpen {
                    DedaoPlayerScreen(store: store, player: store.player)
                        .transition(Self.playerSwap)
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        // 菜单那一层：从按的地方（账号、设置那一行、播放界面的"⋯"）长出来（同网易云）
        .overlayPreferenceValue(DedaoAnchors.self) { anchors in
            GeometryReader { proxy in DedaoMenuLayer(store: store, anchors: anchors, proxy: proxy) }
        }
        .background(Color.black)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#211610"), Color(hex: "#0C0A09")], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [DedaoStyle.accent.opacity(0.22), .clear], center: UnitPoint(x: 0.82, y: -0.05),
                           startRadius: 0, endRadius: canvas.width * 0.6)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

/// 两个并排的按钮之一（出错页）：选中的变白
private struct DedaoChoice: View {
    let title: String
    let focused: Bool
    var size: CGFloat = 24

    var body: some View {
        Text(title)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(focused ? .black : .white)
            .padding(.horizontal, size * 1.25).frame(height: size * 2.5)
            .background(Capsule().fill(focused ? Color.white : .white.opacity(0.1)))
            .scaleEffect(focused ? 1.05 : 1)
            .contentShape(Capsule())
            .animation(Motion.focus, value: focused)
    }
}

// MARK: 出错

/// 出错了：重试；登录着的话旁边还有"重新扫码登录"（登录信息坏了、一直进不去时用）
private struct DedaoFailure: View {
    @ObservedObject var store: DedaoStore
    let text: String
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 70)).foregroundStyle(DedaoStyle.accent)
            Text(text).font(.tv(.headline, emphasized: true)).multilineTextAlignment(.center).frame(maxWidth: 1100)
            if store.canRescan {
                HStack(spacing: 20) {
                    DedaoChoice(title: "重试", focused: store.failureChoice == 0, size: 27)
                        .onTapGesture { store.chooseFailure(0) }
                    DedaoChoice(title: "重新扫码登录", focused: store.failureChoice == 1, size: 27)
                        .onTapGesture { store.chooseFailure(1) }
                }
                .padding(.top, 14)
            } else {
                DedaoChoice(title: "重试", focused: true, size: 27)
                    .onTapGesture { store.chooseFailure(0) }
                    .padding(.top, 14)
            }
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
    }
}

// MARK: 登录

private struct DedaoSignIn: View {
    @ObservedObject var store: DedaoStore
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        HStack(spacing: 140) {
            VStack(alignment: .leading, spacing: 30) {
                if let owl = DedaoStyle.owl {
                    Image(nsImage: owl).resizable().frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                Text("登录得到").font(.tv(.title2, emphasized: true))
                Text("用得到 App 或微信扫码登录").font(.tv(.callout))
            }
            .frame(width: 680, alignment: .leading)
            qr
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
    }

    private var qr: some View {
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        return ZStack {
            shape.fill(.white)
            if let data = store.loginCode?.image, let image = NSImage(data: data) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 400, height: 400)
            } else {
                ProgressView().controlSize(.large).tint(.black)
            }
            if store.loginExpired {
                shape.fill(.black.opacity(0.78))
                VStack(spacing: 16) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 54, weight: .semibold))
                    Text("二维码已过期").font(.tv(.callout, emphasized: true))
                    Text("按确认刷新").font(.tv(.caption1)).opacity(0.7)
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: 460, height: 460)
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .animation(Motion.appear, value: store.loginExpired)
        .onTapGesture { if store.loginExpired { store.startSignIn() } }
    }
}

// MARK: 首页、分类页

/// 左边栏（首页和听书的分类）、右上角（正在播放、账号）、上半屏选中那本书的介绍、下半屏一排排封面
private struct DedaoBrowse: View {
    @ObservedObject var store: DedaoStore
    @Environment(\.canvasSize) private var canvas

    private var sidebarOpen: Bool { store.focus == .sidebar }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            Group {
                rows
                    .frame(width: canvas.width, height: canvas.height - DedaoStyle.rowsTop, alignment: .topLeading)
                    .clipped()
                    // 卡片往左滑的途中，越靠近左边那列图标越淡（同哔哩哔哩）；
                    // 右边露出一截的那张封面淡出屏幕（同一个遮罩，见 EdgeFade）
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 84)
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 74)
                            EdgeFadeMask(trailing: EdgeFadeMask.width(screen: canvas.width, inset: DedaoStyle.margin,
                                                                      card: DedaoStyle.cover.width, gap: DedaoStyle.gap))
                        }
                    }
                    .offset(y: DedaoStyle.rowsTop)
                details
            }
            .offset(x: sidebarOpen ? DedaoStyle.sidebarShift : 0)
            .opacity(sidebarOpen ? 0.4 : 1)
            .animation(DedaoStyle.slide, value: sidebarOpen)
            DedaoTopBar(store: store)
            DedaoSidebar(store: store)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    // MARK: 背景：选中那本书的封面，放大、模糊、压暗

    private var backdrop: some View {
        let cover = store.highlighted?.cover
        return ZStack {
            Color(hex: "#120C08")
            if let cover {
                // 背景只是一片颜色：在很小的尺寸上模糊，再放大铺满（直接对全屏大图模糊每一帧都很贵）
                BiliImage(url: cover)
                    .frame(width: 120, height: 160)
                    .clipped()
                    .blur(radius: 8)
                    .scaleEffect(x: canvas.width / 120 * 1.2, y: canvas.height / 160 * 1.2)
                    .frame(width: canvas.width, height: canvas.height)
                    .opacity(0.6)
                    .id(cover)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.6), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .leading, endPoint: .center)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .animation(.easeInOut(duration: 0.5), value: cover)
    }

    // MARK: 上半屏：选中那本书

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = store.highlighted {
                Text(kicker(item)).font(.tv(.caption1, emphasized: true)).foregroundStyle(DedaoStyle.accent)
                Text(item.title)
                    .font(.tv(.title2, emphasized: true))
                    .lineLimit(1)
                    .frame(maxWidth: 1350, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
                HStack(spacing: 26) {
                    if !item.author.isEmpty { Label(item.author, systemImage: "person.fill") }
                    if !item.score.isEmpty { Label("\(item.score) 分", systemImage: "star.fill") }
                    if !item.heat.isEmpty { Label(item.heat, systemImage: "flame.fill") }
                    if item.duration > 0 { Label(minutes(item.duration), systemImage: "clock.fill") }
                }
                .font(.tv(.body))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                if !item.intro.isEmpty {
                    Text(item.intro).font(.tv(.caption1)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                        .frame(maxWidth: 1150, alignment: .leading)
                }
            } else {
                // 这一排还没取到：写这一页是什么
                Text(store.sections.first { $0.id == store.section }?.title ?? "得到")
                    .font(.tv(.title2, emphasized: true))
                    .padding(.top, 44)
            }
        }
        .id(store.highlighted?.id ?? store.section)
        .transition(.opacity)
        .padding(.horizontal, DedaoStyle.margin)
        .padding(.top, 168)
        .frame(width: canvas.width, alignment: .leading)
        .animation(.easeInOut(duration: 0.22), value: store.highlighted?.id)
    }

    /// 书名上面那一行：是什么、听到哪了
    private func kicker(_ item: DedaoAPI.Item) -> String {
        var parts: [String]
        switch item.kind {
        case .book: parts = ["听书"]
        case .collection: parts = ["名家讲书"] + (item.count > 0 ? ["\(item.count) 本"] : [])
        case .course: parts = ["课程"] + (item.count > 0 ? ["\(item.count) 讲"] : [])
        case .folder: parts = ["分组"] + (item.count > 0 ? ["\(item.count) 项"] : [])
        }
        if item.finished { parts.append("已听完") }
        else if item.progress > 0 { parts.append("已听 \(item.progress)%") }
        else if !item.note.isEmpty { parts.append(item.note) }
        return parts.joined(separator: " · ")
    }

    private func minutes(_ seconds: Double) -> String {
        let total = Int((seconds / 60).rounded())
        return total >= 60 ? "\(total / 60) 小时 \(total % 60) 分钟" : "\(max(1, total)) 分钟"
    }

    // MARK: 下半屏：一排排封面

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, index: index)
                    .frame(height: DedaoStyle.rowHeight, alignment: .top)
                    .opacity(index < store.row ? 0 : (index == store.row ? 1 : 0.55))
            }
        }
        .offset(y: -CGFloat(store.row) * DedaoStyle.rowHeight)
        .id(store.section)
        .transition(.opacity)
    }

    private func rowView(_ row: DedaoStore.Row, index: Int) -> some View {
        let focusedColumn = store.column(of: row)
        let active = index == store.row && store.focus == .rows && store.menu == nil
        // 选中的那一张停在第二个位置，前面露出一张，知道左边还有
        let shift = -CGFloat(max(0, focusedColumn - 1)) * (DedaoStyle.cover.width + DedaoStyle.gap)
        let playing = store.player.current?.itemEnid
        return VStack(alignment: .leading, spacing: 24) {
            Text(row.title)
                .font(.tv(.headline, emphasized: true))
                .foregroundStyle(.white.opacity(index == store.row ? 1 : 0.7))
                .padding(.leading, DedaoStyle.margin)
            if row.items.isEmpty {
                placeholder(row, focused: active)
                    .padding(.leading, DedaoStyle.margin)
                    .onTapGesture { store.focusCard(row: index, column: 0); store.handle(.select) }
            } else {
                HStack(alignment: .top, spacing: DedaoStyle.gap) {
                    ForEach(Array(row.items.enumerated()), id: \.element.id) { column, item in
                        // 只画选中附近的卡片，一排上百张也不卡
                        if abs(column - focusedColumn) <= 7 {
                            DedaoCard(item: item, focused: active && column == focusedColumn,
                                      playing: item.kind == .book && item.enid == playing)
                                .hoverLift()
                                .onTapGesture { store.focusCard(row: index, column: column); store.handle(.select) }
                                // 只留选中前面露出的那一张；再往左的淡出去，左边栏旁边不留残影
                                .opacity(column < focusedColumn - 1 ? 0 : 1)
                                .animation(.easeInOut(duration: 0.42), value: focusedColumn)
                        } else {
                            Color.clear.frame(width: DedaoStyle.cover.width, height: 1)
                        }
                    }
                }
                .padding(.leading, DedaoStyle.margin)
                .offset(x: shift)
            }
        }
    }

    /// 一排还没有卡片：正在取（几张空着的卡片，取到了就填上，不转圈）、没取到（按确认再取）、取到了但是空的
    @ViewBuilder
    private func placeholder(_ row: DedaoStore.Row, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if row.state == .loading {
            HStack(spacing: DedaoStyle.gap) {
                ForEach(0..<7, id: \.self) { _ in
                    shape.fill(.white.opacity(0.05))
                        .overlay(shape.strokeBorder(.white.opacity(0.06), lineWidth: 1.5))
                        .frame(width: DedaoStyle.cover.width, height: DedaoStyle.cover.height)
                }
            }
        } else {
            message(row, focused: focused, shape: shape)
        }
    }

    private func message(_ row: DedaoStore.Row, focused: Bool, shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(.white.opacity(0.05))
            switch row.state {
            case .loading:
                EmptyView()
            case .failed:
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 48, weight: .medium))
                    Text("无法载入，按确认重试").font(.tv(.caption1))
                }
                .foregroundStyle(.white.opacity(0.6))
            case .ready:
                Text(row.empty).font(.tv(.caption1)).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
        }
        .frame(width: 640, height: DedaoStyle.cover.height)
        .overlay(shape.strokeBorder(.white.opacity(focused && row.state == .failed ? 0.95 : 0.08), lineWidth: focused && row.state == .failed ? 5 : 1.5))
        .animation(Motion.focus, value: focused)
    }
}

/// 一本书、一套名家讲书、一门课、一个分组：竖的封面，下面书名、听到哪了（没听过是多少人学过）
private struct DedaoCard: View {
    let item: DedaoAPI.Item
    let focused: Bool
    /// 正在放的就是这本
    let playing: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let size = DedaoStyle.cover
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                cover.frame(width: size.width, height: size.height).clipShape(shape)
                HStack(spacing: 8) {
                    if let badge { DedaoTag(text: badge) }
                    Spacer(minLength: 0)
                    if playing { DedaoTag(symbol: "waveform") }
                }
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .top)
                if item.progress > 0 || item.finished {
                    // 听到多少：封面底下一条
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.25))
                        Rectangle().fill(DedaoStyle.accent).frame(width: size.width * CGFloat(item.finished ? 100 : item.progress) / 100)
                    }
                    .frame(height: 7)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(focused ? 0.95 : 0.08), lineWidth: focused ? 5 : 1.5))
            .shadow(color: .black.opacity(focused ? 0.6 : 0.25), radius: focused ? 26 : 10, y: focused ? 18 : 6)
            .scaleEffect(focused ? 1.08 : 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.system(size: 25, weight: .semibold)).lineLimit(2)
                Text(detail).font(.system(size: 21)).opacity(0.55).lineLimit(1)
            }
            .frame(width: size.width, alignment: .leading)
            .offset(y: focused ? 12 : 0)
            .opacity(focused ? 1 : 0.8)
        }
        .zIndex(focused ? 1 : 0)
        .animation(Motion.focus, value: focused)
    }

    @ViewBuilder private var cover: some View {
        if case .folder = item.kind, item.cover == nil {
            ZStack {
                LinearGradient(colors: [DedaoStyle.accent, Color(hex: "#7A2E00")], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "folder.fill").font(.system(size: 80)).foregroundStyle(.white.opacity(0.9))
            }
        } else {
            ZStack {
                Color.white.opacity(0.06)
                BiliImage(url: item.cover)
            }
        }
    }

    private var badge: String? {
        switch item.kind {
        case .course: "课程"
        case .collection: "名家讲书"
        case .folder: "分组"
        case .book: nil
        }
    }

    private var detail: String {
        if item.finished { return "已听完" }
        if item.progress > 0 { return "已听 \(item.progress)%" }
        if !item.note.isEmpty { return item.note }
        if case .folder = item.kind { return item.count > 0 ? "\(item.count) 项" : "分组" }
        if !item.heat.isEmpty { return item.heat }
        if item.kind == .course, item.count > 0 { return "\(item.count) 讲" + (item.author.isEmpty ? "" : " · \(item.author)") }
        return item.author
    }
}

/// 封面左上角的小标签（课程、名家讲书、分组），右上角正在放的那本是一个橙色的声波
private struct DedaoTag: View {
    var text = ""
    var symbol: String?

    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol) } else { Text(text) }
        }
        .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 32)
        .background(Capsule().fill(symbol == nil ? Color.black.opacity(0.55) : DedaoStyle.accent))
    }
}

// MARK: 左边栏

/// 左边栏：靠左。收起时是一列很淡的图标，当前那一项左边一个小白点；在最左边一张卡片上再按左展开成带文字的面板，
/// 白色高亮跟着上下走（同哔哩哔哩）。分类比一屏多：高亮走到中间以后，停在那里，列表在底下滚
private struct DedaoSidebar: View {
    @ObservedObject var store: DedaoStore
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let open = store.focus == .sidebar
        let entries = store.sections
        let current = entries.firstIndex { $0.id == store.sidebarSection } ?? 0
        let visible = min(entries.count, DedaoStyle.sidebarVisible)
        // 露出来的第一项：高亮尽量停在中间
        let first = max(0, min(current - visible / 2, entries.count - visible))
        let step = DedaoStyle.sidebarStep, item = DedaoStyle.sidebarItem
        let window = CGFloat(visible) * step - (step - item)
        // 上面让出右上角那一排，下面留一点边
        let top: CGFloat = 170
        // 当前项的白色高亮：展开时是一整条；收起时缩成当前图标左边的一个小白点
        let bar = RoundedRectangle(cornerRadius: open ? 20 : 5, style: .continuous)
        let barSize = CGSize(width: open ? 292 : 10, height: open ? item : 10)
        let barY = CGFloat(current) * step + (open ? 0 : item / 2 - 5)
        return ZStack(alignment: .topLeading) {
            bar.fill(.white).frame(width: barSize.width, height: barSize.height).offset(y: barY)
            // 字一律同样粗细、同样的颜色，上下走时字本身一点不变（不然每走一格都要淡出淡入一次，走快了字会看不见）；
            // 选中那一项的黑字是同一列字再画一遍、只露出白条底下那一块，跟着白条走
            labels(entries, open: open, dark: false)
            labels(entries, open: open, dark: true)
                .mask(alignment: .topLeading) {
                    bar.frame(width: barSize.width, height: barSize.height).offset(y: barY)
                }
                .opacity(open ? 1 : 0)
                .allowsHitTesting(false)
        }
        .offset(y: -CGFloat(first) * step)
        .frame(width: open ? 292 : 88, height: window, alignment: .topLeading)
        .clipped()
        .mask {
            // 上下还有没露出来的：那一头淡出去
            VStack(spacing: 0) {
                LinearGradient(colors: [first > 0 ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: 44)
                Color.black
                LinearGradient(colors: [.black, first + visible < entries.count ? .clear : .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 44)
            }
        }
        .padding(18)
        .background {
            // 玻璃底板：收起时向左缩并滑出去
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 38, style: .continuous).fill(.black.opacity(0.35))
                RoundedRectangle(cornerRadius: 38, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 38, style: .continuous).strokeBorder(.white.opacity(0.16))
            }
            .shadow(color: .black.opacity(0.5), radius: 40, x: 12)
            .opacity(open ? 1 : 0)
            .scaleEffect(x: open ? 1 : 0.35, y: open ? 1 : 0.96, anchor: .leading)
            .offset(x: open ? 0 : -150)
        }
        .padding(.leading, open ? 30 : 26)
        .frame(height: canvas.height - top - 30, alignment: .center)
        .offset(y: top)
        .animation(DedaoStyle.slide, value: open)
        .animation(DedaoStyle.slide, value: store.sidebarSection)
    }

    /// 一列图标和名字。dark：选中那一条上的黑字（整列画一遍，用白条当遮罩）
    private func labels(_ entries: [DedaoStore.Section], open: Bool, dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: DedaoStyle.sidebarStep - DedaoStyle.sidebarItem) {
            ForEach(entries) { entry in
                // 收起时当前那一项的图标亮一点（换页时才变）；展开时整列一样，当前项靠白条和黑字
                let shade = dark ? Color.black : Color.white.opacity(open ? 0.78 : (entry.id == store.sidebarSection ? 1 : 0.38))
                HStack(spacing: 20) {
                    Image(systemName: entry.symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .frame(width: 44)
                    Text(entry.title)
                        .font(.tv(.callout))
                        .fixedSize()
                        .opacity(open ? 1 : 0)
                        .offset(x: open ? 0 : -36)          // 文字往左收
                        .frame(width: open ? 184 : 0, alignment: .leading)
                        .clipped()
                }
                .foregroundStyle(shade)
                .animation(open ? DedaoStyle.slide : .easeOut(duration: 0.16), value: open)
                .padding(.horizontal, 22)
                .frame(width: open ? 292 : 88, height: DedaoStyle.sidebarItem, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.select(entry.id) }
            }
        }
    }
}

// MARK: 右上角：正在播放、账号

private struct DedaoTopBar: View {
    @ObservedObject var store: DedaoStore
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        HStack(spacing: 20) {
            if let owl = DedaoStyle.owl {
                Image(nsImage: owl).resizable().frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            Text("得到").font(.tv(.title3, emphasized: true))
            // 在分类页：写上是哪个分类（左边栏收起时只有图标）
            if store.section != DedaoStore.Section.home.id, let title = store.sections.first(where: { $0.id == store.section })?.title {
                HStack(spacing: 16) {
                    Image(systemName: "chevron.right").font(.system(size: 26, weight: .semibold)).opacity(0.4)
                    Text(title).font(.tv(.title3)).opacity(0.7)
                }
                .id(title)
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            // 两个胶囊之间留宽一点：选中的放大了也不碰到旁边那个
            HStack(spacing: 30) {
                if store.player.current != nil {
                    DedaoNowPill(player: store.player, focused: focused(.player), moving: !store.playerOpen)
                        .contentShape(Capsule())
                        .hoverLift()
                        .onTapGesture { store.tapTop(.player) }
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }
                account
            }
        }
        .padding(.horizontal, DedaoStyle.margin)
        .padding(.top, 56)
        .frame(width: canvas.width)
        .animation(Motion.focus, value: store.focus)
        .animation(Motion.appear, value: store.player.current?.id)
        .animation(.easeInOut(duration: 0.22), value: store.section)
    }

    private func focused(_ item: DedaoStore.TopItem) -> Bool { store.focus == .top(item) && store.menu == nil }

    private var account: some View {
        let focused = focused(.account)
        // 账号菜单开着时账号还亮着（菜单是它的）
        let lit = focused || store.menu?.anchor == .account
        return HStack(spacing: 14) {
            BiliImage(url: store.user?.avatar)
                .frame(width: 48, height: 48).clipShape(Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(store.user?.name ?? "得到").font(.system(size: 25, weight: .semibold)).lineLimit(1)
                if let membership = store.user?.membership {
                    Text(membership).font(.system(size: 18, weight: .semibold)).foregroundStyle(DedaoStyle.accent)
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 26)
        .frame(height: 64)
        .foregroundStyle(lit ? .black : .white)
        .background(Capsule().fill(lit ? Color.white : .white.opacity(0.12)))
        .scaleEffect(focused ? 1.06 : 1)
        .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 10)
        .contentShape(Capsule())
        .hoverLift()
        .onTapGesture { store.tapTop(.account) }
    }
}

// MARK: 菜单（账号菜单、设置里的一列、播放界面的"⋯"）

/// 菜单从哪长出来：界面上那个东西的位置（播放界面的"⋯"）
struct DedaoAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 菜单那一层（同网易云）：从账号下面、设置的那一行、播放界面的"⋯"长出来，收起时缩回去；点菜单外面任何地方收起。
/// 白色高亮是同一块，在几项之间滑；确认"退出登录"那一项的高亮是红的
private struct DedaoMenuLayer: View {
    @ObservedObject var store: DedaoStore
    let anchors: [String: Anchor<CGRect>]
    let proxy: GeometryProxy

    /// 菜单宽度：同网易云的 360；右边要写值、有"›"的宽一点，字不挤
    static func width(_ menu: DedaoStore.Menu) -> CGFloat {
        menu.items.contains { !$0.detail.isEmpty || $0.chevron || $0.action == .sleepMenu } ? 420 : 360
    }
    private static let danger = Color(hex: "#E5484D")
    private var canvas: CGSize { proxy.size }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if store.menu != nil {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissMenu() }
            }
            if let menu = store.menu {
                let place = placement(menu)
                panel(menu)
                    .offset(x: place.origin.x, y: place.origin.y)
                    .transition(.scale(scale: 0.86, anchor: place.from).combined(with: .opacity))
                    .id(menu.anchor == .account ? "account" : menu.anchor == .setting ? "setting" : "nowPlaying")
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .animation(Motion.slide, value: store.menu != nil)
    }

    /// 一项多高（加上间隔）、一次最多露出几项（"左边栏显示"有十几个分类：高亮走到中间以后，列表在底下滚）
    private static let step: CGFloat = 82
    private static let visible = 10

    /// 菜单多高
    private func height(_ menu: DedaoStore.Menu) -> CGFloat {
        CGFloat(min(menu.items.count, Self.visible)) * Self.step - 8 + 32 + (menu.title == nil ? 0 : 56)
    }

    /// 账号菜单：账号正下方，右边对齐。设置里的一列：那一行下面放得下就在下面，放不下就在上面，
    /// 都放不下（一长列）就在屏幕上下居中；右边和设置那几行对齐。播放界面的"⋯"：它正上方，右边对齐（同网易云）。
    /// from：从哪个点长出来（缩放的中心）
    private func placement(_ menu: DedaoStore.Menu) -> (origin: CGPoint, from: UnitPoint) {
        let size = height(menu)
        switch menu.anchor {
        case .account:
            return (CGPoint(x: canvas.width - DedaoStyle.margin - Self.width(menu), y: 56 + 64 + 18), .topTrailing)
        case .setting:
            let rowTop = DedaoSettingsPage.rowsTop + CGFloat(store.settingIndex) * DedaoSettingsPage.rowHeight
            let below = rowTop + DedaoSettingsPage.rowHeight + 6, above = rowTop - 6 - size
            let y = below + size <= canvas.height - 24 ? below : (above >= 24 ? above : max(24, (canvas.height - size) / 2))
            return (CGPoint(x: DedaoSettingsPage.rowsLeft + DedaoSettingsPage.rowsWidth - Self.width(menu), y: y), .topTrailing)
        case .nowPlaying:
            let rect = anchors["more"].map { proxy[$0] } ?? CGRect(x: canvas.width / 2, y: canvas.height / 2, width: 0, height: 0)
            let x = min(max(24, rect.maxX - Self.width(menu) + 10), canvas.width - Self.width(menu) - 24)
            let y = min(max(24, rect.minY - size - 4), canvas.height - size - 24)
            return (CGPoint(x: x, y: y), .bottomTrailing)
        }
    }

    private func panel(_ menu: DedaoStore.Menu) -> some View {
        let items = menu.items
        let index = min(menu.index, max(0, items.count - 1))
        let danger = items.indices.contains(index) && items[index].danger
        let shown = min(items.count, Self.visible)
        // 露出来的第一项：高亮尽量停在中间
        let first = max(0, min(index - shown / 2, items.count - shown))
        return VStack(alignment: .leading, spacing: 12) {
            if let title = menu.title {
                Text(title)
                    .font(.tv(.callout, emphasized: true))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.horizontal, 22)
                    .frame(width: Self.width(menu) - 32, height: 44, alignment: .leading)
            }
            list(items, index: index, danger: danger, width: Self.width(menu) - 32)
                .offset(y: -CGFloat(first) * Self.step)
                .frame(width: Self.width(menu) - 32, height: CGFloat(shown) * Self.step - 8, alignment: .top)
                .clipped()
                .mask {
                    // 上下还有没露出来的：那一头淡出去
                    VStack(spacing: 0) {
                        LinearGradient(colors: [first > 0 ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: 40)
                        Color.black
                        LinearGradient(colors: [.black, first + shown < items.count ? .clear : .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                    }
                }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.black.opacity(0.35))
            RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.16))
        }
        .shadow(color: .black.opacity(0.55), radius: 30, y: 14)
        .fixedSize()
        .animation(Motion.focus, value: index)
        .animation(Motion.slide, value: items.count)
    }

    /// 一列选项，白色高亮在后面跟着走
    private func list(_ items: [DedaoStore.MenuItem], index: Int, danger: Bool, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Self.step - 74) {
                ForEach(Array(items.enumerated()), id: \.offset) { row, item in
                    let focused = row == index
                    HStack(spacing: 18) {
                        if item.symbol.isEmpty {
                            Color.clear.frame(width: 36, height: 1)   // 没打勾的档位：字照样对齐
                        } else {
                            Image(systemName: item.symbol).font(.system(size: 26, weight: .semibold)).frame(width: 36)
                        }
                        Text(item.title).font(.tv(.callout)).lineLimit(1)
                        Spacer(minLength: 0)
                        // 右边现在的值：倍速写"1.5×"；定时关闭开着时写还剩多久（每秒走一下）或"本讲结束"
                        if item.action == .sleepMenu {
                            DedaoSleepDetail(player: store.player)
                        } else if !item.detail.isEmpty {
                            Text(item.detail).font(.system(size: 24, weight: .medium).monospacedDigit()).opacity(0.55).lineLimit(1)
                        }
                        // 往里还有一层
                        if item.chevron {
                            Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(0.5)
                        }
                    }
                    .foregroundStyle(focused ? (danger ? .white : .black) : .white.opacity(0.8))
                    .padding(.horizontal, 22)
                    .frame(width: width, height: 74)
                    .contentShape(Rectangle())
                    // 一组到这里为止：在和下一行的空隙里画一条细线（不占地方，高亮照样一格一格走）
                    .overlay(alignment: .bottom) {
                        if item.groupEnd {
                            Rectangle().fill(.white.opacity(0.18)).frame(height: 1).padding(.horizontal, 22)
                                .offset(y: (Self.step - 74) / 2)
                        }
                    }
                    .onHover { inside in if inside { store.hoverMenu(row) } }
                    .onTapGesture { store.tapMenu(row) }
                }
        }
        .background(alignment: .top) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(danger ? Self.danger : .white)
                .frame(height: 74)
                .offset(y: CGFloat(index) * Self.step)
        }
    }
}

/// 播放界面"⋯"里"定时关闭"那一行右边：还剩多久（每秒走一下）、"本讲结束"，没开就不写
private struct DedaoSleepDetail: View {
    @ObservedObject var player: DedaoPlayer

    var body: some View {
        if let timer = player.sleep {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(timer.label(at: context.date)).font(.system(size: 24, weight: .medium).monospacedDigit()).opacity(0.55)
            }
        }
    }
}

// MARK: 设置

/// 和网易云的设置页一个样子：左边头像和名字，右边一行行设置（左边名字和一句说明，右边现在的值）。
/// 白色高亮滑到哪一行，哪一行就是黑字（两遍字、用高亮当遮罩，字本身不动）
private struct DedaoSettingsPage: View {
    @ObservedObject var store: DedaoStore
    @ObservedObject var player: DedaoPlayer
    @Environment(\.canvasSize) private var canvas

    static let rowHeight: CGFloat = 116
    static let rowsLeft: CGFloat = DedaoStyle.listMargin + 460 + 100
    static let rowsTop: CGFloat = 238
    static let rowsWidth: CGFloat = 900

    var body: some View {
        let active = store.menu == nil
        let highlightY = CGFloat(store.settingIndex) * Self.rowHeight
        let highlight = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                BiliImage(url: store.user?.avatar)
                    .frame(width: 360, height: 360)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                Text(store.user?.name ?? "得到").font(.tv(.headline, emphasized: true)).lineLimit(1).padding(.top, 30)
                if let membership = store.user?.membership {
                    Text(membership).font(.tv(.callout, emphasized: true)).foregroundStyle(DedaoStyle.accent).padding(.top, 6)
                }
                Text("设置").font(.tv(.body)).opacity(0.6).padding(.top, 8)
            }
            .frame(width: 460, alignment: .leading)
            .padding(.leading, DedaoStyle.listMargin)
            .padding(.top, 190)
            ZStack(alignment: .topLeading) {
                highlight.fill(.white)
                    .frame(height: Self.rowHeight - 8)
                    .offset(y: highlightY + 4)
                    .opacity(active ? 1 : 0.35)
                rows(dark: false)
                rows(dark: true)
                    .mask(alignment: .topLeading) {
                        highlight.frame(height: Self.rowHeight - 8).offset(y: highlightY + 4)
                    }
                    .allowsHitTesting(false)
            }
            .frame(width: Self.rowsWidth, alignment: .topLeading)
            .offset(x: Self.rowsLeft, y: Self.rowsTop)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .animation(Motion.focus, value: store.settingIndex)
        .animation(Motion.focus, value: active)
    }

    private func rows(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(DedaoStore.Setting.allCases.enumerated()), id: \.offset) { index, setting in
                if dark {
                    row(setting, dark: true)
                } else {
                    row(setting, dark: false)
                        .hoverWash()
                        .onTapGesture { store.activateSetting(index) }
                }
            }
        }
    }

    private func row(_ setting: DedaoStore.Setting, dark: Bool) -> some View {
        let (title, value, picks): (String, String, Bool) = switch setting {
        case .speed: ("默认倍速", DedaoStore.speedText(player.speed), true)
        case .autoNext: ("自动播放下一讲", player.autoNext ? "打开" : "关闭", false)
        case .sidebar: ("边栏", store.sidebarSummary, true)
        case .shelf: ("主屏幕顶部", DedaoShelfSource.summary, true)
        }
        return HStack(spacing: 18) {
            Text(title).font(.system(size: 30, weight: .semibold))
            Spacer(minLength: 20)
            Text(value).font(.system(size: 28, weight: .medium)).opacity(0.6)
                .contentTransition(.opacity)
            // 弹出一列选项的行带这个记号；开关那一行也留着它的位置，右边的值对在同一条竖线上
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 20, weight: .semibold))
                .opacity(picks ? 0.45 : 0)
        }
        .foregroundStyle(dark ? .black : .white.opacity(0.9))
        .padding(.horizontal, 30)
        .frame(width: Self.rowsWidth, height: Self.rowHeight)
        .contentShape(Rectangle())
    }
}

/// 右上角的"正在播放"：封面、在放还是停着、书名。选它打开播放界面
private struct DedaoNowPill: View {
    @ObservedObject var player: DedaoPlayer
    let focused: Bool
    /// 看得见（没被播放界面盖住）：竖条才跟着动
    let moving: Bool

    var body: some View {
        HStack(spacing: 14) {
            BiliImage(url: player.current?.cover)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            NeteaseWave(playing: !player.paused, active: moving, size: 22)
                .foregroundStyle(focused ? Color.black : DedaoStyle.accent)
            // 胶囊跟着书名的长短走；太长的截掉（约 16 个字）
            Text(short(player.current?.title ?? "")).lineLimit(1).fixedSize()
        }
        .font(.tv(.caption1))
        .foregroundStyle(focused ? .black : .white.opacity(0.85))
        .padding(.leading, 10).padding(.trailing, 26)
        .frame(height: 64)
        .background(Capsule().fill(focused ? Color.white : .white.opacity(0.12)))
        .scaleEffect(focused ? 1.06 : 1)
        .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 10)
        .animation(Motion.focus, value: focused)
    }

    private func short(_ title: String) -> String {
        title.count > 16 ? String(title.prefix(15)) + "…" : title
    }
}

// MARK: 列表页（一门课的讲、一套名家讲书、一个分组）

private struct DedaoListPage: View {
    @ObservedObject var store: DedaoStore
    let page: DedaoStore.Page
    @Environment(\.canvasSize) private var canvas

    private var item: DedaoAPI.Item { page.item }
    private var focus: Int { store.listFocus[item.id] ?? 0 }
    private let listLeft: CGFloat = 760
    private let listTop: CGFloat = 130
    /// 选中的那一讲停在第几行（上面露出几讲）
    private let anchor = 3

    var body: some View {
        ZStack(alignment: .topLeading) {
            info
                .frame(width: 540, alignment: .topLeading)
                .padding(.leading, DedaoStyle.listMargin)
                .padding(.top, 110)
            list
                .frame(width: canvas.width - listLeft - DedaoStyle.listMargin, height: canvas.height - listTop, alignment: .topLeading)
                .clipped()
                .offset(x: listLeft, y: listTop)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    // MARK: 左边：封面、名字、介绍

    private var info: some View {
        let course = store.courses[item.id]
        let list = store.tracks[item.id] ?? []
        return VStack(alignment: .leading, spacing: 22) {
            BiliImage(url: course?.cover ?? item.cover)
                .frame(width: 330, height: 440)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
            Text(course?.title.isEmpty == false ? course!.title : item.title)
                .font(.system(size: 40, weight: .bold)).lineLimit(3)
            let author = course?.lecturer.isEmpty == false ? course!.lecturer : item.author
            if !author.isEmpty { Text(author).font(.tv(.callout)).opacity(0.7) }
            Text(meta(course: course, list: list)).font(.tv(.caption1, emphasized: true)).foregroundStyle(DedaoStyle.accent)
            let intro = course?.intro.isEmpty == false ? course!.intro : item.intro
            if !intro.isEmpty { Text(intro).font(.tv(.caption2)).opacity(0.55).lineLimit(4) }
        }
    }

    private func meta(course: DedaoAPI.Course?, list: [DedaoAPI.Track]) -> String {
        if case .folder = page { return "\((store.folders[item.id] ?? []).count) 项" }
        let total = max(course?.lectures ?? 0, list.count, item.count)
        let done = list.filter { $0.finished || $0.progress >= 98 }.count
        let unit = item.kind == .course ? "讲" : "本"
        return total > 0 ? "共 \(total) \(unit)" + (done > 0 ? " · 已听完 \(done) \(unit)" : "") : ""
    }

    // MARK: 右边：一列

    @ViewBuilder private var list: some View {
        let count = store.listCount(page)
        if count == 0 {
            Group {
                if store.loadingPages.contains(item.id) {
                    Text("正在载入…")
                } else if store.failedPages.contains(item.id) {
                    Text("无法载入，按确认重试").onTapGesture { store.handle(.select) }
                } else {
                    Text("暂无内容")
                }
            }
            .font(.tv(.callout)).opacity(0.55).padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    if abs(index - focus) <= 12 {
                        rowView(index)
                            .frame(height: DedaoStyle.listRow)
                            .onTapGesture { store.focusListItem(index); store.handle(.select) }
                    } else {
                        Color.clear.frame(height: DedaoStyle.listRow)
                    }
                }
            }
            .padding(.horizontal, 16)
            .offset(y: -CGFloat(max(0, focus - anchor)) * DedaoStyle.listRow)
            .animation(Motion.focus, value: focus)
        }
    }

    @ViewBuilder private func rowView(_ index: Int) -> some View {
        let focused = index == focus
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 26) {
            switch page {
            case .tracks: trackRow(index, focused: focused)
            case .folder: folderRow(index)
            }
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(.white.opacity(focused ? 0.14 : 0)))
        .overlay(shape.strokeBorder(.white.opacity(focused ? 0.95 : 0), lineWidth: 4))
        .scaleEffect(focused ? 1.02 : 1)
        .padding(.vertical, 6)
        .animation(Motion.focus, value: focused)
    }

    @ViewBuilder private func trackRow(_ index: Int, focused: Bool) -> some View {
        let track = (store.tracks[item.id] ?? [])[index]
        let current = store.player.current?.id == track.id
        Group {
            if current {
                Image(systemName: store.player.paused ? "pause.fill" : "waveform")
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(DedaoStyle.accent)
            } else {
                Text("\(index + 1)").font(.system(size: 26, weight: .semibold).monospacedDigit()).opacity(0.45)
            }
        }
        .frame(width: 60)
        VStack(alignment: .leading, spacing: 6) {
            Text(track.title).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                .foregroundStyle(current ? DedaoStyle.accent : .white)
            Text([track.reader, track.duration > 0 ? clockText(track.duration) : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 21)).opacity(0.5).lineLimit(1)
        }
        Spacer(minLength: 0)
        Group {
            if !track.playable {
                Label("无法播放", systemImage: "lock.fill")
            } else if track.finished || track.progress >= 98 {
                Label("已听完", systemImage: "checkmark")
            } else if track.progress > 0 {
                Text("已听 \(Int(track.progress))%")
            }
        }
        .font(.system(size: 21, weight: .semibold)).opacity(0.55)
    }

    @ViewBuilder private func folderRow(_ index: Int) -> some View {
        let entry = (store.folders[item.id] ?? [])[index]
        BiliImage(url: entry.cover)
            .frame(width: 60, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title).font(.system(size: 28, weight: .semibold)).lineLimit(1)
            Text(entry.author).font(.system(size: 21)).opacity(0.5).lineLimit(1)
        }
        Spacer(minLength: 0)
        if entry.progress > 0 {
            Text(entry.finished ? "已听完" : "已听 \(entry.progress)%").font(.system(size: 21, weight: .semibold)).opacity(0.55)
        }
    }
}

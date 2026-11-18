import SwiftUI

struct NeteaseRoot: View {
    @ObservedObject var store: NeteaseStore

    var body: some View {
        TVCanvas { NeteaseScreen(store: store) }.ignoresSafeArea()
    }
}

/// 几个"菜单从这里长出来"的位置：播放界面的"⋯"、头像、选中的卡片、选中的那首歌、歌单页的收藏按钮
struct NeteaseAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 网易云音乐的电视式页面。
///
/// 首页：上半屏是选中那首歌（或歌单）的名字，下半屏是一排排方形封面；最上面一排再按上是顶栏（正在放的歌、搜索、头像）。
/// 歌单页：左边封面和歌单名，右边竖排的歌曲列表。
/// 正在播放：左边封面、歌名和进度，右边跟着唱的歌词；按上选音质，按下看播放列表。
/// 全程只用方向键、确认、返回；能看见的东西也都能用鼠标点。
///
/// 动画只用这几种，和哔哩哔哩那边一致：
/// - 焦点移动（卡片、整排、高亮）：Motion.focus
/// - 面板和页面进出（菜单、音质栏、播放列表、歌单页、播放界面）：slide
/// - 歌词换句（滚动和变亮）：lyric
/// - 换内容（切歌时的歌名、歌词）：swap，旧的先出、新的后入，不重叠
struct NeteaseScreen: View {
    @ObservedObject var store: NeteaseStore
    @Environment(\.canvasSize) private var canvas
    @FocusState private var typing: Bool
    @FocusState private var namingField: Bool
    @Namespace private var qualitySpace
    /// 播放界面已经完全盖住了：下面的首页、歌单页先不画（看不见，不用跟着每次换歌、换句重算）
    @State private var covered = false

    private let menuWidth: CGFloat = 360
    private let margin: CGFloat = 120
    private let cardSize: CGFloat = 300
    private let cardGap: CGFloat = 40
    private let rowHeight: CGFloat = 500
    private let rowsTop: CGFloat = 430
    private let songHeight: CGFloat = 92
    private let pageTop: CGFloat = 190
    /// 歌单页里选中的行尽量停在第 4 行的位置，上面能看到刚过去的几首
    private let pageAnchor = 3

    private static let slide = Animation.spring(response: 0.42, dampingFraction: 0.84)
    private static let lyric = Animation.spring(response: 0.6, dampingFraction: 0.9)
    private static let swap = AnyTransition.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.4).delay(0.12)),
                                                       removal: .opacity.animation(.easeIn(duration: 0.12)))
    private static let danger = Color(hex: "#E5484D")

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            if store.account != nil, !covered {
                Group {
                    rows
                        .frame(width: canvas.width, height: canvas.height - rowsTop, alignment: .topLeading)
                        .clipped()
                        .offset(y: rowsTop)
                    details
                }
                // 进歌单：首页往左退一点并淡出，歌单页从右边进来
                .opacity(store.page == nil ? 1 : 0)
                .offset(x: store.page == nil ? 0 : -50)
                if let page = store.page {
                    playlistPage(page)
                        .transition(.opacity.combined(with: .offset(x: 50)))
                }
                if store.loading, store.rows.isEmpty {
                    ProgressView().controlSize(.large).position(x: canvas.width / 2, y: canvas.height / 2)
                }
            } else if store.checked {
                login
            }
            topBar
            if let song = store.current {
                // 播放界面：淡入的同时从稍大一点缩到正好，像是推到眼前
                nowPlaying(song)
                    .opacity(store.nowPlayingVisible ? 1 : 0)
                    .scaleEffect(store.nowPlayingVisible ? 1 : 1.04)
                    .allowsHitTesting(store.nowPlayingVisible)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .overlayPreferenceValue(NeteaseAnchors.self) { anchors in
            GeometryReader { proxy in menuLayer(anchors, proxy) }
        }
        .animation(Self.slide, value: store.nowPlayingVisible)
        .animation(Self.slide, value: store.page?.list.id)
        .onChange(of: store.nowPlayingVisible) { _, visible in
            if visible {
                // 等播放界面完全淡入（动画大约半秒）以后再收起下面
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    if store.nowPlayingVisible { covered = true }
                }
            } else {
                covered = false
            }
        }
    }

    // MARK: 背景和顶栏

    private var focusedCover: URL? {
        if let page = store.page { return page.list.cover }
        switch store.focused {
        case .song(let song): return song.cover
        case .playlist(let list): return list.cover
        default: return nil
        }
    }

    /// 整屏的柔和底色：选中那一项的封面，小图模糊后放大。换图时新的在旧的上面浮现，不会先空一下
    private var backdrop: some View {
        ZStack {
            Color.black
            FadingImage(url: focusedCover)
                .frame(width: 160, height: 90)
                .blur(radius: 14)
                .scaleEffect(x: canvas.width / 160 * 1.15, y: canvas.height / 90 * 1.15)
                .opacity(0.5)
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    /// 顶上一排，从左到右：字标 …… 正在放的歌、搜索、头像。后三个能被选中（最上面一排再按上），确认才进去。
    private var topBar: some View {
        HStack(spacing: 20) {
            if let mark = NeteaseStore.wordmark {
                Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 46)
            } else {
                Text("网易云音乐").font(.system(size: 44, weight: .medium)).foregroundStyle(.white)
            }
            Spacer()
            if store.account != nil, !store.nowPlayingVisible {
                if let song = store.current {
                    let focused = store.topFocus == .player
                    HStack(spacing: 12) {
                        NeteaseWave(playing: !store.paused, size: 22)
                        Text(song.name).lineLimit(1)
                    }
                    .font(.tv(.caption1))
                    .foregroundStyle(focused ? .black : .white.opacity(0.85))
                    .padding(.horizontal, 24).frame(height: 58)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(focused ? Color.white : Color.white.opacity(0.12), in: Capsule())
                    .scaleEffect(focused ? 1.06 : 1)
                    .contentShape(Capsule())
                    .pointerFocus { store.hoverTop(.player) }
                    .onTapGesture { store.tapTop(.player) }
                }
                if store.page == nil {
                    searchField
                    let focused = store.topFocus == .account
                    BiliImage(url: store.account?.avatar)
                        .frame(width: 58, height: 58)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(focused ? 1 : 0.2), lineWidth: focused ? 4 : 1.5))
                        .scaleEffect(focused ? 1.12 : 1)
                        .contentShape(Circle())
                        .pointerFocus { store.hoverTop(.account) }
                        .onTapGesture { store.tapTop(.account) }
                        .anchorPreference(key: NeteaseAnchors.self, value: .bounds) { ["account": $0] }
                }
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, 58)
        .frame(width: canvas.width)
        .animation(Motion.focus, value: store.topFocus)
    }

    /// 搜索：平时是一个小小的"搜索"，选中它按确认才变成输入框
    private var searchField: some View {
        let focused = store.topFocus == .search && !store.editing
        return HStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .semibold))
            if store.editing {
                TextField("搜索歌曲、歌单", text: $store.query)
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .onSubmit { store.submitSearch() }
                    .onAppear { typing = true }   // 输入框一出现就拿键盘（只靠状态变化去设，有时会落空）
            } else {
                Text(store.query.isEmpty ? "搜索" : store.query).lineLimit(1)
            }
        }
        .font(.tv(.callout))
        .foregroundStyle(store.editing || focused ? .black : .white.opacity(0.85))
        .padding(.horizontal, 24)
        .frame(width: store.editing ? 620 : nil, height: 58, alignment: .leading)
        .background(store.editing || focused ? Color.white : Color.white.opacity(0.12), in: Capsule())
        .scaleEffect(focused ? 1.06 : 1)
        .environment(\.colorScheme, store.editing ? .light : .dark)
        .contentShape(Capsule())
        .pointerFocus { store.hoverTop(.search) }
        .onTapGesture { store.tapTop(.search) }
        .onChange(of: store.editing) { _, editing in typing = editing }
        .onChange(of: store.focusRequest) { _, _ in if store.editing { typing = true } }
        .animation(Self.slide, value: store.editing)
    }

    // MARK: 菜单

    /// 菜单那一层。菜单从被按的地方（"⋯"、头像、卡片、那一行歌）长出来，收起时缩回那里；点菜单外面任何地方收起。
    private func menuLayer(_ anchors: [String: Anchor<CGRect>], _ proxy: GeometryProxy) -> some View {
        ZStack(alignment: .topLeading) {
            if store.menu != nil {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissMenu() }
            }
            if let menu = store.menu {
                let place = menuPlacement(menu, anchors, proxy)
                // 摆好位置以后整块铺满屏幕，再以"从哪儿来"的那个点为中心放大 / 缩小
                menuPanel(menu)
                    .position(x: place.origin.x + place.size.width / 2, y: place.origin.y + place.size.height / 2)
                    .transition(.scale(scale: 0.04, anchor: UnitPoint(x: place.from.x / max(1, proxy.size.width),
                                                                      y: place.from.y / max(1, proxy.size.height)))
                        .combined(with: .opacity))
                    .id(menu.anchor)
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        .animation(Self.slide, value: store.menu != nil)
    }

    private func menuPanel(_ menu: NeteaseStore.Menu) -> some View {
        let items = menu.items
        let index = min(menu.index, max(0, items.count - 1))
        let danger = items.indices.contains(index) && items[index].danger
        return VStack(alignment: .leading, spacing: 12) {
            if let title = menu.title {
                Text(title)
                    .font(.tv(.callout, emphasized: true))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.horizontal, 22)
                    .frame(width: menuWidth - 32, height: 44, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { row, item in
                    let focused = row == index
                    HStack(spacing: 18) {
                        Image(systemName: item.symbol).font(.system(size: 26, weight: .semibold)).frame(width: 36)
                        if store.naming == item.action {
                            TextField("歌单名字", text: $store.newName)
                                .textFieldStyle(.plain)
                                .font(.tv(.callout))
                                .focused($namingField)
                                .onSubmit { store.submitName() }
                                .onAppear {
                                    namingField = true
                                    // 输入框刚出现的那一下有时拿不到键盘，稍等再要一次
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .milliseconds(80))
                                        if store.naming != nil { namingField = true }
                                    }
                                }
                                .environment(\.colorScheme, .light)
                        } else {
                            Text(item.title).font(.tv(.callout, emphasized: focused)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .foregroundStyle(focused ? (danger ? .white : .black) : .white.opacity(0.8))
                    .padding(.horizontal, 22)
                    .frame(width: menuWidth - 32, height: 74)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { store.hoverMenu(row) } }
                    .onTapGesture { store.tapMenu(row) }
                }
            }
            .background(alignment: .top) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(danger ? Self.danger : .white)   // 确认"删除""退出登录""取消收藏"时，高亮是红的
                    .frame(height: 74)
                    .offset(y: CGFloat(index) * 82)
                    .opacity(items.isEmpty ? 0 : 1)
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
        .onChange(of: store.naming) { _, naming in namingField = naming != nil }
        .onChange(of: store.focusRequest) { _, _ in if store.naming != nil { namingField = true } }
        .animation(Motion.focus, value: index)
        .animation(Self.slide, value: items.count)
    }

    /// 菜单摆在哪、从哪个点长出来：贴着它是从哪儿弹出来的，出不了屏幕
    private func menuPlacement(_ menu: NeteaseStore.Menu, _ anchors: [String: Anchor<CGRect>],
                               _ proxy: GeometryProxy) -> (origin: CGPoint, size: CGSize, from: CGPoint) {
        let size = CGSize(width: menuWidth, height: CGFloat(menu.items.count) * 82 + 24 + (menu.title == nil ? 0 : 56))
        let screen = proxy.size
        let key = switch menu.anchor {
        case .nowPlaying: "more"
        case .account: "account"
        case .song: "song"
        case .card: "card"
        case .pageButton: "pageButton"
        }
        let rect = anchors[key].map { proxy[$0] } ?? CGRect(x: screen.width / 2, y: screen.height / 2, width: 0, height: 0)
        var origin = switch menu.anchor {
        case .nowPlaying: CGPoint(x: rect.maxX - size.width + 10, y: rect.minY - size.height - 4)   // "⋯"正上方，右边对齐
        case .account: CGPoint(x: rect.maxX - size.width, y: rect.maxY + 16)                     // 头像正下方，右边对齐
        case .song: CGPoint(x: rect.minX + 70, y: rect.maxY + 4)                                 // 那一行下面
        case .pageButton: CGPoint(x: rect.minX, y: rect.maxY + 16)                               // 按钮下面
        case .card: CGPoint(x: rect.minX + 24, y: rect.minY + 24)                                // 压在卡片左上角里面
        }
        origin.x = min(max(24, origin.x), screen.width - size.width - 24)
        origin.y = min(max(24, origin.y), screen.height - size.height - 24)
        return (origin, size, CGPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: 登录

    private var login: some View {
        VStack(spacing: 36) {
            ZStack {
                if let image = store.loginImage {
                    Image(nsImage: image).resizable().interpolation(.none).frame(width: 360, height: 360)
                } else {
                    ProgressView().controlSize(.large).colorScheme(.light)
                }
            }
            .frame(width: 420, height: 420)
            .background(.white, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            Text(store.loginScanned ? "请在手机上确认" : (store.loginSlow && store.loginImage == nil ? "按确认打开官方登录页" : "用网易云音乐 App 扫码登录"))
                .font(.tv(.headline, emphasized: true))
                .foregroundStyle(.white)
        }
        .fixedSize()
        .position(x: canvas.width / 2, y: canvas.height / 2)
    }

    // MARK: 首页

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch store.focused {
            case .song(let song):
                Text(song.name).font(.tv(.title2, emphasized: true)).foregroundStyle(.white).lineLimit(2)
                Text(song.artist).font(.tv(.body)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            case .playlist(let list):
                Text(list.name).font(.tv(.title2, emphasized: true)).foregroundStyle(.white).lineLimit(2)
                if let second = secondLine(list) { Text(second).font(.tv(.body)).foregroundStyle(.white.opacity(0.72)).lineLimit(1) }
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: 1250, alignment: .leading)
        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        .padding(.leading, margin)
        .padding(.top, 220)
        .animation(.easeInOut(duration: 0.22), value: store.focused)
    }

    /// 卡片和上半屏的第二行：歌手写"歌手"，专辑写歌手名和歌数，歌单写歌数
    private func secondLine(_ list: NeteasePlaylist) -> String? {
        switch list.kind {
        case .artist: "歌手"
        case .album: [list.subtitle, list.count > 0 ? "\(list.count) 首" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .playlist: list.count > 0 ? "\(list.count) 首" : nil
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, index: index)
                    .frame(height: rowHeight, alignment: .top)
                    .opacity(index < store.row ? 0 : (index == store.row ? 1 : 0.55))
            }
        }
        .offset(y: -CGFloat(store.row) * rowHeight)
        .id(store.results != nil)
        .transition(.opacity)
    }

    private func rowView(_ row: NeteaseStore.Row, index: Int) -> some View {
        let focusedColumn = store.column(of: row)
        let active = index == store.row && !store.editing && store.topFocus == nil
        let shift = -CGFloat(max(0, focusedColumn - 1)) * (cardSize + cardGap)
        return VStack(alignment: .leading, spacing: 26) {
            Text(row.title)
                .font(.tv(.headline, emphasized: true))
                .foregroundStyle(.white.opacity(index == store.row ? 1 : 0.7))
                .padding(.leading, margin)
            HStack(alignment: .top, spacing: cardGap) {
                ForEach(Array(row.items.enumerated()), id: \.offset) { column, item in
                    // 只画焦点附近的卡片，一排几十张也不卡
                    if abs(column - focusedColumn) <= 8 {
                        // 滑出左边的那张淡掉：和整排滑动是同一个动画里一起发生的，步调一致
                        card(item, focused: active && column == focusedColumn)
                            .pointerFocus { store.hoverCard(row: index, column: column) }
                            .onTapGesture { store.focus(row: index, column: column); store.activate() }
                            .opacity(column < focusedColumn - 1 ? 0 : 1)
                    } else {
                        Color.clear.frame(width: cardSize, height: 1)
                    }
                }
            }
            .padding(.leading, margin)
            .offset(x: shift)
        }
    }

    @ViewBuilder
    private func card(_ item: NeteaseStore.Item, focused: Bool) -> some View {
        // 歌手是圆的（和哔哩哔哩的 UP 主一样），其余是圆角方块
        let round = if case .playlist(let list) = item, list.kind == .artist { true } else { false }
        let shape = RoundedRectangle(cornerRadius: round ? cardSize / 2 : 20, style: .continuous)
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Color.white.opacity(0.06)
                switch item {
                case .song(let song):
                    BiliImage(url: song.cover)
                    if store.current == song {
                        Color.black.opacity(0.45)
                        NeteaseWave(playing: !store.paused, active: !store.nowPlayingVisible, size: 64).foregroundStyle(.white)
                    }
                case .playlist(let list):
                    BiliImage(url: list.cover)
                }
            }
            .frame(width: cardSize, height: cardSize)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 5 : 1.5))
            .shadow(color: .black.opacity(focused ? 0.65 : 0), radius: 30, y: 22)
            .scaleEffect(focused ? 1.09 : 1)
            .anchorPreference(key: NeteaseAnchors.self, value: .bounds) { focused ? ["card": $0] : [:] }

            VStack(alignment: .leading, spacing: 6) {
                switch item {
                case .song(let song):
                    Text(song.name).font(.system(size: 27, weight: focused ? .semibold : .medium)).foregroundStyle(.white.opacity(focused ? 1 : 0.78)).lineLimit(1)
                    Text(song.artist).font(.tv(.caption2)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                case .playlist(let list):
                    Text(list.name).font(.system(size: 27, weight: focused ? .semibold : .medium)).foregroundStyle(.white.opacity(focused ? 1 : 0.78)).lineLimit(1)
                    if let second = secondLine(list) { Text(second).font(.tv(.caption2)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                }
            }
            .frame(width: cardSize, alignment: .leading)
            .offset(y: focused ? 12 : 0)
        }
        .zIndex(focused ? 1 : 0)
        .animation(Motion.focus, value: focused)
    }

    // MARK: 歌单页

    /// 左边封面、歌单名和几个按钮（播放、随机播放、收藏），右边竖排的歌。
    /// 选中的那一行是一块白色高亮，换行时它滑过去；几百首的歌单也只排看得见的那三十来行。
    private func playlistPage(_ page: NeteaseStore.Page) -> some View {
        let shift = -CGFloat(max(0, page.index - pageAnchor)) * songHeight
        let listActive = page.button == nil && store.topFocus == nil
        let lo = max(0, page.index - 16), hi = min(page.songs.count, page.index + 16)
        return HStack(alignment: .top, spacing: 100) {
            VStack(alignment: .leading, spacing: 0) {
                BiliImage(url: page.list.cover)
                    .frame(width: 400, height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: page.list.kind == .artist ? 200 : 22, style: .continuous))   // 歌手是圆的
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                Text(page.list.name).font(.tv(.headline, emphasized: true)).foregroundStyle(.white).lineLimit(2).padding(.top, 30)
                Text(pageSubtitle(page)).font(.tv(.body)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).padding(.top, 8)
                // 一横排圆形图标；选中哪个，哪个拉长、把字显示出来
                HStack(spacing: 14) {
                    ForEach(Array(store.pageButtons.enumerated()), id: \.offset) { index, button in
                        pageButton(button, list: page.list, focused: page.button == index && store.topFocus == nil)
                            .pointerFocus { store.hoverPageButton(index) }
                            .onTapGesture { store.pressPageButton(index) }
                    }
                }
                .padding(.top, 30)
            }
            .frame(width: 460, alignment: .leading)
            .padding(.top, pageTop)

            let highlightY = CGFloat(page.index) * songHeight + 4
            let showHighlight = listActive && !page.songs.isEmpty
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white)
                    .frame(height: songHeight - 8)
                    .offset(y: highlightY)
                    .opacity(showHighlight ? 1 : 0)
                    .anchorPreference(key: NeteaseAnchors.self, value: .bounds) { showHighlight ? ["song": $0] : [:] }
                songRows(page, lo, hi, dark: false)
                // 同一份列表再画一遍黑字，只在白色高亮那一块露出来：高亮滑到哪，黑字就在哪，
                // 连按时也不会出现白底白字、暗底黑字一闪而过
                songRows(page, lo, hi, dark: true)
                    .mask(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .frame(height: songHeight - 8)
                            .offset(y: highlightY)
                    }
                    .opacity(showHighlight ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .padding(.top, 44)   // 给顶上的淡出留出位置：第一首歌选中时，白色高亮不会被淡掉一截
            .offset(y: shift)
            .frame(width: canvas.width - margin * 2 - 560, height: canvas.height - pageTop + 44, alignment: .topLeading)
            .clipped()
            // 上下两头渐渐淡出
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                       .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .padding(.top, pageTop - 44)
        }
        .padding(.horizontal, margin)
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .animation(Motion.focus, value: page.button)
    }

    /// 歌单页左边名字下面那一行
    private func pageSubtitle(_ page: NeteaseStore.Page) -> String {
        let count = page.songs.isEmpty ? page.list.count : page.songs.count
        switch page.list.kind {
        case .artist: return page.list.subtitle.isEmpty ? "歌手" : page.list.subtitle
        case .album: return [page.list.subtitle, count > 0 ? "\(count) 首" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .playlist: return count > 0 ? "\(count) 首" : " "
        }
    }

    private func pageButton(_ button: NeteaseStore.PageButton, list: NeteasePlaylist, focused: Bool) -> some View {
        let on = store.subscribed(list)
        let (symbol, title): (String, String) = switch button {
        case .play: ("play.fill", "播放")
        case .shuffle: ("shuffle", "随机播放")
        case .subscribe: (on ? "star.fill" : "star", on ? "已收藏" : "收藏")
        }
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).frame(width: 28)
            if focused {
                Text(title).font(.tv(.callout, emphasized: true)).fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
        .foregroundStyle(focused ? .black : .white.opacity(0.9))
        .padding(.horizontal, focused ? 26 : 0)
        .frame(minWidth: 68)
        .frame(height: 68)
        .background(focused ? Color.white : Color.white.opacity(0.14), in: Capsule())
        .contentShape(Capsule())
        .anchorPreference(key: NeteaseAnchors.self, value: .bounds) { button == .subscribe ? ["pageButton": $0] : [:] }
        .animation(Motion.focus, value: focused)
    }

    /// 歌单里看得见的那几十行。dark = 高亮那一层用的黑字版本
    private func songRows(_ page: NeteaseStore.Page, _ lo: Int, _ hi: Int, dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lo..<hi, id: \.self) { index in
                if dark {
                    songRow(page.songs[index], number: index + 1, dark: true)
                } else {
                    songRow(page.songs[index], number: index + 1, dark: false)
                        .pointerFocus { store.hoverSong(index) }
                        .onTapGesture { store.tapSong(index) }
                }
            }
        }
        .padding(.top, CGFloat(lo) * songHeight)
    }

    private func songRow(_ song: NeteaseSong, number: Int, dark: Bool) -> some View {
        let current = store.current == song
        return HStack(spacing: 24) {
            ZStack {
                if current {
                    NeteaseWave(playing: !store.paused, active: !store.nowPlayingVisible, size: 26)   // 正在放的这一首：波形跟着动，暂停时停住
                } else {
                    Text("\(number)").font(.system(size: 25, weight: .medium).monospacedDigit()).opacity(0.5)
                }
            }
            .frame(width: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.name).font(.system(size: 30, weight: .semibold)).lineLimit(1)
                Text(song.artist).font(.system(size: 23, weight: .regular)).opacity(0.6).lineLimit(1)
            }
            Spacer(minLength: 20)
            if store.liked.contains(song.id) { Image(systemName: "heart.fill").font(.system(size: 20)).opacity(0.5) }
            if song.duration > 0 {
                Text(neteaseClockText(Double(song.duration))).font(.system(size: 25, weight: .medium).monospacedDigit()).opacity(0.55)
            }
        }
        .foregroundStyle(dark ? .black : .white.opacity(current ? 1 : 0.85))
        .padding(.horizontal, 22)
        .frame(height: songHeight - 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: 正在播放

    /// 左边封面、歌名和进度，右边跟着唱的歌词。没有按钮：左右切歌，确认暂停，上选音质，下看播放列表，返回回列表。
    private func nowPlaying(_ song: NeteaseSong) -> some View {
        ZStack {
            Color.black
            // 背景和封面：切歌时新图到手后在旧图上浮现，不会先空一下，也不会两张叠着
            FadingImage(url: song.cover)
                .frame(width: 160, height: 90)
                .blur(radius: 12)
                .scaleEffect(x: canvas.width / 160 * 1.2, y: canvas.height / 90 * 1.2)
                .opacity(0.8)
            Color.black.opacity(0.32)
            HStack(alignment: .center, spacing: 130) {
                VStack(alignment: .leading, spacing: 0) {
                    FadingImage(url: song.cover)
                        .frame(width: 600, height: 600)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.55), radius: 50, y: 30)
                        // 暂停：封面轻轻缩小，正中间浮出一个暂停图标（和哔哩哔哩播放器暂停时同一种）
                        .overlay {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 68, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 168, height: 168)
                                .background(.ultraThinMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                                .scaleEffect(store.paused ? 1 : 0.7)
                                .opacity(store.paused ? 1 : 0)
                        }
                        .scaleEffect(store.paused ? 0.9 : 1)
                        .animation(Self.slide, value: store.paused)
                        .contentShape(Rectangle())
                        .hoverLift(scale: 1.015, brighten: 0.03)
                        .onTapGesture { store.tapPlayPause() }
                    HStack(alignment: .center, spacing: 16) {
                        // 切歌：旧歌名先淡出，新歌名随后淡入（不同时出现，不会重影）
                        ZStack(alignment: .leading) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(song.name).font(.tv(.headline, emphasized: true)).foregroundStyle(.white).lineLimit(1)
                                    .hoverLift(scale: 1.02, brighten: 0.15)
                                    .onTapGesture { store.openAlbum(of: song) }
                                artistLine(song)
                            }
                            .id(song.id)
                            .transition(Self.swap)
                        }
                        .animation(.easeInOut(duration: 0.3), value: song.id)
                        Spacer(minLength: 0)
                        // "⋯"：长按确认（或点它）展开——喜欢、收藏到歌单、查看歌手、查看专辑、播放模式
                        Image(systemName: "ellipsis")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white.opacity(store.menu?.anchor == .nowPlaying ? 1 : 0.7))
                            .frame(width: 58, height: 58)
                            .contentShape(Rectangle())
                            .hoverLift(scale: 1.15, brighten: 0.2)
                            .onTapGesture { store.tapMore() }
                            .anchorPreference(key: NeteaseAnchors.self, value: .bounds) { ["more": $0] }
                    }
                    .padding(.top, 36)
                    NeteaseProgress(store: store, clock: store.clock)
                        .padding(.top, 20)
                }
                .frame(width: 600, alignment: .leading)
                // 没有歌词的歌（纯音乐等）不留歌词那一栏，封面这一栏自己居中
                // 歌词那一栏一直占着位置：没有歌词时它淡出，整块往右平移半格，封面这一栏正好居中。
                // 只是平移和淡入淡出（显卡直接搬），不重新排版，封面的大阴影不用一帧帧重画
                lyricsColumn
                    .frame(width: 800, height: 820, alignment: .leading)
                    .opacity(store.lyricsShown ? 1 : 0)
            }
            .offset(x: store.lyricsShown ? 0 : (800 + 130) / 2)
            // 音质栏、播放列表开着时，上面这些退到后面：轻微模糊、变暗
            .blur(radius: store.queueVisible ? 22 : 0)
            .opacity(store.queueVisible ? 0.75 : 1)
            .animation(Self.slide, value: store.queueVisible)
            if store.qualityVisible || store.queueVisible {
                // 点空白处：收起音质栏 / 播放列表
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissPanels() }
            }
            qualityBar
            queueRow
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    /// 当前的播放列表：按下从屏幕下方滑上来的一排封面，左右挑，确认（或点）就放那一首。和哔哩哔哩的相关视频是同一种做法。
    private var queueRow: some View {
        let open = store.queueVisible
        let size: CGFloat = 230, gap: CGFloat = 34
        let focus = store.queueFocus
        let shift = -CGFloat(max(0, focus - 1)) * (size + gap)
        let lo = max(0, focus - 3), hi = min(store.queue.count, focus + 10)
        return VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 22) {
                Text("播放列表").font(.tv(.headline, emphasized: true)).foregroundStyle(.white).padding(.leading, margin)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(lo..<hi, id: \.self) { index in
                        let song = store.queue[index]
                        let focused = index == focus
                        VStack(alignment: .leading, spacing: 12) {
                            ZStack {
                                BiliImage(url: song.cover)
                                if index == store.queueIndex {
                                    Color.black.opacity(0.45)
                                    NeteaseWave(playing: !store.paused, active: store.queueVisible, size: 50).foregroundStyle(.white)
                                }
                            }
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 5 : 1.5))
                            .scaleEffect(focused ? 1.08 : 1)
                            Text(song.name).font(.system(size: 25, weight: focused ? .semibold : .medium))
                                .foregroundStyle(.white.opacity(focused ? 1 : 0.75)).lineLimit(1)
                                .offset(y: focused ? 10 : 0)
                            Text(song.artist).font(.system(size: 21)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                .offset(y: focused ? 10 : 0)
                        }
                        .frame(width: size, alignment: .leading)
                        .opacity(index < focus - 1 ? 0 : 1)
                        .contentShape(Rectangle())
                        .pointerFocus { store.hoverQueue(index) }
                        .onTapGesture { store.tapQueue(index) }
                    }
                }
                .padding(.leading, margin + CGFloat(lo) * (size + gap))
                .offset(x: shift)
            }
            .padding(.top, 70)
            .padding(.bottom, 54)
            .frame(width: canvas.width, alignment: .leading)
            .background {
                // 后面已经模糊了，这里只需要淡淡一层暗色托住文字
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.3), location: 0.2),
                                       .init(color: .black.opacity(0.45), location: 0.45), .init(color: .black.opacity(0.55), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -400)   // 往屏幕外多铺一段：滑上来回弹时底下不露缝
            }
        }
        .offset(y: open ? 0 : 520)
        .opacity(open ? 1 : 0)
        .allowsHitTesting(open)
        .animation(Self.slide, value: open)
    }

    /// 音质：从屏幕上方滑下来的一行，白色高亮左右滑。和哔哩哔哩的清晰度是同一种做法。
    private var qualityBar: some View {
        let open = store.qualityVisible
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("音质").font(.tv(.callout, emphasized: true)).foregroundStyle(.white.opacity(0.75))
                // 一条竖线把"这一栏叫什么"和"能选的档位"分开
                Capsule().fill(.white.opacity(0.35)).frame(width: 3, height: 36).padding(.horizontal, 22)
                ForEach(Array(store.offered.enumerated()), id: \.offset) { index, quality in
                    let focused = index == store.qualityIndex
                    Text(quality.name)
                        .font(.tv(.callout, emphasized: focused))
                        .foregroundStyle(focused ? .black : .white.opacity(quality.level == store.actualLevel ? 1 : 0.7))
                        .padding(.horizontal, 28)
                        .frame(height: 64)
                        .background {
                            if focused { Capsule().fill(.white).matchedGeometryEffect(id: "quality", in: qualitySpace) }
                        }
                        .contentShape(Capsule())
                        .onHover { inside in if inside { store.hoverQuality(index) } }
                        .onTapGesture { store.tapQuality(index) }
                }
            }
            .padding(.top, 54)
            .padding(.bottom, 54)
            .frame(width: canvas.width)
            .background {
                LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .padding(.top, -400)   // 往屏幕外多铺一段：滑下来回弹时顶上不露缝
            }
            Spacer()
        }
        .offset(y: open ? 0 : -260)
        .opacity(open ? 1 : 0)
        .allowsHitTesting(open)
        .animation(Self.slide, value: open)
        .animation(Motion.focus, value: store.qualityIndex)
    }

    /// 歌词那一栏。切歌时旧歌词先淡出，新歌词载入后再淡入，两份不会同时出现
    private var lyricsColumn: some View {
        ZStack(alignment: .topLeading) {
            if !store.lyrics.isEmpty {
                lyricsContent.id(store.lyricsSong).transition(Self.swap)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.lyricsSong)
    }

    /// 正在唱的那句又大又亮、停在中间，前后的句子越远越淡；换句时滚动和变亮用同一条曲线。点哪句跳到哪句。
    private var lyricsContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 34) {
                    Color.clear.frame(height: 360)
                    ForEach(Array(store.lyrics.enumerated()), id: \.offset) { index, line in
                        let current = index == store.lyricIndex
                        let distance = abs(index - max(0, store.lyricIndex))
                        Group {
                            // 只有正在唱、又有逐字时间的那一句跟着播放进度刷新；其余的句子是静的
                            if current, !line.words.isEmpty {
                                NeteaseKaraokeLine(line: line, playing: !store.paused && store.nowPlayingVisible, time: store.playbackTime)
                            } else {
                                Text(line.text).foregroundStyle(.white)
                            }
                        }
                        .font(.system(size: 50, weight: .bold))
                        .opacity(current ? 1 : max(0.1, 0.38 - Double(distance) * 0.06))
                        .scaleEffect(current ? 1 : 0.94, anchor: .leading)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { store.seek(toTime: line.time) }
                        .id(index)
                    }
                    Color.clear.frame(height: 360)
                }
                .animation(Self.lyric, value: store.lyricIndex)
            }
            .scrollDisabled(true)
            .onChange(of: store.lyricIndex) { _, index in
                withAnimation(Self.lyric) { proxy.scrollTo(max(0, index), anchor: .center) }
            }
            .onChange(of: store.nowPlayingVisible) { _, _ in proxy.scrollTo(max(0, store.lyricIndex), anchor: .center) }
            .onAppear { proxy.scrollTo(max(0, store.lyricIndex), anchor: .center) }
        }
        // 上下两头渐渐淡出
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22),
                                   .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// 歌手名：每位都能点，点了去他的歌手页
    @ViewBuilder private func artistLine(_ song: NeteaseSong) -> some View {
        if song.artists.isEmpty {
            Text(song.artist).font(.tv(.body)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(song.artists.prefix(4).enumerated()), id: \.offset) { index, artist in
                    if index > 0 { Text(" / ") }
                    Text(artist.name).hoverLift(scale: 1.02, brighten: 0.25).onTapGesture { store.openArtist(artist) }
                }
            }
            .font(.tv(.body))
            .foregroundStyle(.white.opacity(0.65))
            .lineLimit(1)
            .frame(maxWidth: 520, alignment: .leading)
            .clipped()
        }
    }
}

/// 进度条和两头的时间。只有它（和正在唱的那句歌词）跟着播放时间刷新，整个页面不用跟着重画。
/// 点进度条上哪儿就跳到哪儿；点的范围比细细一条大一些。
struct NeteaseProgress: View {
    @ObservedObject var store: NeteaseStore
    @ObservedObject var clock: NeteaseClock
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    // 每一帧直接问播放器放到哪了（播放界面关着、暂停时不算）
                    TimelineView(.animation(minimumInterval: nil, paused: store.paused || !store.nowPlayingVisible)) { _ in
                        let fraction = clock.duration > 0 ? min(1, max(0, store.playbackTime() / clock.duration)) : 0
                        Capsule().fill(.white).frame(width: geo.size.width * fraction)
                    }
                }
                // 鼠标移上去、拖的时候变粗一点：提示能拖
                .frame(height: store.scrubbing || hovering ? 12 : 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // 按住拖：声音先停，进度条和歌词跟着走，松手跳过去接着放；点一下就是跳到那里
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        store.beginScrub()
                        store.scrub(to: Double(value.location.x / max(1, geo.size.width)) * clock.duration)
                    }
                    .onEnded { _ in store.endScrub() })
                .onHover { inside in withAnimation(Motion.focus) { hovering = inside } }
                .animation(Motion.focus, value: store.scrubbing)
            }
            .frame(height: 36)
            HStack {
                Text(neteaseClockText(clock.time))
                Spacer()
                // 中间：一直是这首歌实际在放的音质（暂停图标在封面上）
                Text(NeteaseStore.name(of: store.actualLevel))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: store.actualLevel)
                Spacer()
                Text("-" + neteaseClockText(max(0, clock.duration - clock.time)))
            }
            .font(.system(size: 24, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// 正在唱的那一句（有逐字时间时）：唱到哪个字，哪个字在它该唱的那一小段时间里慢慢亮起来。
/// 按屏幕刷新率逐帧算（暂停时停住），亮起来的过程两头缓、中间快，看着是"晕开"而不是"跳亮"。
struct NeteaseKaraokeLine: View {
    let line: NeteaseLyricLine
    let playing: Bool
    /// 现在放到哪了：每一帧直接问播放器，和声音严丝合缝
    let time: () -> Double

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !playing)) { _ in
            let now = time()
            line.words.reduce(Text("")) { text, word in
                let span = max(0.3, min(word.duration, 0.9))
                let linear = max(0, min(1, (now + 0.05 - word.time) / span))
                let eased = linear * linear * (3 - 2 * linear)
                return text + Text(word.text).foregroundColor(.white.opacity(0.42 + 0.58 * eased))
            }
        }
    }
}

func neteaseClockText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// 正在播放的标记：在放的时候是几根上下起伏的竖条（像声波），暂停时是一个暂停图标。
/// active = 现在看得见：被盖住、收起来的时候竖条停住不动，不白白每秒算二十次
struct NeteaseWave: View {
    let playing: Bool
    var active = true
    var size: CGFloat = 24

    var body: some View {
        if playing, !active {
            HStack(alignment: .center, spacing: size * 0.09) {
                ForEach(0..<5, id: \.self) { bar in
                    Capsule().frame(width: size * 0.11, height: size * [0.5, 0.8, 0.6, 0.9, 0.55][bar])
                }
            }
            .frame(width: size, height: size)
        } else if playing {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: size * 0.09) {
                    ForEach(0..<5, id: \.self) { bar in
                        // 每根竖条用两个不同快慢的波叠起来，各自错开一点，看着像在跟着音乐动
                        let phase = Double(bar) * 1.3
                        let level = 0.55 + 0.3 * sin(t * 5.2 + phase) + 0.15 * sin(t * 8.7 + phase * 2.1)
                        Capsule().frame(width: size * 0.11, height: size * max(0.18, min(1, level)))
                    }
                }
                .frame(width: size, height: size)
            }
        } else {
            Image(systemName: "pause.fill").font(.system(size: size * 0.82, weight: .semibold)).frame(width: size, height: size)
        }
    }
}

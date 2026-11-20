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

    private static let slide = Motion.slide
    private static let lyric = Animation.spring(response: 0.6, dampingFraction: 0.9)
    private static let swap = AnyTransition.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.4).delay(0.12)),
                                                       removal: .opacity.animation(.easeIn(duration: 0.12)))
    /// 换界面（首页、歌单页、设置页、播放界面之间）：旧的先在 0.12 秒里淡出，新的稍后淡入。
    /// 两层不会半透明地叠在一起——叠着就会看到上一页的人的残影
    private static let fadeOut = Animation.easeIn(duration: 0.12)
    /// 新的稍晚一点点开始淡入：旧的淡出、新的淡入几乎首尾相接——中间不会空着暗一下，也不会两层叠在一起
    private static let fadeIn = Animation.easeOut(duration: 0.28).delay(0.05)
    /// 播放界面收起后，下面那一层整个回来：不再加延迟（里面的页面自己已经有一点延迟了，两个叠在一起中间会空着暗一下）
    private static let layerIn = Animation.easeOut(duration: 0.25)
    private static let pageSwap = AnyTransition.asymmetric(insertion: .opacity.combined(with: .offset(x: 50)).animation(fadeIn),
                                                           removal: .opacity.animation(fadeOut))
    private var homeShown: Bool { store.page == nil && !store.settingsOpen }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            if store.account != nil, !covered {
              ZStack(alignment: .topLeading) {
                Group {
                    rows
                        .frame(width: canvas.width, height: canvas.height - rowsTop, alignment: .topLeading)
                        .clipped()
                        // 右边露出一截的那张卡片淡出屏幕（见 EdgeFade）
                        .edgeFade(trailing: true, width: EdgeFadeMask.width(screen: canvas.width, inset: margin, card: cardSize, gap: cardGap))
                        .offset(y: rowsTop)
                    details
                }
                // 进歌单、设置：首页先往左退一点淡出，新的一页随后从右边进来（不叠在一起）
                .opacity(homeShown ? 1 : 0)
                .offset(x: homeShown ? 0 : -50)
                .animation(homeShown ? Self.fadeIn : Self.fadeOut, value: homeShown)
                if let page = store.page {
                    playlistPage(page)
                        .id("\(page.list.kind)-\(page.list.id)")   // 换到另一个歌单 / 歌手：旧的整页先出去，新的再进来
                        .transition(Self.pageSwap)
                }
                if store.settingsOpen {
                    settingsPage
                        .transition(Self.pageSwap)
                }
                if store.loading, store.rows.isEmpty {
                    ProgressView().controlSize(.large).position(x: canvas.width / 2, y: canvas.height / 2)
                }
              }
              // 播放界面出来时，下面这些先淡出；播放界面收起时，等它淡出了下面才淡入——两层不叠在一起
              .opacity(store.nowPlayingVisible ? 0 : 1)
              .animation(store.nowPlayingVisible ? Self.fadeOut : Self.layerIn, value: store.nowPlayingVisible)
              .transition(.opacity.animation(Self.layerIn))
            } else if store.checked {
                login
            }
            topBar
            if let song = store.current {
                // 播放界面：淡入的同时从稍大一点缩到正好，像是推到眼前
                nowPlaying(song)
                    .opacity(store.nowPlayingVisible ? 1 : 0)
                    .scaleEffect(store.nowPlayingVisible ? 1 : 1.04)
                    .animation(store.nowPlayingVisible ? Self.fadeIn : Self.fadeOut, value: store.nowPlayingVisible)
                    .allowsHitTesting(store.nowPlayingVisible)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .overlayPreferenceValue(NeteaseAnchors.self) { anchors in
            GeometryReader { proxy in menuLayer(anchors, proxy) }
        }
        .animation(Self.slide, value: store.nowPlayingVisible)
        .animation(Self.slide, value: store.page?.list.id)
        .animation(Self.slide, value: store.settingsOpen)
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

    /// 整屏背景用哪张图：歌单页 / 歌手页 / 专辑页用它自己的封面，设置页用头像，
    /// 首页用这一排选中的那张（焦点在顶栏、在输入框里时也是它，背景不会变空，也不会留着别的页的图）
    private var focusedCover: URL? {
        if let page = store.page { return page.list.cover }
        if store.settingsOpen { return store.account?.largeAvatar ?? store.account?.avatar }
        let rows = store.rows
        guard rows.indices.contains(store.row) else { return nil }
        let line = rows[store.row]
        let column = store.column(of: line)
        guard line.items.indices.contains(column) else { return nil }
        switch line.items[column] {
        case .song(let song): return song.cover
        case .playlist(let list): return list.cover
        }
    }

    /// 整屏的柔和底色：选中那一项的封面，小图模糊后放大。换图时新的在旧的上面浮现，不会先空一下
    private var backdrop: some View {
        ZStack {
            Color.black
            // 播放界面整个盖着时（covered）直接换：从播放界面点歌手进歌手页，背后已经是歌手的图，不会先亮一下再变
            FadingImage(url: focusedCover, holdWhileLoading: false, instant: covered)
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
                    .hoverLift()
                    .onTapGesture { store.tapTop(.player) }
                }
                if store.page == nil, !store.settingsOpen {
                    searchField
                    let focused = store.topFocus == .account
                    BiliImage(url: store.account?.avatar)
                        .frame(width: 58, height: 58)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(focused ? 1 : 0.2), lineWidth: focused ? 4 : 1.5))
                        .scaleEffect(focused ? 1.12 : 1)
                        .contentShape(Circle())
                        .hoverLift(scale: 1.08)
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
        // 字和旁边正在放的那首歌是同一个大小（同一排的几个胶囊要一样）
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold))
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
        .font(.tv(.caption1))
        .foregroundStyle(store.editing || focused ? .black : .white.opacity(0.85))
        .padding(.horizontal, 24)
        .frame(width: store.editing ? 620 : nil, height: 58, alignment: .leading)
        .background(store.editing || focused ? Color.white : Color.white.opacity(0.12), in: Capsule())
        .scaleEffect(focused ? 1.06 : 1)
        .environment(\.colorScheme, store.editing ? .light : .dark)
        .contentShape(Capsule())
        .hoverLift()
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
                DimBackdrop(close: { store.dismissMenu() })
                    .transition(.opacity)
            }
            if let menu = store.menu {
                let place = menuPlacement(menu, anchors, proxy)
                // 摆好位置以后整块铺满屏幕，再以"从哪儿来"的那个点为中心放大 / 缩小
                menuPanel(menu)
                    .position(x: place.origin.x + place.size.width / 2, y: place.origin.y + place.size.height / 2)
                    .transition(.growing(from: UnitPoint(x: place.from.x / max(1, proxy.size.width),
                                                         y: place.from.y / max(1, proxy.size.height))))
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
                        if item.symbol.isEmpty {
                            Color.clear.frame(width: 36, height: 1)   // 没有图标的一行（比如没打勾的档位）：字照样对齐
                        } else {
                            Image(systemName: item.symbol).font(.system(size: 26, weight: .semibold)).frame(width: 36)
                        }
                        if store.naming == item.action {
                            TextField("歌单标题", text: $store.newName)
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
                    .fill(danger ? Color.destructive : .white)   // 确认"删除""退出登录""取消收藏"时，高亮是红的
                    .frame(height: 74)
                    .offset(y: CGFloat(index) * 82)
                    .opacity(items.isEmpty ? 0 : 1)
            }
        }
        .padding(16)
        .tvPanelSurface(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .tvShadow(.float)
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
        case .setting: "setting"
        }
        let rect = anchors[key].map { proxy[$0] } ?? CGRect(x: screen.width / 2, y: screen.height / 2, width: 0, height: 0)
        var origin = switch menu.anchor {
        case .nowPlaying: CGPoint(x: rect.maxX - size.width + 10, y: rect.minY - size.height - 4)   // "⋯"正上方，右边对齐
        case .account: CGPoint(x: rect.maxX - size.width, y: rect.maxY + 16)                     // 头像正下方，右边对齐
        case .song: CGPoint(x: rect.minX + 70, y: rect.maxY + 4)                                 // 那一行下面
        case .pageButton: CGPoint(x: rect.minX, y: rect.maxY + 16)                               // 按钮下面
        case .card: CGPoint(x: rect.minX + 24, y: rect.minY + 24)                                // 压在卡片左上角里面
        // 设置那一行：下面放得下就贴在下面，放不下（比如最后一行）就贴在上面，右边对齐，绝不飘到别处
        case .setting: CGPoint(x: rect.maxX - size.width,
                               y: rect.maxY + 8 + size.height <= screen.height - 24 ? rect.maxY + 8 : rect.minY - size.height - 8)
        }
        origin.x = min(max(24, origin.x), screen.width - size.width - 24)
        origin.y = min(max(24, origin.y), screen.height - size.height - 24)
        // 设置那一行的菜单从右边的值那里长出来
        let from = menu.anchor == .setting ? CGPoint(x: rect.maxX - 90, y: rect.midY) : CGPoint(x: rect.midX, y: rect.midY)
        return (origin, size, from)
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

    /// 上半屏选中那一项的名字。换的时候旧的先很快淡出、新的再淡入：
    /// 甩着翻很快时也不会两个标题叠在一起糊成一团
    private var details: some View {
        ZStack(alignment: .topLeading) {
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
          .id(store.focused)
          .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.06)),
                                  removal: .opacity.animation(.easeIn(duration: 0.08))))
        }
        .frame(maxWidth: 1250, alignment: .leading)
        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        .padding(.leading, margin)
        .padding(.top, 220)
    }

    /// 卡片和上半屏的第二行：歌手写"歌手"，专辑写歌手名和歌数，歌单写歌数
    private func secondLine(_ list: NeteasePlaylist) -> String? {
        switch list.kind {
        case .artist: "歌手"
        case .album: [list.subtitle, list.count > 0 ? "\(list.count) 首" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .playlist, .recent, .daily: list.count > 0 ? "\(list.count) 首" : nil
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
                            .hoverLift()
                            .onTapGesture { store.focus(row: index, column: column); store.activate() }
                            .onLongPressGesture(minimumDuration: 0.5) { store.longPressCard(row: index, column: column) }
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
            .overlay(PillOutline(shape).strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 5 : 1.5))
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
                            .hoverLift(scale: 1.08)
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
        case .playlist, .recent, .daily: return count > 0 ? "\(count) 首" : " "
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
                        .hoverWash()
                        .onTapGesture { store.tapSong(index) }
                        .onLongPressGesture(minimumDuration: 0.5) { store.longPressSong(index) }
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
                Text(clockText(Double(song.duration))).font(.system(size: 25, weight: .medium).monospacedDigit()).opacity(0.55)
            }
        }
        .foregroundStyle(dark ? .black : .white.opacity(current ? 1 : 0.85))
        .padding(.horizontal, 22)
        .frame(height: songHeight - 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: 设置页

    private let settingHeight: CGFloat = 104

    /// 和歌单页一个样子：左边头像和名字，右边一行行设置（左边名字，右边现在的值）。
    /// 白色高亮滑到哪一行，哪一行就是黑字（和歌单页一样画两遍、用高亮当遮罩）
    private var settingsPage: some View {
        let active = store.topFocus == nil
        let highlightY = CGFloat(store.settingIndex) * settingHeight
        return HStack(alignment: .top, spacing: 100) {
            VStack(alignment: .leading, spacing: 0) {
                BiliImage(url: store.account?.largeAvatar ?? store.account?.avatar)
                    .frame(width: 400, height: 400)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                Text(store.account?.name ?? "").font(.tv(.headline, emphasized: true)).foregroundStyle(.white).lineLimit(1).padding(.top, 30)
                Text("设置").font(.tv(.body)).foregroundStyle(.white.opacity(0.6)).padding(.top, 8)
            }
            .frame(width: 460, alignment: .leading)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white)
                    .frame(height: settingHeight - 8)
                    .offset(y: highlightY)
                    .opacity(active ? 1 : 0)
                // 设置菜单从选中的那一行长出来、收回那一行：用一块看不见的、按排版真正挪到那一行的占位来量位置
                //（上面的白色高亮是用 offset 挪的，量出来永远是第一行"音质"）
                Color.clear
                    .frame(height: settingHeight - 8)
                    .anchorPreference(key: NeteaseAnchors.self, value: .bounds) { ["setting": $0] }
                    .padding(.top, highlightY)
                    .allowsHitTesting(false)
                settingRows(dark: false)
                settingRows(dark: true)
                    .mask(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .frame(height: settingHeight - 8)
                            .offset(y: highlightY)
                    }
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(width: 900, alignment: .topLeading)
            .padding(.top, 48)
        }
        .padding(.horizontal, margin)
        .padding(.top, pageTop)
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .animation(Motion.focus, value: store.settingIndex)
        .animation(Motion.focus, value: active)
    }

    private func settingRows(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(NeteaseStore.Setting.allCases.enumerated()), id: \.offset) { index, setting in
                if dark {
                    settingRow(setting, dark: true)
                } else {
                    settingRow(setting, dark: false)
                        .hoverWash()
                        .onTapGesture { store.activateSetting(index) }
                }
            }
        }
    }

    private func settingRow(_ setting: NeteaseStore.Setting, dark: Bool) -> some View {
        let title = switch setting {
        case .quality: "音质"
        case .balance: "音量平衡"
        case .background: "后台播放"
        case .resume: "记住播放进度"
        case .history: "同步听歌记录"
        case .shelf: "主屏幕顶部"
        }
        let value = setting == .quality ? NeteaseStore.name(of: store.effectiveLevel)
            : setting == .shelf ? NeteaseShelfSource.summary : (store.isOn(setting) ? "打开" : "关闭")
        return HStack(spacing: 18) {
            Text(title).font(.system(size: 30, weight: .semibold))
            Spacer(minLength: 20)
            Text(value).font(.system(size: 28, weight: .medium)).opacity(0.6)
                .contentTransition(.opacity)
            // 弹出一列选项的行带这个记号；开关那几行也留着它的位置，右边的值对在同一条竖线上
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 20, weight: .semibold))
                .opacity(setting == .quality || setting == .shelf ? 0.45 : 0)
        }
        .foregroundStyle(dark ? .black : .white.opacity(0.9))
        .padding(.horizontal, 30)
        .frame(width: 900, height: settingHeight - 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: 正在播放

    /// 左边封面、歌名和进度，右边跟着唱的歌词。没有按钮：左右切歌，确认暂停，上选音质，下看播放列表，返回回列表。
    private func nowPlaying(_ song: NeteaseSong) -> some View {
        ZStack {
            Color.black
            // 背景和封面：切歌时新图到手后在旧图上浮现，不会先空一下，也不会两张叠着
            FadingImage(url: song.cover, holdWhileLoading: false)
                .frame(width: 160, height: 90)
                .blur(radius: 12)
                .scaleEffect(x: canvas.width / 160 * 1.2, y: canvas.height / 90 * 1.2)
                .opacity(0.8)
            Color.black.opacity(0.32)
            HStack(alignment: .center, spacing: 130) {
                VStack(alignment: .leading, spacing: 0) {
                    FadingImage(url: song.cover, holdWhileLoading: false)
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
                        .hoverLift()
                        .onTapGesture { store.tapQueue(index) }
                    }
                }
                .padding(.leading, margin + CGFloat(lo) * (size + gap))
                .offset(x: shift)
            }
            .padding(.top, 70)
            .padding(.bottom, 54)
            .frame(width: canvas.width, alignment: .leading)
            // 右边露出一截的那张封面淡出屏幕（见 EdgeFade）；底下的暗色不跟着淡
            .edgeFade(trailing: true, width: EdgeFadeMask.width(screen: canvas.width, inset: margin, card: size, gap: gap))
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
                // 往屏幕外多铺一段同样深的：滑下来回弹时顶上不露缝
                VStack(spacing: 0) {
                    Color.black.opacity(0.85).frame(height: 400)
                    EdgeScrim(strength: 0.85, edge: .top)
                }
                .padding(.top, -400)
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
    @ObservedObject private var pointer = PointerActivity.shared   // 按键、滑动时鼠标悬停的加粗收起

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
                .frame(height: store.scrubbing || (hovering && pointer.active) ? 12 : 7)
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
                Text(clockText(clock.time))
                Spacer()
                // 中间：一直是这首歌实际在放的音质（暂停图标在封面上）。点它打开音质栏。
                // 汉字占满整个字框，同样字号比两头的数字看着大一圈：汉字小一号，看起来才一样高（"Hi-Res"是英文，不用）
                let quality = NeteaseStore.name(of: store.actualLevel)
                Text(quality)
                    .font(.system(size: quality.allSatisfy(\.isASCII) ? 24 : 20, weight: .medium))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: store.actualLevel)
                    .contentShape(Rectangle())
                    .hoverLift(scale: 1.06, brighten: 0.25)
                    .onTapGesture { store.openQualityBar() }
                Spacer()
                Text("-" + clockText(max(0, clock.duration - clock.time)))
            }
            .font(.system(size: 24, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// 正在唱的那一句（有逐字时间时）：KTV 那样从左往右涂亮。每个字（英文是每个词）在它自己唱的那段时间里，
/// 从灰色一点点涂成白色，分界线带一段柔和的过渡；拖长音的字涂得慢，快的字涂得快。
/// 和网易云、Apple Music 的逐字歌词是同一个做法：涂到哪 = (现在 − 这个字开始唱) ÷ 这个字唱多久，
/// "现在"每一帧直接问播放器（声音实际放到的位置），所以不会越走越偏。
/// macOS 15 起用系统的逐字绘制来涂；更老的系统整个字慢慢变亮（同一套时间）。
struct NeteaseKaraokeLine: View {
    /// 提前一点点：画面从算出来到真正显示在电视上要两三帧，再加上"涂到一半才看得出在唱这个字"，
    /// 所以整体提前 0.08 秒，字被唱出来的那一刻正好开始涂。以前是开始唱才亮、半秒左右才亮到一半，看着慢半个字
    nonisolated static let lead = 0.08
    /// 涂到第几成（0 还没开始，1 涂满）。极短的字至少给 0.08 秒涂，不会一闪而过
    nonisolated static func progress(at now: Double, start: Double, duration: Double) -> Double {
        max(0, min(1, (now + lead - start) / max(0.08, duration)))
    }
    nonisolated static let dim = 0.42

    /// 一个字（词）后面带着的空格、标点不占它唱的时间：字在自己的时长里涂满，后面的标点在它唱完时一下亮起。
    /// 不然"字，"整个按一个字的宽度涂，字涂到一半就唱完了，看着跑在声音前面
    static func split(_ text: String) -> (core: String, tail: String) {
        var core = Substring(text)
        var tail = ""
        while let last = core.last, last.isWhitespace || last.isPunctuation {
            tail.insert(last, at: tail.startIndex)
            core.removeLast()
        }
        return core.isEmpty ? (text, "") : (String(core), tail)
    }

    let line: NeteaseLyricLine
    let playing: Bool
    /// 现在放到哪了：每一帧直接问播放器，和声音严丝合缝
    let time: () -> Double

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !playing)) { _ in
            let now = time()
            if #available(macOS 15, *) {
                line.words.reduce(Text("")) { text, word in
                    let (core, tail) = Self.split(word.text)
                    let sung = text + Text(core).customAttribute(KaraokeTiming(start: word.time, duration: word.duration))
                    return tail.isEmpty ? sung : sung + Text(tail).customAttribute(KaraokeTiming(start: word.time + word.duration, duration: 0))
                }
                .foregroundStyle(.white)
                .textRenderer(KaraokeRenderer(now: now))
            } else {
                line.words.reduce(Text("")) { text, word in
                    let level = NeteaseKaraokeLine.progress(at: now, start: word.time, duration: word.duration)
                    return text + Text(word.text).foregroundColor(.white.opacity(Self.dim + (1 - Self.dim) * level))
                }
            }
        }
    }
}

/// 每个字什么时候开始唱、唱多久，跟着字走，画的时候拿出来算涂到哪
@available(macOS 15, *)
struct KaraokeTiming: TextAttribute {
    let start: Double
    let duration: Double
}

/// 逐字涂亮：每个字先画一层灰的，再画一层白的，白的那层只露出左边涂过的部分，分界处渐变过渡
@available(macOS 15, *)
struct KaraokeRenderer: TextRenderer {
    let now: Double

    /// 一个字（词）被折到两行、或者中英文混排被拆成几段时，它就成了好几段（run）。这几段要当成一个整体
    /// 从左到右接着涂：先涂第一段，涂满了再涂下一段，而不是几段同时涂
    static func share(of done: Double, total: Double, before: Double, width: Double) -> Double {
        guard width > 0 else { return done >= 1 ? 1 : 0 }
        return max(0, min(1, (done * total - before) / width))
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // 先量一遍：每个字一共多宽、它的每一段前面已经有多宽
        var totals: [KaraokeTiming: Double] = [:]
        var befores: [Double] = []
        for line in layout {
            for run in line {
                guard let timing = run[KaraokeTiming.self] else { befores.append(0); continue }
                let width = run.typographicBounds.rect.width
                befores.append(totals[timing, default: 0])
                totals[timing, default: 0] += width
            }
        }
        var position = 0
        for line in layout {
            for run in line {
                defer { position += 1 }
                guard let timing = run[KaraokeTiming.self] else { context.draw(run); continue }
                let box = run.typographicBounds.rect
                let whole = NeteaseKaraokeLine.progress(at: now, start: timing.start, duration: timing.duration)
                let done = Self.share(of: whole, total: totals[timing] ?? box.width, before: befores[position], width: box.width)
                if done >= 1 { context.draw(run); continue }
                var dim = context
                dim.opacity = NeteaseKaraokeLine.dim
                dim.draw(run)
                guard done > 0 else { continue }
                // 过渡带：字宽的一半（至少 8 点），随涂的进度从字左边外面走到右边外面
                let soft = max(8, box.width * 0.5)
                let edge = box.minX - soft + (box.width + soft) * done
                let tall = CGRect(x: box.minX - 4, y: box.minY - box.height, width: 0, height: box.height * 3)
                var lit = context
                lit.clipToLayer { mask in
                    mask.fill(Path(CGRect(x: tall.minX, y: tall.minY, width: max(0, edge - tall.minX), height: tall.height)), with: .color(.white))
                    mask.fill(Path(CGRect(x: edge, y: tall.minY, width: soft, height: tall.height)),
                              with: .linearGradient(Gradient(colors: [.white, .white.opacity(0)]),
                                                    startPoint: CGPoint(x: edge, y: 0), endPoint: CGPoint(x: edge + soft, y: 0)))
                }
                lit.draw(run)
            }
        }
    }
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


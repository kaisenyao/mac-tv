import SwiftUI

struct NeteaseRoot: View {
    @ObservedObject var store: NeteaseStore

    var body: some View {
        TVCanvas { NeteaseScreen(store: store) }.ignoresSafeArea()
    }
}

/// 网易云音乐的电视式页面。
///
/// 首页：上半屏是选中那首歌（或歌单）的名字，下半屏是一排排方形封面；最上面一排再按上是搜索框。
/// 歌单页：左边封面和歌单名，右边竖排的歌曲列表。
/// 正在播放：左边封面、歌名和进度，右边跟着唱的歌词；按上选音质。
/// 全程只用方向键、确认、返回。
struct NeteaseScreen: View {
    @ObservedObject var store: NeteaseStore
    @Environment(\.canvasSize) private var canvas
    @FocusState private var typing: Bool
    @Namespace private var qualitySpace
    @FocusState private var namingField: Bool
    private let menuWidth: CGFloat = 360

    private let margin: CGFloat = 120
    private let cardSize: CGFloat = 300
    private let cardGap: CGFloat = 40
    private let rowHeight: CGFloat = 500
    private let rowsTop: CGFloat = 430
    private let songHeight: CGFloat = 92
    private static let slide = Animation.spring(response: 0.42, dampingFraction: 0.84)

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            if store.account != nil {
                Group {
                    rows
                        .frame(width: canvas.width, height: canvas.height - rowsTop, alignment: .topLeading)
                        .clipped()
                        .offset(y: rowsTop)
                    details
                }
                .opacity(store.page == nil ? 1 : 0)
                if let page = store.page {
                    playlistPage(page).transition(.opacity)
                }
                if store.loading, store.rows.isEmpty {
                    ProgressView().controlSize(.large).position(x: canvas.width / 2, y: canvas.height / 2)
                }
            } else if store.checked {
                login
            }
            topBar
            if let song = store.current {
                nowPlaying(song)
                    .opacity(store.nowPlayingVisible ? 1 : 0)
                    .allowsHitTesting(store.nowPlayingVisible)
            }
            menuView
        }
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.navigate, value: store.nowPlayingVisible)
        .animation(Motion.navigate, value: store.page?.list.id)
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

    private var backdrop: some View {
        ZStack {
            Color.black
            // 小图模糊后再放大：整屏的柔和底色，开销很小
            BiliImage(url: focusedCover)
                .frame(width: 160, height: 90)
                .blur(radius: 14)
                .scaleEffect(x: canvas.width / 160 * 1.15, y: canvas.height / 90 * 1.15)
                .opacity(0.5)
                .id(focusedCover)
                .transition(.opacity)
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .animation(.easeInOut(duration: 0.5), value: focusedCover)
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
                        .onTapGesture { store.tapTop(.account) }
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
        .onTapGesture { store.tapTop(.search) }
        .onChange(of: store.editing) { _, editing in typing = editing }
        .onChange(of: store.focusRequest) { _, _ in if store.editing { typing = true } }
        .animation(Self.slide, value: store.editing)
    }

    // MARK: 菜单

    /// 长按确认、点"⋯"或点头像弹出来的小菜单：玻璃底板，白色高亮上下滑。和哔哩哔哩卡片菜单是同一种。
    @ViewBuilder private var menuView: some View {
        ZStack(alignment: .topLeading) {
            if let menu = store.menu {
                let height = CGFloat(menu.items.count) * 82 - 8 + 32
                // 从哪儿弹出来，就以哪个角为准放大：播放界面的"⋯"在它右下，头像在它右上，卡片在它左上
                let corner: UnitPoint = menu.anchor == .account ? .topTrailing : (menu.anchor == .nowPlaying ? .bottomTrailing : .topLeading)
                menuPanel(menu)
                    .offset(menuOrigin(height: height))
                    .transition(.scale(scale: 0.6, anchor: corner).combined(with: .opacity))
                    .id(menu.anchor)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .allowsHitTesting(store.menu != nil)
        .animation(Self.slide, value: store.menu != nil)
    }

    private func menuPanel(_ menu: NeteaseStore.Menu) -> some View {
        let items = menu.items
        let index = min(menu.index, max(0, items.count - 1))
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { row, item in
                let focused = row == index
                HStack(spacing: 18) {
                    if case .create = item.action, store.naming != nil {
                        Image(systemName: "plus").font(.system(size: 26, weight: .semibold)).frame(width: 36)
                        TextField("歌单名字", text: $store.newName)
                            .textFieldStyle(.plain)
                            .font(.tv(.callout))
                            .focused($namingField)
                            .onSubmit { store.createList() }
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
                        Image(systemName: item.symbol).font(.system(size: 26, weight: .semibold)).frame(width: 36)
                        Text(title(of: item)).font(.tv(.callout, emphasized: focused)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .foregroundStyle(focused ? .black : .white.opacity(0.8))
                .padding(.horizontal, 22)
                .frame(width: menuWidth - 32, height: 74)
                .contentShape(Rectangle())
                .onTapGesture { store.tapMenu(row) }
            }
        }
        .background(alignment: .top) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(store.logoutArmed ? Color(hex: "#E5484D") : .white)
                .frame(height: 74)
                .offset(y: CGFloat(index) * 82)
                .opacity(items.isEmpty ? 0 : 1)
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
        .animation(Self.slide, value: index)
        .animation(Self.slide, value: items.count)
    }

    private func title(of item: NeteaseStore.MenuItem) -> String {
        if case .logout = item.action, store.logoutArmed { return "再按一次退出" }
        return item.title
    }

    /// 菜单摆在哪：贴着它是从哪儿弹出来的
    private func menuOrigin(height: CGFloat) -> CGSize {
        switch store.menu?.anchor {
        case .account:
            return CGSize(width: canvas.width - margin - menuWidth, height: 58 + 58 + 18)
        case .nowPlaying:
            // 歌名那一行"⋯"的上方
            return CGSize(width: playerLeft + 600 - menuWidth + 8, height: playerTop + 600 + 36 - height)
        case .song:
            let visible = min(store.page?.index ?? 0, pageAnchor)
            return CGSize(width: margin + 560 + 90, height: min(pageTop + CGFloat(visible) * songHeight + 40, canvas.height - height - 40))
        default:
            let line = store.rows.indices.contains(store.row) ? store.rows[store.row] : nil
            let column = line.map { store.column(of: $0) } ?? 0
            return CGSize(width: margin + (column > 0 ? cardSize + cardGap : 0) + 30, height: rowsTop + 110)
        }
    }

    /// 播放界面左边那一栏（封面、歌名、进度）的左上角
    private var playerLeft: CGFloat { store.lyricsShown ? (canvas.width - (600 + 130 + 800)) / 2 : (canvas.width - 600) / 2 }
    private var playerTop: CGFloat { (canvas.height - 820) / 2 }
    private let pageTop: CGFloat = 190
    /// 歌单页里选中的行尽量停在第 4 行的位置，上面能看到刚过去的几首
    private let pageAnchor = 3

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
                if list.count > 0 { Text("\(list.count) 首").font(.tv(.body)).foregroundStyle(.white.opacity(0.72)) }
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
                        card(item, focused: active && column == focusedColumn)
                            .onTapGesture { store.focus(row: index, column: column); store.activate() }
                            .opacity(column < focusedColumn - 1 ? 0 : 1)
                            .animation(.easeInOut(duration: 0.42), value: focusedColumn)
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
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Color.white.opacity(0.06)
                switch item {
                case .song(let song):
                    BiliImage(url: song.cover)
                    if store.current == song {
                        Color.black.opacity(0.45)
                        NeteaseWave(playing: !store.paused, size: 64).foregroundStyle(.white)
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

            VStack(alignment: .leading, spacing: 6) {
                switch item {
                case .song(let song):
                    Text(song.name).font(.system(size: 27, weight: focused ? .semibold : .medium)).foregroundStyle(.white.opacity(focused ? 1 : 0.78)).lineLimit(1)
                    Text(song.artist).font(.tv(.caption2)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                case .playlist(let list):
                    Text(list.name).font(.system(size: 27, weight: focused ? .semibold : .medium)).foregroundStyle(.white.opacity(focused ? 1 : 0.78)).lineLimit(1)
                    if list.count > 0 { Text("\(list.count) 首").font(.tv(.caption2)).foregroundStyle(.white.opacity(0.5)) }
                }
            }
            .frame(width: cardSize, alignment: .leading)
            .offset(y: focused ? 12 : 0)
        }
        .zIndex(focused ? 1 : 0)
        .animation(Motion.focus, value: focused)
    }

    // MARK: 歌单页

    /// 左边封面、歌单名和几个按钮（播放、随机播放、收藏），右边竖排的歌：选中的那一行是白底黑字。
    /// 在歌曲里按左到按钮，在按钮上按右回到歌曲。
    private func playlistPage(_ page: NeteaseStore.Page) -> some View {
        let shift = -CGFloat(max(0, page.index - pageAnchor)) * songHeight
        let listActive = page.button == nil && store.topFocus == nil
        return HStack(alignment: .top, spacing: 100) {
            VStack(alignment: .leading, spacing: 0) {
                BiliImage(url: page.list.cover)
                    .frame(width: 400, height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                Text(page.list.name).font(.tv(.headline, emphasized: true)).foregroundStyle(.white).lineLimit(2).padding(.top, 30)
                Text(page.loading ? "正在载入…" : "\(page.songs.count) 首")
                    .font(.tv(.body)).foregroundStyle(.white.opacity(0.6)).padding(.top, 8)
                // 一横排圆形图标；选中哪个，哪个拉长、把字显示出来
                HStack(spacing: 14) {
                    ForEach(Array(store.pageButtons.enumerated()), id: \.offset) { index, button in
                        pageButton(button, list: page.list, focused: page.button == index && store.topFocus == nil)
                            .onTapGesture { store.pressPageButton(index) }
                    }
                }
                .padding(.top, 30)
            }
            .frame(width: 460, alignment: .leading)
            .padding(.top, pageTop)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(page.songs.enumerated()), id: \.offset) { index, song in
                    // 只画选中那行附近的，几百首的歌单也不卡
                    if abs(index - page.index) <= 14 {
                        songRow(song, number: index + 1, focused: listActive && index == page.index)
                            .onTapGesture { store.tapSong(index) }
                    } else {
                        Color.clear.frame(height: songHeight)
                    }
                }
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
        .animation(Self.slide, value: page.index)
        .animation(Motion.focus, value: page.button)
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
        .animation(Self.slide, value: focused)
    }

    private func songRow(_ song: NeteaseSong, number: Int, focused: Bool) -> some View {
        let current = store.current == song
        return HStack(spacing: 24) {
            ZStack {
                if current {
                    NeteaseWave(playing: !store.paused, size: 26)   // 正在放的这一首：波形跟着动，暂停时停住
                } else {
                    Text("\(number)").font(.system(size: 25, weight: .medium).monospacedDigit()).opacity(0.5)
                }
            }
            .frame(width: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.name).font(.system(size: 30, weight: focused ? .semibold : .medium)).lineLimit(1)
                Text(song.artist).font(.system(size: 23, weight: .regular)).opacity(0.6).lineLimit(1)
            }
            Spacer(minLength: 20)
            if store.liked.contains(song.id) { Image(systemName: "heart.fill").font(.system(size: 20)).opacity(0.5) }
            if song.duration > 0 {
                Text(clock(Double(song.duration))).font(.system(size: 25, weight: .medium).monospacedDigit()).opacity(0.55)
            }
        }
        .foregroundStyle(focused ? .black : .white.opacity(current ? 1 : 0.85))
        .padding(.horizontal, 22)
        .frame(height: songHeight - 8)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white).opacity(focused ? 1 : 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: 正在播放

    /// 左边封面、歌名和进度，右边跟着唱的歌词。没有按钮：左右切歌，确认暂停，上选音质，返回回列表。
    private func nowPlaying(_ song: NeteaseSong) -> some View {
        ZStack {
            Color.black
            // 背景和封面：切歌时直接换成新的（新图到手之前留着上一张），不做叠化，不会出现两张图叠在一起
            BiliImage(url: song.cover, keepsPrevious: true)
                .frame(width: 160, height: 90)
                .blur(radius: 12)
                .scaleEffect(x: canvas.width / 160 * 1.2, y: canvas.height / 90 * 1.2)
                .opacity(0.8)
            Color.black.opacity(0.32)
            HStack(alignment: .center, spacing: 130) {
                VStack(alignment: .leading, spacing: 0) {
                    BiliImage(url: song.cover, keepsPrevious: true)
                        .frame(width: 600, height: 600)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.55), radius: 50, y: 30)
                        .scaleEffect(store.paused ? 0.9 : 1)
                        .animation(Self.slide, value: store.paused)
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(song.name).font(.tv(.headline, emphasized: true)).foregroundStyle(.white).lineLimit(1)
                            Text(song.artist).font(.tv(.body)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        // "⋯"：长按确认（或点它）展开——喜欢、收藏到歌单、播放模式
                        Image(systemName: "ellipsis")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white.opacity(store.menu?.anchor == .nowPlaying ? 1 : 0.7))
                            .frame(width: 58, height: 58)
                            .contentShape(Rectangle())
                            .onTapGesture { store.tapMore() }
                    }
                    .padding(.top, 36)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.22))
                            Capsule().fill(.white)
                                .frame(width: geo.size.width * (store.duration > 0 ? min(1, store.time / store.duration) : 0))
                        }
                    }
                    .frame(height: 7)
                    .padding(.top, 34)
                    HStack {
                        Text(clock(store.time))
                        Spacer()
                        if store.paused { Image(systemName: "pause.fill") }
                        Spacer()
                        Text("-" + clock(max(0, store.duration - store.time)))
                    }
                    .font(.system(size: 24, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 14)
                }
                .frame(width: 600, alignment: .leading)
                // 没有歌词的歌（纯音乐等）不留歌词那一栏，封面这一栏自己居中
                if store.lyricsShown {
                    lyricsColumn
                        .frame(width: 800, height: 820, alignment: .leading)
                        .id(song.id)   // 每首歌一份全新的歌词：换歌时直接换，旧歌词不会和新歌词叠着过渡
                        .transition(.opacity)
                }
            }
            qualityBar
            queueRow
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    /// 当前的播放列表：按下从屏幕下方滑上来的一排封面，左右挑，确认就放那一首。和哔哩哔哩的相关视频是同一种做法。
    private var queueRow: some View {
        let open = store.queueVisible
        let size: CGFloat = 230, gap: CGFloat = 34
        let focus = store.queueFocus
        let shift = -CGFloat(max(0, focus - 1)) * (size + gap)
        return VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 22) {
                Text("播放列表").font(.tv(.headline, emphasized: true)).foregroundStyle(.white).padding(.leading, margin)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(store.queue.enumerated()), id: \.offset) { index, song in
                        if abs(index - focus) <= 9 {
                            let focused = index == focus
                            VStack(alignment: .leading, spacing: 12) {
                                ZStack {
                                    BiliImage(url: song.cover)
                                    if index == store.queueIndex {
                                        Color.black.opacity(0.45)
                                        NeteaseWave(playing: !store.paused, size: 50).foregroundStyle(.white)
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
                        } else {
                            Color.clear.frame(width: size, height: 1)
                        }
                    }
                }
                .padding(.leading, margin)
                .offset(x: shift)
            }
            .padding(.top, 70)
            .padding(.bottom, 54)
            .frame(width: canvas.width, alignment: .leading)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.7), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -400)   // 往屏幕外多铺一段：滑上来回弹时底下不露缝
            }
        }
        .offset(y: open ? 0 : 520)
        .opacity(open ? 1 : 0)
        .animation(Self.slide, value: open)
        .animation(Self.slide, value: focus)
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
        .animation(Self.slide, value: open)
        .animation(Self.slide, value: store.qualityIndex)
    }

    /// 歌词：正在唱的那句又大又亮、停在中间，前后的句子越远越淡。
    /// 有逐字歌词的歌，这一句里唱到哪个字亮到哪个字（卡拉 OK 那样）。
    @ViewBuilder private var lyricsColumn: some View {
        if store.lyrics.isEmpty {
            Color.clear
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 34) {
                        Color.clear.frame(height: 360)
                        ForEach(Array(store.lyrics.enumerated()), id: \.offset) { index, line in
                            let current = index == store.lyricIndex
                            let distance = abs(index - max(0, store.lyricIndex))
                            lineText(line, current: current)
                                .font(.system(size: 50, weight: .bold))
                                .opacity(current ? 1 : max(0.1, 0.38 - Double(distance) * 0.06))
                                .scaleEffect(current ? 1 : 0.94, anchor: .leading)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                        Color.clear.frame(height: 360)
                    }
                    .animation(.easeInOut(duration: 0.45), value: store.lyricIndex)
                }
                .scrollDisabled(true)
                .onChange(of: store.lyricIndex) { _, index in
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { proxy.scrollTo(max(0, index), anchor: .center) }
                }
                .onChange(of: store.lyrics) { _, _ in proxy.scrollTo(max(0, store.lyricIndex), anchor: .center) }
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
    }

    /// 一句歌词。正在唱、并且有逐字时间的那一句：唱到哪个字，哪个字渐渐亮起来。
    private func lineText(_ line: NeteaseLyricLine, current: Bool) -> Text {
        guard current, !line.words.isEmpty else { return Text(line.text).foregroundColor(.white) }
        // 每个字不是一下子变白，而是在它该唱的那一小段时间里从半透明慢慢亮起来
        return line.words.reduce(Text("")) { text, word in
            let span = max(0.3, min(word.duration, 0.9))
            let progress = max(0, min(1, (store.time + 0.05 - word.time) / span))
            return text + Text(word.text).foregroundColor(.white.opacity(0.42 + 0.58 * progress))
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 正在播放的标记：在放的时候是几根上下起伏的竖条（像声波），暂停时是一个暂停图标
struct NeteaseWave: View {
    let playing: Bool
    var size: CGFloat = 24

    var body: some View {
        if playing {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
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

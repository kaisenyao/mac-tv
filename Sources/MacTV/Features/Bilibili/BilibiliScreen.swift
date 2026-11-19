import SwiftUI

/// 哔哩哔哩的入口：列表页，或者正在播放时的播放界面
struct BilibiliRoot: View {
    @ObservedObject var store: BilibiliStore

    var body: some View {
        ZStack {
            TVCanvas { BilibiliScreen(store: store) }.ignoresSafeArea()
            if let video = store.player.current {
                BilibiliPlayerScreen(player: store.player, video: video)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.player.current)
    }
}

/// 哔哩哔哩的电视式页面。
///
/// 左边一列很淡的小图标是导航（搜索、首页、关注、发现、我的），焦点移过去才展开成带文字的面板；
/// 右边上半屏是当前选中视频的大标题和封面背景，下半屏是一排排大卡片。
/// 按 1920×1080 的电视画布排版，三米外能看清；全程只用方向键、确认、返回。
struct BilibiliScreen: View {
    @ObservedObject var store: BilibiliStore
    @Environment(\.canvasSize) private var canvas
    @FocusState private var typing: Bool

    private let margin: CGFloat = 176
    /// 左边栏展开时，右边的内容整体让开这么多（Apple TV 的做法：内容右移并变暗，而不是被盖住）
    private let sidebarShift: CGFloat = 214
    private let cardWidth: CGFloat = 416
    private let cardGap: CGFloat = 40
    private let rowHeight: CGFloat = 470
    /// 卡片区从多高开始。搜索页里焦点不在视频上时（输入框、"UP 主"那一排），上面只有搜索框，
    /// 结果整体往上挪；焦点到了视频上，就和别的页一样，上面是大标题。
    private var rowsTop: CGFloat { searchPage ? 316 : 470 }
    private var searchPage: Bool { store.tab == .search && store.upPage == nil && focusedVideo == nil }
    private let pink = Color(hex: "#FB7299")
    @Namespace private var sortSpace
    /// 粉色的 bilibili 字标（Icons/bilibili-logo.png，透明底）
    private static let logo: NSImage? = Bundle.main.url(forResource: "bilibili-logo.png", withExtension: nil, subdirectory: "Icons")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            Group {
                rows
                    .frame(width: canvas.width, height: canvas.height - rowsTop, alignment: .topLeading)
                    .clipped()
                    // 卡片往左滑的途中，越靠近左边那列图标越淡：淡出是跟着位置走的，所以和滑动严丝合缝。
                    // （滑到头的卡片另外会整张隐去，见 rowView，所以这里不会留残影。）
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 84)
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 74)
                            Color.black
                        }
                    }
                    .offset(y: rowsTop)
                details
                if store.rows.isEmpty { status }
            }
            .offset(x: store.headerFocused ? sidebarShift : (store.settingsOpen ? -50 : 0))
            .opacity(store.settingsOpen ? 0 : (store.headerFocused ? 0.4 : 1))
            .animation(Self.slide, value: store.headerFocused)
            .animation(.easeOut(duration: 0.2), value: store.settingsOpen)
            // 设置页：列表先往左退一点淡出，设置页随后从右边进来（和网易云进设置一样）
            if store.settingsOpen {
                BilibiliSettingsPage(store: store, player: store.player)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 50)).animation(.easeOut(duration: 0.28).delay(0.05)),
                                            removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
            topBar
            sidebar
            cardMenu
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .background(Color.black)
        .animation(Motion.focus, value: store.headerFocused)
    }

    // MARK: 左边栏

    /// 左边栏：靠左、上下居中。从头到尾只有一组图标，它们基本不动：
    /// 展开时，玻璃底板和文字从左边滑出来把图标"接住"；收起时，底板和文字往左吸走，图标留在原地变淡。
    /// 所以是同一样东西在两种状态之间过渡，而不是两层东西一隐一现。
    private var sidebar: some View {
        let open = store.headerFocused
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(BilibiliStore.Tab.allCases) { tab in
                let current = tab == store.sidebarTab
                HStack(spacing: 20) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 44)
                    Text(tab.title)
                        .font(.tv(.callout, emphasized: current))
                        .fixedSize()
                        .opacity(open ? 1 : 0)
                        .offset(x: open ? 0 : -36)          // 文字往左收
                        .frame(width: open ? 184 : 0, alignment: .leading)
                        .clipped()
                }
                .foregroundStyle(open && current ? Color.black : Color.white.opacity(current ? 1 : (open ? 0.78 : 0.38)))
                .animation(open ? Self.slide : .easeOut(duration: 0.16), value: open)
                .padding(.horizontal, 22)
                .frame(width: open ? 292 : 88, height: 78, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.select(tab) }
            }
        }
        .padding(18)
        .background(alignment: .topLeading) {
            // 当前项的白色高亮：展开时是一整条；收起时不跟底板走，而是自己收缩成一个小白点，
            // 停在当前图标的左边，当作"现在在哪一页"的指示。再展开时从这个小白点长回去。
            let index = CGFloat(BilibiliStore.Tab.allCases.firstIndex(of: store.sidebarTab) ?? 0)
            RoundedRectangle(cornerRadius: open ? 22 : 5, style: .continuous)
                .fill(.white)
                .frame(width: open ? 292 : 10, height: open ? 78 : 10)
                .offset(x: open ? 18 : 18, y: 18 + index * 88 + (open ? 0 : 34))
        }
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
        .frame(height: canvas.height, alignment: .center)
        .animation(Self.slide, value: open)
        .animation(Self.slide, value: store.tab)
    }

    /// 左边栏滑出 / 吸回，以及右边内容让开 / 回位，共用这一条带一点弹性的曲线
    private static let slide = Animation.spring(response: 0.42, dampingFraction: 0.84)

    // MARK: 背景：选中视频的封面，放大、模糊、压暗

    private var focusedVideo: BiliVideo? {
        if case .video(let video) = store.highlighted { return video }
        return nil
    }

    private var backdrop: some View {
        ZStack {
            Color(hex: "#0B0B10")
            if let cover = focusedVideo?.cover {
                // 背景只是一片色彩，用很小的一张图就够：先在小尺寸上模糊，再放大铺满。
                // 直接对全屏大图做大半径模糊，每一帧都很贵，会拖慢别的动画。
                let small = URL(string: cover.absoluteString.replacingOccurrences(of: "@800w_450h_1c", with: "@160w_90h_1c")) ?? cover
                BiliImage(url: small)
                    .frame(width: 160, height: 90)
                    .blur(radius: 7)
                    .scaleEffect(x: canvas.width / 160 * 1.16, y: canvas.height / 90 * 1.16)
                    .frame(width: canvas.width, height: canvas.height)
                    .opacity(0.75)
                    .id(cover)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .animation(.easeInOut(duration: 0.5), value: focusedVideo?.cover)
    }

    // MARK: 上半屏：品牌、账号、选中视频的信息（或搜索框）

    /// 顶部一行：品牌和账号。左边栏展开时它不动。
    private var topBar: some View {
        HStack(alignment: .center, spacing: 28) {
            if let logo = Self.logo {
                Image(nsImage: logo).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 64)
            } else {
                Text("bilibili")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .foregroundStyle(pink)
            }
            Spacer()
            HStack(spacing: 14) {
                if let face = store.account?.face {
                    BiliImage(url: face)
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                } else {
                    Image(systemName: store.account == nil ? "person.crop.circle" : "person.crop.circle.fill")
                }
                Text(store.account?.name ?? "未登录")
            }
            .font(.tv(.caption1, emphasized: store.accountFocused))
            .foregroundStyle(store.accountFocused ? .black : .white.opacity(0.85))
            .padding(.leading, store.account?.face == nil ? 26 : 12).padding(.trailing, 26).padding(.vertical, store.account?.face == nil ? 14 : 9)
            .focusPlatter(Capsule(), focused: store.accountFocused)
            .scaleEffect(store.accountFocused ? 1.07 : 1, anchor: .trailing)
            .animation(Motion.focus, value: store.accountFocused)
            .contentShape(Capsule())
            .onTapGesture { store.tapAccount() }
            // 账号菜单：从头像下面滑出来，和左边栏是同一种玻璃和同一条曲线
            .overlay(alignment: .topTrailing) { accountMenu.offset(y: 84) }
        }
        .padding(.horizontal, margin)
        .padding(.top, 64)
        .frame(width: canvas.width, alignment: .leading)
    }

    /// 头像下面的账号菜单。一直都在，平时缩在头像后面；白色高亮是同一块，在两项之间滑动。
    private var accountMenu: some View {
        let open = store.accountMenuOpen
        let actions = store.accountActions
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                let focused = index == store.accountIndex
                HStack(spacing: 18) {
                    Image(systemName: symbol(for: action)).font(.system(size: 26, weight: .semibold)).frame(width: 36)
                    Text(hint(for: action)).font(.tv(.callout, emphasized: focused))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(focused ? (action == .confirmLogout ? .white : .black) : .white.opacity(0.8))
                .padding(.horizontal, 22)
                .frame(width: 300, height: 74)
                .contentShape(Rectangle())
                .onTapGesture { store.tapAccountAction(index) }
            }
        }
        .background(alignment: .top) {
            let index = min(store.accountIndex, max(0, actions.count - 1))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(actions.indices.contains(index) && actions[index] == .confirmLogout ? Color(hex: "#E5484D") : .white)
                .frame(height: 74)
                .offset(y: CGFloat(index) * 82)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.black.opacity(0.35))
            RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.16))
        }
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
        .fixedSize()
        .scaleEffect(open ? 1 : 0.86, anchor: .topTrailing)
        .offset(y: open ? 0 : -26)
        .opacity(open ? 1 : 0)
        .allowsHitTesting(open)
        .animation(Self.slide, value: open)
        .animation(Self.slide, value: store.accountIndex)
    }

    private func symbol(for item: BilibiliStore.Item) -> String {
        switch item {
        case .login: "qrcode.viewfinder"
        case .refresh: "arrow.clockwise"
        case .settings: "gearshape"
        case .logout, .confirmLogout: "rectangle.portrait.and.arrow.right"
        case .keepLogin: "xmark"
        case .empty: "star"
        case .user: "person.fill"
        case .video: "play.fill"
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("bilibili")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .hidden()
                Spacer()
            }
            Spacer().frame(height: searchPage ? 30 : 74)
            if let page = store.upPage, !page.browsing {
                VStack(alignment: .leading, spacing: 36) {
                    upHeader(page)
                    sortBar(page)
                }
            } else if searchPage {
                searchField   // 搜索页的上方始终是搜索框（显示刚搜的词，按上可以接着改）
            } else if let video = focusedVideo {
                VStack(alignment: .leading, spacing: 18) {
                    Text(video.title)
                        .font(.tv(.title2, emphasized: true))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: 1250, alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
                    HStack(spacing: 22) {
                        if !video.owner.isEmpty { Label(video.owner, systemImage: "person.fill") }
                        if video.views > 0 { Label(video.viewsText, systemImage: "play.rectangle.fill") }
                        if video.duration > 0 { Label(video.durationText, systemImage: "clock.fill") }
                    }
                    .font(.tv(.body))
                    .foregroundStyle(.white.opacity(0.72))
                }
                .id(video.id)
                .transition(.opacity)
            } else if let item = store.highlighted {
                Text(hint(for: item))
                    .font(.tv(.headline))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: 1250, alignment: .leading)
            } else {
                Text(store.upPage?.user.name ?? store.tab.title)
                    .font(.tv(.title2, emphasized: true))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, 64)
        .frame(width: canvas.width, alignment: .leading)
        .animation(.easeInOut(duration: 0.22), value: store.highlighted)
        .animation(.easeInOut(duration: 0.22), value: store.tab)
    }

    /// 焦点停在搜索框上、但还没开始打字
    private var fieldFocused: Bool {
        store.tab == .search && !store.headerFocused && !store.editing && store.rows.isEmpty
    }

    /// 搜索页上方的大输入框：按确认后才真正进入输入（系统输入框，中文输入法可用）
    private var searchField: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 20) {
                Image(systemName: "magnifyingglass").font(.system(size: 38, weight: .semibold))
                if store.editing {
                    TextField("搜索视频", text: $store.query)
                        .textFieldStyle(.plain)
                        .focused($typing)
                        .onSubmit { store.submitSearch() }
                        .onAppear { typing = true }   // 输入框一出现就拿键盘（只靠状态变化去设，有时会落空）
                } else {
                    Text(store.query.isEmpty ? "搜索视频" : store.query)
                        .opacity(store.query.isEmpty ? 0.45 : 1)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .font(.tv(.headline))
            .foregroundStyle(store.editing ? .black : .white)
            .padding(.horizontal, 34)
            .frame(width: 1100, height: 104, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(store.editing ? Color.white : Color.white.opacity(fieldFocused ? 0.2 : 0.12))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(store.editing ? 0 : (fieldFocused ? 0.95 : 0.2)), lineWidth: fieldFocused ? 5 : 1.5)
            }
            .scaleEffect(fieldFocused ? 1.02 : 1, anchor: .leading)
            .environment(\.colorScheme, store.editing ? .light : .dark)
            .onChange(of: store.editing) { _, editing in typing = editing }
        }
    }

    /// UP 主页的上方：头像、名字、粉丝数，名字旁边是关注按钮（第一排再按上才会选中它）
    private func upHeader(_ page: BilibiliStore.UpPage) -> some View {
        let focused = page.followFocused
        return HStack(alignment: .center, spacing: 30) {
            ZStack {
                Circle().fill(.white.opacity(0.08))
                if page.user.face != nil {
                    BiliImage(url: page.user.face).clipShape(Circle())
                } else {
                    Image(systemName: "person.fill").font(.system(size: 50)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 124, height: 124)
            VStack(alignment: .leading, spacing: 12) {
                Text(page.user.name)
                    .font(.tv(.title2, emphasized: true))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if page.user.fans > 0 {
                    Text(page.user.videos > 0 ? "\(page.user.fansText) · \(page.user.videos) 个视频" : page.user.fansText)
                        .font(.tv(.body))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            HStack(spacing: 12) {
                Image(systemName: page.armed ? "xmark" : (page.following ? "checkmark" : "plus"))
                Text(page.armed ? "再按一次取消关注" : (page.following ? "已关注" : "关注"))
            }
            .font(.tv(.callout, emphasized: true))
            .foregroundStyle(focused && !page.armed ? .black : .white)
            .padding(.horizontal, 34)
            .frame(height: 78)
            .background {
                Capsule().fill(page.armed ? Color(hex: "#C0392B") : (focused ? Color.white : (page.following ? Color.white.opacity(0.14) : pink)))
            }
            .scaleEffect(focused ? 1.08 : 1)
            .padding(.leading, 26)
            .opacity(page.loading ? 0 : 1)
            .animation(Motion.focus, value: focused)
            .animation(Motion.focus, value: page.armed)
            .animation(Motion.focus, value: page.following)
        }
    }

    /// UP 主页的三个排序。焦点左右移到哪个，下面那排视频就换成哪个。
    private func sortBar(_ page: BilibiliStore.UpPage) -> some View {
        let active = page.sortFocused && !store.headerFocused && !store.accountFocused
        return HStack(spacing: 14) {
            ForEach(BilibiliStore.UpPage.Sort.allCases, id: \.rawValue) { sort in
                let chosen = sort == page.sort
                Text(sort.title)
                    .font(.tv(.callout, emphasized: chosen))
                    .foregroundStyle(chosen && active ? .black : .white.opacity(chosen ? 1 : 0.6))
                    .padding(.horizontal, 30)
                    .frame(height: 64)
                    .background {
                        if chosen {
                            Capsule().fill(active ? Color.white : Color.white.opacity(0.16))
                                .matchedGeometryEffect(id: "sort", in: sortSpace)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { store.tapSort(sort.rawValue) }
            }
        }
        .opacity(page.loading ? 0 : 1)
        .animation(Motion.focus, value: page.sort)
        .animation(Motion.focus, value: active)
    }

    /// 长按确认后的小菜单：出现在选中的那张卡片上，和头像菜单同一种玻璃、同一条曲线
    private var cardMenu: some View {
        let actions = store.cardMenu ?? []
        let open = store.cardMenu != nil
        let focusedColumn = store.rows.indices.contains(store.row) ? store.column(of: store.rows[store.row]) : 0
        let labels: [BilibiliStore.CardAction: (String, String)] = [.upPage: ("person.crop.circle", "UP 主主页"),
                                                                    .favorite: ("star", "收藏"),
                                                                    .watchLater: ("clock", "稍后再看")]
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                let focused = index == store.cardMenuIndex
                HStack(spacing: 18) {
                    Image(systemName: labels[action]?.0 ?? "circle").font(.system(size: 26, weight: .semibold)).frame(width: 36)
                    Text(labels[action]?.1 ?? "").font(.tv(.callout, emphasized: focused))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(focused ? .black : .white.opacity(0.8))
                .padding(.horizontal, 22)
                .frame(width: 320, height: 74)
                .contentShape(Rectangle())
                .onTapGesture { store.tapCardMenu(index) }
            }
        }
        .background(alignment: .top) {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white)
                .frame(height: 74)
                .offset(y: CGFloat(min(store.cardMenuIndex, max(0, actions.count - 1))) * 82)
                .opacity(actions.isEmpty ? 0 : 1)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.black.opacity(0.35))
            RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.16))
        }
        .shadow(color: .black.opacity(0.55), radius: 30, y: 14)
        .fixedSize()
        .scaleEffect(open ? 1 : 0.86, anchor: .topLeading)
        .opacity(open ? 1 : 0)
        .allowsHitTesting(open)
        // 选中的卡片在第一或第二个位置上；菜单压在它的左上角里面一点
        .offset(x: margin + (focusedColumn > 0 ? cardWidth + cardGap : 0) + 36, y: rowsTop + 110)
        .animation(Self.slide, value: open)
        .animation(Self.slide, value: store.cardMenuIndex)
    }

    private func hint(for item: BilibiliStore.Item) -> String {
        switch item {
        case .login: "扫码登录"
        case .refresh: "刷新"
        case .settings: "设置"
        case .logout, .confirmLogout: "退出登录"
        case .keepLogin: "取消"
        case .empty(let text): text
        case .user(let user): user.name
        case .video: ""
        }
    }

    // MARK: 下半屏：一排排卡片

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, index: index)
                    .frame(height: rowHeight, alignment: .top)
                    .opacity(index < store.row ? 0 : (index == store.row ? 1 : 0.55))
            }
        }
        .offset(y: -CGFloat(store.row) * rowHeight)
        .id(store.tab)
        .transition(.opacity)
    }

    private func rowView(_ row: BilibiliStore.Row, index: Int) -> some View {
        let focusedColumn = store.column(of: row)
        let active = index == store.row && !store.headerFocused && !store.editing && !store.accountFocused
            && store.upPage?.followFocused != true && store.upPage?.browsing != false
        // UP 主页里焦点还在排序上时，这一排的标题就是选中的那个排序，不重复写
        let titled = store.upPage?.browsing != false
        // 焦点卡片保持在第二个位置，前面露出一张，知道左边还有
        let shift = -CGFloat(max(0, focusedColumn - 1)) * (cardWidth + cardGap)
        return VStack(alignment: .leading, spacing: 26) {
            Text(row.title)
                .font(.tv(.headline, emphasized: true))
                .foregroundStyle(.white.opacity(index == store.row ? 1 : 0.7))
                .padding(.leading, margin)
                .opacity(titled ? 1 : 0)
            HStack(alignment: .top, spacing: cardGap) {
                ForEach(Array(row.items.enumerated()), id: \.offset) { column, item in
                    // 只画焦点附近的卡片，一排几十张也不卡
                    if abs(column - focusedColumn) <= 6 {
                        card(item, focused: active && column == focusedColumn)
                            .hoverLift()
                            .onTapGesture {
                                store.focus(row: index, column: column)
                                store.activate()
                            }
                            // 只留焦点前面露出的那一张；再往左的直接隐去，左边那列图标旁边不留任何残影
                            // 淡出、略微缩小，和整排滑动用同一条曲线、同样的时长：是"滑着滑着淡掉"，不是突然没了
                            .opacity(column < focusedColumn - 1 ? 0 : 1)
                            .animation(.easeInOut(duration: 0.42), value: focusedColumn)
                    } else {
                        Color.clear.frame(width: cardWidth, height: 1)
                    }
                }
            }
            .padding(.leading, margin)
            .offset(x: shift)
        }
    }

    @ViewBuilder
    private func card(_ item: BilibiliStore.Item, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottom) {
                switch item {
                case .video(let video):
                    Color.white.opacity(0.06)
                    BiliImage(url: video.cover)
                    .frame(width: cardWidth, height: cardWidth * 9 / 16)
                    if video.duration > 0 {
                        HStack {
                            Spacer()
                            Text(video.durationText)
                                .font(.system(size: 23, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(.black.opacity(0.66), in: Capsule())
                        }
                        .padding(12)
                    }
                    if let progress = video.progress, progress > 0, video.duration > 0 {
                        GeometryReader { geo in
                            Rectangle().fill(pink)
                                .frame(width: geo.size.width * min(1, CGFloat(progress) / CGFloat(video.duration)), height: 7)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                case .login: action("qrcode.viewfinder", "扫码登录")
                case .refresh: action("arrow.clockwise", "刷新")
                case .settings: action("gearshape", "设置")
                case .logout, .confirmLogout: action("rectangle.portrait.and.arrow.right", "退出登录")
                case .keepLogin: action("xmark", "取消")
                case .user(let user):
                    ZStack {
                        Color.white.opacity(0.06)
                        BiliImage(url: user.face)
                            .frame(width: 168, height: 168)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2))
                    }
                case .empty(let text):
                    ZStack {
                        Color.white.opacity(0.05)
                        VStack(spacing: 16) {
                            Image(systemName: "star").font(.system(size: 54, weight: .medium))
                            Text(text).font(.tv(.caption1))
                        }
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .frame(width: cardWidth, height: cardWidth * 9 / 16)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 5 : 1.5))
            .shadow(color: .black.opacity(focused ? 0.65 : 0), radius: 30, y: 22)
            .scaleEffect(focused ? 1.09 : 1)

            if case .video(let video) = item {
                VStack(alignment: .leading, spacing: 8) {
                    Text(video.title)
                        .font(.system(size: 27, weight: focused ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(focused ? 1 : 0.78))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(video.owner)
                        .font(.tv(.caption2))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
                .offset(y: focused ? 12 : 0)
            } else if case .user(let user) = item {
                VStack(alignment: .leading, spacing: 8) {
                    Text(user.name)
                        .font(.system(size: 27, weight: focused ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(focused ? 1 : 0.78))
                        .lineLimit(1)
                    Text(user.videos > 0 ? "\(user.fansText) · \(user.videos) 个视频" : user.fansText)
                        .font(.tv(.caption2))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
                .offset(y: focused ? 12 : 0)
            }
        }
        .zIndex(focused ? 1 : 0)
        .animation(Motion.focus, value: focused)
    }

    private func action(_ symbol: String, _ title: String) -> some View {
        ZStack {
            Color.white.opacity(0.1)
            VStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: 68, weight: .medium))
                Text(title).font(.tv(.callout, emphasized: true))
            }
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder private var status: some View {
        VStack(spacing: 22) {
            if store.loading {
                ProgressView().controlSize(.large)
                Text("正在载入…").font(.tv(.callout))
            } else if store.failed {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 72))
                Text("载入失败").font(.tv(.headline, emphasized: true))
                Text("按确认键重试").font(.tv(.body)).opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height - rowsTop)
        .offset(y: rowsTop)
    }
}

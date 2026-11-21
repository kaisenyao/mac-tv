import SwiftUI

/// 设置 › Apps › Top Shelf：有主屏顶部内容的应用一行一个（按主屏上的顺序），右边写着现在放什么，再一个"›"。
/// 选一行往里一层：一行一个选项，开着的打勾，确认勾上 / 勾掉（只能选一种的，勾跟着走），左右不动。
/// 存在哪、什么规则（只能选一种、可以选几种、"至少选择一项"）都和各应用自己设置里的"主屏幕顶部"是同一份，两边改了都一样
struct TopShelfPreferencesPanel: Equatable {
    /// 第一层：焦点在第几个应用
    var row = 0
    /// 进了哪个应用的那一层；nil 是第一层
    var app: String?
    /// 那一层：焦点在第几项
    var option = 0
    /// 勾过几次：选项存在各应用自己那里，这里变一下面板才跟着重画
    var changes = 0
    /// 确认（或点）了几次：有焦点的那一行往下一沉再弹回来
    var presses = 0
}

/// 某个应用那一层的一项
struct TopShelfOption: Equatable {
    let title: String
    let on: Bool
    /// 从这一项起是新的一组，上面一行小标题（和设置里的分组标题一样）。每一组都有：空开一段就说明下面是另一类，
    /// 得说是哪一类；只有一组的也有（选的是什么）
    var header: String?
}

extension TVController {
    func openTopShelfPreferences() { topShelfPreferences = TopShelfPreferencesPanel() }

    /// 有主屏顶部内容的应用：按主屏上的顺序，不在主屏上的排在后面
    var topShelfApps: [Service] {
        let onHome = services.filter { AppShelf.services.contains($0.id) }
        let ids = Set(onHome.map(\.id))
        return onHome + Catalog.services.filter { AppShelf.services.contains($0.id) && !ids.contains($0.id) }
    }

    /// 第一层一行右边写的：和各应用设置里"主屏幕顶部"那一行一样
    func topShelfSummary(_ app: String) -> String {
        switch app {
        case BilibiliStore.appID: BiliShelfSource.current.title
        case NeteaseStore.appID: NeteaseShelfSource.summary
        case DedaoStore.appID: DedaoShelfSource.summary
        default: YouTubeShelfSource.current.title
        }
    }

    /// 第一层（一个个应用）的小标题
    static let topShelfAppsHeader = "APPS"

    /// 只能选一种（哔哩哔哩、YouTube）：勾跟着走。网易云、得到可以选几种
    func topShelfSingleChoice(_ app: String) -> Bool {
        app == BilibiliStore.appID || app == "youtube"
    }

    /// 那一层的几项：和各应用设置里"主屏幕顶部"的选项一样、一样的顺序
    func topShelfOptions(_ app: String) -> [TopShelfOption] {
        switch app {
        case BilibiliStore.appID:
            let current = BiliShelfSource.current
            return BiliShelfSource.allCases.enumerated().map {
                TopShelfOption(title: $0.element.title, on: $0.element == current, header: $0.offset == 0 ? "内容" : nil)
            }
        case NeteaseStore.appID:
            // 两组：正在放的，和歌单、榜单
            let chosen = Set(NeteaseShelfSource.selected)
            return [TopShelfOption(title: "正在播放", on: NeteaseShelfSource.showsNowPlaying, header: "播放")]
                + NeteaseShelfSource.allCases.enumerated().map {
                    TopShelfOption(title: $0.element.title, on: chosen.contains($0.element), header: $0.offset == 0 ? "歌单" : nil)
                }
        case DedaoStore.appID:
            // 得到自己的设置里分类在"新书推荐"里面一层；这里摆在它下面，一层就够。
            // 两组各有小标题：放什么（正在播放、新书推荐），新书从哪些分类里挑（得到自己叫"分类"，网页版的"全部分类"）
            let hidden = DedaoShelfSource.hiddenCategories
            return [TopShelfOption(title: "正在播放", on: DedaoShelfSource.showsListening, header: "内容"),
                    TopShelfOption(title: "新书推荐", on: DedaoShelfSource.showsNewBooks)]
                + Self.dedaoShelfCategories.enumerated().map {
                    TopShelfOption(title: $0.element, on: !hidden.contains($0.element), header: $0.offset == 0 ? "分类" : nil)
                }
        default:
            let current = YouTubeShelfSource.current
            return YouTubeShelfSource.allCases.enumerated().map {
                TopShelfOption(title: $0.element.title, on: $0.element == current, header: $0.offset == 0 ? "CONTENT" : nil)
            }
        }
    }

    private static var dedaoShelfCategories: [String] {
        DedaoStore.shelfCategories(DedaoAPI.savedTopics() ?? []).map(\.name)
    }

    func handleTopShelfPreferences(_ command: RemoteCommand) {
        guard var panel = topShelfPreferences else { return }
        if let app = panel.app {
            switch command {
            case .back: closeTopShelfApp(); return
            case .move(.up): panel.option = max(0, panel.option - 1)
            case .move(.down): panel.option = min(topShelfOptions(app).count - 1, panel.option + 1)
            case .select:
                topShelfPreferences?.presses += 1
                toggleTopShelfOption(panel.option)
                return
            default: return   // 左右不动
            }
        } else {
            switch command {
            case .back: topShelfPreferences = nil; return
            case .move(.up): panel.row = max(0, panel.row - 1)
            case .move(.down): panel.row = min(topShelfApps.count - 1, panel.row + 1)
            case .select:
                topShelfPreferences?.presses += 1
                openTopShelfApp(panel.row)
                return
            default: return
            }
        }
        topShelfPreferences = panel
    }

    /// 进这个应用那一层：只能选一种的，焦点落在选着的那一项上
    func openTopShelfApp(_ row: Int) {
        let apps = topShelfApps
        guard topShelfPreferences != nil, apps.indices.contains(row) else { return }
        let app = apps[row].id
        topShelfPreferences?.row = row
        topShelfPreferences?.option = topShelfSingleChoice(app) ? (topShelfOptions(app).firstIndex(where: \.on) ?? 0) : 0
        topShelfPreferences?.app = app
    }

    /// 回到第一层，焦点在刚才那个应用上
    func closeTopShelfApp() {
        guard let app = topShelfPreferences?.app else { return }
        if let row = topShelfApps.firstIndex(where: { $0.id == app }) { topShelfPreferences?.row = row }
        topShelfPreferences?.app = nil
    }

    /// 确认（或鼠标点）那一层的一项：交给那个应用自己设置里用的同一个开关，规则、提示、主屏顶部重新取都一样
    func toggleTopShelfOption(_ index: Int) {
        guard let app = topShelfPreferences?.app, topShelfOptions(app).indices.contains(index) else { return }
        topShelfPreferences?.option = index
        switch app {
        case BilibiliStore.appID:
            bilibiliStore.chooseSetting(.shelf, index)
        case NeteaseStore.appID:
            neteaseStore.toggleShelf(index == 0 ? NeteaseShelfSource.nowPlayingKey : NeteaseShelfSource.allCases[index - 1].rawValue)
        case DedaoStore.appID:
            // 这次还没进过得到时它还不认识主屏（提示、主屏顶部重新取都要它）：和打开得到时一样接上
            if dedaoStore.tv == nil { dedaoStore.tv = self }
            switch index {
            case 0: dedaoStore.toggleListening()
            case 1: dedaoStore.toggleNewBooks()
            default: dedaoStore.toggleCategory(Self.dedaoShelfCategories[index - 2])
            }
        default:
            let choice = YouTubeShelfSource.allCases[index]
            if choice != YouTubeShelfSource.current {
                YouTubeShelfSource.current = choice
                appShelf.sourceChangedSoon("youtube")   // 连着换几下，停下来以后才按最后选的取一次
            }
        }
        topShelfPreferences?.changes += 1
    }
}

struct TopShelfPreferencesSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    @Namespace private var focusSpace

    /// 和设置一样大（Apple TV 的设置在 1080p 上的大小）
    private static let rowHeight = SettingsMetrics.rowHeight
    private static let spacing = SettingsMetrics.rowSpacing
    /// 组的小标题：多高、和下面那一行隔多少、和上面一组多隔多少（和设置里的分组标题一样）
    private static let headerHeight: CGFloat = 30
    private static let headerGap: CGFloat = 10
    private static let headerTop: CGFloat = 12
    /// 那一层最多露出这么高；更长的（得到的分类）跟着焦点滚，焦点尽量停在中间
    private static let window: CGFloat = 800

    var body: some View {
        let panel = tv.topShelfPreferences ?? TopShelfPreferencesPanel()
        let apps = tv.topShelfApps
        let app = panel.app.flatMap { id in apps.first { $0.id == id } }
        HStack(spacing: 0) {
            hero(caption: app == nil ? "SETTINGS" : "TOP SHELF", title: app?.name ?? "Top Shelf", app: app)
                .padding(.leading, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                // 往里一层：第一层往左让开、淡出，这一层从右边进来；返回反过来。只是一段短的位置 + 透明度
                if let app {
                    options(app.id, focused: panel.option)
                        .id(app.id)
                        .transition(AnyTransition.offset(x: 80).combined(with: .opacity))
                } else {
                    appRows(apps, focused: panel.row)
                        .transition(AnyTransition.offset(x: -80).combined(with: .opacity))
                }
            }
            .frame(width: SettingsMetrics.listWidth)
            .padding(.trailing, 100)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
    }

    /// 左边：和设置一样的大图标，下面是这一层的名字（上面一行小字是上一层）。
    /// 进了某个应用那一层，图标换成它在主屏上的那张卡片（得到的猫头鹰、哔哩哔哩的小电视……），放大到一样宽
    private func hero(caption: String, title: String, app: Service?) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(caption).font(.tv(.caption2, emphasized: true)).tracking(1.6).opacity(0.5)
                .id(caption).transition(.opacity)
            ZStack {
                if let app {
                    AppTile(service: app, focused: false, tilt: .zero)
                        .scaleEffect(1.12)   // Home's 250-pt-wide tile, as wide as the 280-pt icon box
                        .id(app.id)
                        .transition(.opacity)
                } else {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 120, weight: .regular))
                        .frame(width: 280, height: 280)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 66, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 66, style: .continuous).strokeBorder(.white.opacity(0.14)))
                        .transition(.opacity)
                }
            }
            .frame(width: 280, height: 280)
            Text(title).font(.tv(.title2, emphasized: true))
                .id(title).transition(.opacity)
        }
    }

    /// 第一层：每个应用一行，右边是现在放什么；上面一个小标题
    private func appRows(_ apps: [Service], focused: Int) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            header(TVController.topShelfAppsHeader, first: true)
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                row(focused: index == focused, focusID: "apps") {
                    Text(app.name).font(SettingsMetrics.title).lineLimit(1)
                    Spacer(minLength: 16)
                    Text(tv.topShelfSummary(app.id)).font(SettingsMetrics.value).opacity(0.55).lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.right").font(.system(size: 24, weight: .semibold)).opacity(0.4)
                } action: {
                    tv.openTopShelfApp(index)
                }
            }
        }
    }

    /// 那一层：一行一项，开着的右边打勾
    private func options(_ app: String, focused: Int) -> some View {
        let items = tv.topShelfOptions(app)
        // 每一行的上边在哪（组的小标题、组和组之间多空的），算滚到哪用
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for (index, item) in items.enumerated() {
            if item.header != nil { y += (index == 0 ? 0 : Self.headerTop) + Self.headerHeight + Self.headerGap }
            tops.append(y)
            y += Self.rowHeight + Self.spacing
        }
        let total = max(0, y - Self.spacing)
        let list = VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: Self.headerGap) {
                    if let header = item.header { self.header(header, first: index == 0) }
                    row(focused: index == focused, focusID: "options-\(app)") {
                        Text(item.title).font(SettingsMetrics.title).lineLimit(1)
                        Spacer(minLength: 16)
                        Image(systemName: "checkmark").font(.system(size: 25, weight: .bold)).opacity(item.on ? 1 : 0)
                    } action: {
                        tv.toggleTopShelfOption(index)
                    }
                    .accessibilityAddTraits(item.on ? .isSelected : [])
                }
            }
        }
        return Group {
            if total <= Self.window {
                list
            } else {
                // 放不下：焦点那一行尽量在中间，到头了就不再滚；上下露出半行的地方淡出去
                let center = tops.indices.contains(focused) ? tops[focused] + Self.rowHeight / 2 : 0
                let scroll = min(max(0, center - Self.window / 2), total - Self.window)
                list
                    .offset(y: -scroll)
                    .frame(height: Self.window, alignment: .top)
                    .mask {
                        ListFadeMask(above: scroll > 1, below: scroll < total - Self.window - 1, length: 56)
                            // 左右留出焦点那一行放大、阴影的地方
                            .padding(.horizontal, -40)
                    }
            }
        }
    }

    /// 一组的小标题：和设置里的一样
    private func header(_ text: String, first: Bool) -> some View {
        Text(text).font(.tv(.caption1, emphasized: true)).tracking(1.4).opacity(0.5)
            .frame(height: Self.headerHeight)
            .padding(.leading, 6).padding(.top, first ? 0 : Self.headerTop)
            .accessibilityAddTraits(.isHeader)
    }

    /// 和设置里的一行一样：焦点是一块白底黑字、在行之间滑的板子，稍微放大、带影子；按下去往下一沉
    private func row<Content: View>(focused: Bool, focusID: String, @ViewBuilder content: () -> Content,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) { content() }
                .padding(.horizontal, SettingsMetrics.inset)
                .frame(height: Self.rowHeight)
                .foregroundStyle(focused ? .black : .white)
                .background {
                    let shape = RoundedRectangle(cornerRadius: SettingsMetrics.corner, style: .continuous)
                    if focused {
                        shape.fill(.white).matchedGeometryEffect(id: focusID, in: focusSpace)
                    } else {
                        shape.fill(.white.opacity(0.07))
                    }
                }
                .scaleEffect(focused ? 1.03 : 1)
                .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 16, y: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDip(presses: tv.topShelfPreferences?.presses ?? 0, focused: focused))
    }
}

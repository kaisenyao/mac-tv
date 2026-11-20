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
}

/// 某个应用那一层的一项
struct TopShelfOption: Equatable {
    let title: String
    let on: Bool
    /// 这一组到这里为止，下面空开一点：网易云、得到的"正在播放"，得到的"新书推荐"（下面是它的分类）
    var groupEnd = false
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

    /// 只能选一种（哔哩哔哩、YouTube）：勾跟着走。网易云、得到可以选几种
    func topShelfSingleChoice(_ app: String) -> Bool {
        app == BilibiliStore.appID || app == "youtube"
    }

    /// 那一层的几项：和各应用设置里"主屏幕顶部"的选项一样、一样的顺序
    func topShelfOptions(_ app: String) -> [TopShelfOption] {
        switch app {
        case BilibiliStore.appID:
            let current = BiliShelfSource.current
            return BiliShelfSource.allCases.map { TopShelfOption(title: $0.title, on: $0 == current) }
        case NeteaseStore.appID:
            let chosen = Set(NeteaseShelfSource.selected)
            return [TopShelfOption(title: "正在播放", on: NeteaseShelfSource.showsNowPlaying, groupEnd: true)]
                + NeteaseShelfSource.allCases.map { TopShelfOption(title: $0.title, on: chosen.contains($0)) }
        case DedaoStore.appID:
            // 得到自己的设置里分类在"新书推荐"里面一层；这里摆在它下面，一层就够
            let hidden = DedaoShelfSource.hiddenCategories
            return [TopShelfOption(title: "正在播放", on: DedaoShelfSource.showsListening, groupEnd: true),
                    TopShelfOption(title: "新书推荐", on: DedaoShelfSource.showsNewBooks, groupEnd: true)]
                + Self.dedaoShelfCategories.map { TopShelfOption(title: $0, on: !hidden.contains($0)) }
        default:
            let current = YouTubeShelfSource.current
            return YouTubeShelfSource.allCases.map { TopShelfOption(title: $0.title, on: $0 == current) }
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
            case .select: toggleTopShelfOption(panel.option); return
            default: return   // 左右不动
            }
        } else {
            switch command {
            case .back: topShelfPreferences = nil; return
            case .move(.up): panel.row = max(0, panel.row - 1)
            case .move(.down): panel.row = min(topShelfApps.count - 1, panel.row + 1)
            case .select: openTopShelfApp(panel.row); return
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

    private static let rowHeight: CGFloat = 78
    private static let spacing: CGFloat = 10
    private static let groupGap: CGFloat = 18
    /// 那一层最多露出这么高；更长的（得到的分类）跟着焦点滚，焦点尽量停在中间
    private static let window: CGFloat = 800

    var body: some View {
        let panel = tv.topShelfPreferences ?? TopShelfPreferencesPanel()
        let apps = tv.topShelfApps
        let app = panel.app.flatMap { id in apps.first { $0.id == id } }
        HStack(spacing: 0) {
            hero(caption: app == nil ? "SETTINGS" : "TOP SHELF", title: app?.name ?? "Top Shelf")
                .frame(width: 780, alignment: .leading)
                .padding(.leading, 120)
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
            .frame(maxWidth: .infinity)
            .padding(.trailing, 120)
            .padding(.leading, 20)
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
    }

    /// 左边：和设置一样的大图标，下面是这一层的名字（上面一行小字是上一层）
    private func hero(caption: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 34) {
            Text(caption).font(.tv(.caption2, emphasized: true)).tracking(1.6).opacity(0.5)
                .id(caption).transition(.opacity)
            Image(systemName: "rectangle.topthird.inset.filled")
                .font(.system(size: 130, weight: .regular))
                .frame(width: 300, height: 300)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 72, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 72, style: .continuous).strokeBorder(.white.opacity(0.14)))
            Text(title).font(.tv(.title2, emphasized: true))
                .id(title).transition(.opacity)
        }
    }

    /// 第一层：每个应用一行，右边是现在放什么
    private func appRows(_ apps: [Service], focused: Int) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                row(focused: index == focused, focusID: "apps") {
                    Text(app.name).font(.tv(.body)).lineLimit(1)
                    Spacer(minLength: 16)
                    Text(tv.topShelfSummary(app.id)).font(.tv(.caption1)).opacity(0.55).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(0.4)
                } action: {
                    tv.openTopShelfApp(index)
                }
            }
        }
    }

    /// 那一层：一行一项，开着的右边打勾
    private func options(_ app: String, focused: Int) -> some View {
        let items = tv.topShelfOptions(app)
        // 每一行的上边在哪（组和组之间多空一点），算滚到哪用
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for item in items {
            tops.append(y)
            y += Self.rowHeight + Self.spacing + (item.groupEnd ? Self.groupGap : 0)
        }
        let total = max(0, y - Self.spacing)
        let list = VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                row(focused: index == focused, focusID: "options-\(app)") {
                    Text(item.title).font(.tv(.body)).lineLimit(1)
                    Spacer(minLength: 16)
                    Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).opacity(item.on ? 1 : 0)
                } action: {
                    tv.toggleTopShelfOption(index)
                }
                .accessibilityAddTraits(item.on ? .isSelected : [])
                .padding(.bottom, item.groupEnd ? Self.groupGap : 0)
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
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: scroll > 1 ? 56 : 0)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: scroll < total - Self.window - 1 ? 56 : 0)
                        }
                        // 左右留出焦点那一行放大、阴影的地方
                        .padding(.horizontal, -40)
                    }
            }
        }
    }

    /// 和设置里的一行一样：焦点是一块白底黑字、在行之间滑的板子，稍微放大、带影子
    private func row<Content: View>(focused: Bool, focusID: String, @ViewBuilder content: () -> Content,
                                    action: @escaping () -> Void) -> some View {
        HStack(spacing: 22) { content() }
            .padding(.horizontal, 30)
            .frame(height: Self.rowHeight)
            .foregroundStyle(focused ? .black : .white)
            .background {
                let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
                if focused {
                    shape.fill(.white).matchedGeometryEffect(id: focusID, in: focusSpace)
                } else {
                    shape.fill(.white.opacity(0.07))
                }
            }
            .scaleEffect(focused ? 1.03 : 1)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 20, y: 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

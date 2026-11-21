import SwiftUI

/// History（Safari 的 Show All History，⌘Y、"⋯"菜单里的一行）：整页，样子和开始页一样。
/// 在 Mac TV 里看过的页面（每个人一份，最多一百条，无痕标签页的不记），按天分组：Today、Yesterday、星期几、再往前是日期。
/// 每一行：网站图标、标题、网站、几点看的。最上面一个搜索框（按标题、网址筛）和 Clear History…。
/// 遥控器：上下走；确认打开（在正在看的标签页里）；按住确认是 Remove from History；返回回到打开它之前的地方。
/// 一百条以内，按需画（LazyVStack），不常驻内存：开的时候读一次，关了就扔
struct BrowserHistoryState: Equatable {
    var entries: [WebPage]
    var focus: Focus = .search
    /// 按住确认弹出的那一行的菜单（Remove from History）
    var rowMenu = false
    /// Clear History… 的那一块（焦点在哪一项上，默认 Cancel）
    var clearing: BrowserHistoryClear?
    /// 从哪个网页打开的（返回回到它）；开始页上打开的是 nil
    var returnTo: String?

    enum Focus: Equatable { case search, clear, row(Int) }
}

/// Clear History 的几种（Apple 的说法）。Cancel 在最上面、一开始在它上面（和别的问法一样）
enum BrowserHistoryClear: CaseIterable, Equatable {
    case cancel, lastHour, today, todayAndYesterday, all

    var title: String {
        switch self {
        case .lastHour: "The Last Hour"
        case .today: "Today"
        case .todayAndYesterday: "Today and Yesterday"
        case .all: "All History"
        case .cancel: "Cancel"
        }
    }

    /// 从什么时候起的清掉（nil：全部）
    func since(_ now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .today: calendar.startOfDay(for: now)
        case .todayAndYesterday: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case .all, .cancel: nil
        }
    }
}

enum BrowserHistoryList {
    /// 按标题、网址筛（不分大小写）
    static func filter(_ pages: [WebPage], _ query: String) -> [WebPage] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !words.isEmpty else { return pages }
        return pages.filter { $0.title.lowercased().contains(words) || $0.url.absoluteString.lowercased().contains(words) }
    }

    /// 一天的标题：Today、Yesterday、这一周里的星期几，再往前是日期（"November 11, 2026"）
    static func header(for day: Date, now: Date, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: day), today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        switch days {
        case ...0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return day.formatted(.dateTime.weekday(.wide))
        default: return day.formatted(.dateTime.month(.wide).day().year())
        }
    }

    /// 一行右边的时间：和 Mac TV 别的钟一样，跟着设置里的 24-Hour Time（"7:53 AM" 或 "07:53"）
    @MainActor
    static func time(_ date: Date, twentyFour: Bool, calendar: Calendar = .current) -> String {
        TimeOfDay.text(date, twentyFour: twentyFour, calendar: calendar)
    }

    /// 按天分组（新的在前），每一条带着它在整张表里的位置（焦点按位置走）
    static func sections(_ pages: [WebPage], now: Date, calendar: Calendar = .current) -> [(title: String, rows: [(index: Int, page: WebPage)])] {
        var sections: [(title: String, rows: [(index: Int, page: WebPage)])] = []
        for (index, page) in pages.enumerated() {
            let title = header(for: page.visited ?? .distantPast, now: now, calendar: calendar)
            if sections.last?.title == title { sections[sections.count - 1].rows.append((index, page)) }
            else { sections.append((title, [(index, page)])) }
        }
        return sections
    }
}

extension BrowserTabStorage {
    /// 历史记录存的地方（和 BrowserTabs.swift 里 history 读的是同一个键）
    private static let historyEditKey = "browserHistory"

    func removeHistory(_ url: URL) { writeHistory(history.filter { $0.url != url }) }

    /// since 以后看的都清掉（nil：全部）
    func clearHistory(since: Date?) {
        writeHistory(since.map { start in history.filter { ($0.visited ?? .distantPast) < start } } ?? [])
    }

    private func writeHistory(_ pages: [WebPage]) {
        if let data = try? JSONEncoder().encode(pages) { defaults.set(data, forKey: Self.historyEditKey) }
    }
}

extension BrowserStore {
    /// 筛过的（搜索框里有字时）
    var historyShown: [WebPage] { historyState.map { BrowserHistoryList.filter($0.entries, query) } ?? [] }

    /// 打开 History：网页上是先回到开始页那一层（网页收起，返回再回来）
    func openHistory() {
        guard historyState == nil else { return }
        let from = onStartPage ? nil : barCurrentID
        if !onStartPage { openStartPage(origin: .home) }
        stopEditing()
        typed("")
        withAnimation(Motion.appear) {
            historyState = BrowserHistoryState(entries: profileStorage.history, returnTo: from)
        }
    }

    /// 返回：回到打开它之前的地方（网页、或者开始页）
    func closeHistory() {
        guard let state = historyState else { return }
        stopEditing()
        typed("")
        withAnimation(Motion.appear) { historyState = nil }
        if let id = state.returnTo, let tab = tabs.first(where: { $0.id == id }) { open(tab) }
    }

    private func setHistoryFocus(_ focus: BrowserHistoryState.Focus) {
        withAnimation(Motion.focus) { historyState?.focus = focus }
    }

    /// History 开着时的遥控器
    func handleHistory(_ command: RemoteCommand) {
        guard var state = historyState else { return }
        // Clear History… 的那一块：上下选，确认，返回是 Cancel
        if let choice = state.clearing {
            let all = BrowserHistoryClear.allCases, index = all.firstIndex(of: choice) ?? 0
            switch command {
            case .move(.up): if index > 0 { withAnimation(Motion.focus) { historyState?.clearing = all[index - 1] } }
            case .move(.down): if index + 1 < all.count { withAnimation(Motion.focus) { historyState?.clearing = all[index + 1] } }
            case .select: clearHistory(choice)
            case .back: withAnimation(Motion.appear) { historyState?.clearing = nil }
            default: break
            }
            return
        }
        // 一行的菜单：确认就是 Remove from History
        if state.rowMenu {
            switch command {
            case .select: if case .row(let index) = state.focus, historyShown.indices.contains(index) { removeFromHistory(historyShown[index]) }
            case .back: withAnimation(Motion.appear) { historyState?.rowMenu = false }
            default: break
            }
            return
        }
        // 搜索框里打字：和地址栏一样（键盘的字直接进输入框，手机的走这里）
        if editing {
            switch command {
            case .text(let text): typed(query + text)
            case .deleteBackward: if !query.isEmpty { typed(String(query.dropLast())) }
            case .select, .move(.down):
                stopEditing()
                if !historyShown.isEmpty { setHistoryFocus(.row(0)) }
            case .back: stopEditing()
            default: break
            }
            return
        }
        let count = historyShown.count
        switch command {
        case .move(.up):
            if case .row(let index) = state.focus { setHistoryFocus(index == 0 ? .search : .row(index - 1)) }
        case .move(.down):
            switch state.focus {
            case .search, .clear: if count > 0 { setHistoryFocus(.row(0)) }
            case .row(let index): if index + 1 < count { setHistoryFocus(.row(index + 1)) }
            }
        case .move(.right): if state.focus == .search { setHistoryFocus(.clear) }
        case .move(.left): if state.focus == .clear { setHistoryFocus(.search) }
        case .select:
            switch state.focus {
            case .search: startEditing()
            case .clear: withAnimation(Motion.appear) { historyState?.clearing = .cancel }
            case .row(let index): if historyShown.indices.contains(index) { openFromHistory(historyShown[index]) }
            }
        case .back:
            if case .row = state.focus { setHistoryFocus(.search) } else { closeHistory() }
        default: break
        }
        state = historyState ?? state
        _ = state
    }

    func historyCanMove(_ direction: RemoteCommand.Direction) -> Bool {
        guard let state = historyState else { return false }
        if state.clearing != nil || state.rowMenu { return direction == .up || direction == .down }
        switch (state.focus, direction) {
        case (.row(let index), .down): return index + 1 < historyShown.count
        case (.row, .up): return true
        case (.search, .right), (.clear, .left): return true
        case (_, .down): return !historyShown.isEmpty
        default: return false
        }
    }

    /// 按住确认：这一行的菜单（Remove from History）。不在一行上没有
    func openHistoryRowMenu() -> Bool {
        guard let state = historyState, state.clearing == nil, !state.rowMenu, case .row = state.focus else { return false }
        withAnimation(Motion.appear) { historyState?.rowMenu = true }
        return true
    }

    func closeHistoryRowMenu() -> Bool {
        guard historyState?.rowMenu == true else { return false }
        withAnimation(Motion.appear) { historyState?.rowMenu = false }
        return true
    }

    /// 在正在看的标签页里打开（开始页的空白标签页、或者打开 History 之前看着的那个网页）
    func openFromHistory(_ page: WebPage) {
        guard let state = historyState else { return }
        withAnimation(Motion.appear) { historyState = nil }
        typed("")
        if let id = state.returnTo, let tab = tabs.first(where: { $0.id == id }) { show(tab, loading: page.url) } else { open(page.url) }
    }

    func removeFromHistory(_ page: WebPage) {
        profileStorage.removeHistory(page.url)
        reloadHistory(keepingRowNear: page)
    }

    func clearHistory(_ choice: BrowserHistoryClear) {
        if choice != .cancel { profileStorage.clearHistory(since: choice.since(Date())) }
        withAnimation(Motion.appear) { historyState?.clearing = nil }
        if choice != .cancel { reloadHistory(keepingRowNear: nil) }
    }

    private func reloadHistory(keepingRowNear page: WebPage?) {
        guard var state = historyState else { return }
        let old = historyShown.firstIndex { $0 == page }
        state.entries = profileStorage.history
        state.rowMenu = false
        let count = BrowserHistoryList.filter(state.entries, query).count
        if case .row = state.focus {
            state.focus = count == 0 ? .search : .row(min(old ?? 0, count - 1))
        }
        withAnimation(Motion.focus) { historyState = state }
        rebuildRows()   // 开始页的 Recently Visited 跟着变
    }

    /// 鼠标点了一行：选中它、打开
    func tapHistoryRow(_ index: Int) {
        guard historyState != nil, historyShown.indices.contains(index) else { return }
        stopEditing()
        setHistoryFocus(.row(index))
        openFromHistory(historyShown[index])
    }

    func tapHistoryClear() {
        guard historyState != nil else { return }
        stopEditing()
        setHistoryFocus(.clear)
        withAnimation(Motion.appear) { historyState?.clearing = .cancel }
    }

    var historyKey: String {
        guard let state = historyState else { return "" }
        return "history-\(state.focus)-\(state.rowMenu)-\(String(describing: state.clearing))-\(state.entries.count)"
    }
}

/// History 那一页
struct BrowserHistoryView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var preferences = Preferences.shared
    @Environment(\.canvasSize) private var canvas
    @FocusState private var typing: Bool

    private let margin: CGFloat = 160

    var body: some View {
        let state = store.historyState
        let pages = store.historyShown
        let sections = BrowserHistoryList.sections(pages, now: Date())
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: "#1C1F27"), Color(hex: "#0B0C10")], startPoint: .top, endPoint: .bottom)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                        Color.clear.frame(height: 250)
                        if pages.isEmpty {
                            Text(store.query.isEmpty ? "No History" : "No Results")
                                .font(.tv(.title3)).foregroundStyle(.white.opacity(0.5))
                                .frame(maxWidth: .infinity).padding(.top, 120)
                        }
                        ForEach(sections, id: \.title) { section in
                            Text(section.title)
                                .font(.tv(.callout, emphasized: true))
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.top, 28).padding(.bottom, 6).padding(.leading, 28)
                            ForEach(section.rows, id: \.page.id) { row in
                                HistoryRow(page: row.page, focused: state?.focus == .row(row.index) && state?.clearing == nil,
                                           twentyFour: preferences.twentyFourHourTime)
                                    .id(row.index)
                                    .onTapGesture { store.tapHistoryRow(row.index) }
                            }
                        }
                        Color.clear.frame(height: 160)
                    }
                    .padding(.horizontal, margin)
                }
                .scrollDisabled(true)
                .onChange(of: state?.focus) { _, focus in
                    if case .row(let index)? = focus { withAnimation(Motion.navigate) { proxy.scrollTo(index, anchor: .center) } }
                    else { withAnimation(Motion.navigate) { proxy.scrollTo(0, anchor: .bottom) } }
                }
            }
            header(state)
            if state?.rowMenu == true { rowMenu }
            if let choice = state?.clearing { clearPanel(choice) }
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)
        .onChange(of: store.editing) { _, editing in typing = editing }
        .onChange(of: store.focusRequest) { _, _ in if store.editing { typing = true } }
    }

    /// 标题、搜索框、Clear History…（盖在列表上面，往下滚时列表从它底下过去，渐隐）
    private func header(_ state: BrowserHistoryState?) -> some View {
        let searchLit = state?.focus == .search && state?.clearing == nil && !store.editing
        let clearLit = state?.focus == .clear && state?.clearing == nil
        let text = Binding(get: { store.query }, set: { store.typed($0) })
        return VStack(alignment: .leading, spacing: 28) {
            Text("History").font(.tv(.title1, emphasized: true)).foregroundStyle(.white)
            HStack(spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "magnifyingglass").font(.tv(.body, emphasized: true))
                    if store.editing {
                        TextField("Search History", text: text)
                            .textFieldStyle(.plain)
                            .focused($typing)
                            .onSubmit { store.handle(.select) }
                            .onAppear { typing = true }
                    } else {
                        Text(store.query.isEmpty ? "Search History" : store.query)
                            .foregroundStyle(searchLit ? Color.black.opacity(0.55) : .white.opacity(0.55))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .font(.tv(.body))
                .foregroundStyle(searchLit ? .black : .white.opacity(0.85))
                .padding(.horizontal, 32)
                .frame(width: 900, height: 76)
                .background {
                    Capsule().fill(searchLit ? Color.white : .white.opacity(store.editing ? 0.16 : 0.1))
                        .shadow(color: .black.opacity(searchLit ? 0.45 : 0), radius: 21, y: 12)
                    PillOutline().strokeBorder(store.editing ? Color(hex: "#4A8FE7") : .white.opacity(searchLit ? 0 : 0.14),
                                               lineWidth: store.editing ? 3 : 1)
                }
                .scaleEffect(searchLit ? 1.04 : 1)
                .contentShape(Capsule())
                .onTapGesture { store.startEditing() }
                Text("Clear History…")
                    .font(.tv(.callout, emphasized: true))
                    .foregroundStyle(clearLit ? .black : .white)
                    .padding(.horizontal, 36)
                    .frame(height: 76)
                    .background(Capsule().fill(clearLit ? Color.white : .white.opacity(0.12)))
                    .browserLift(focused: clearLit, in: Capsule(), scale: 1.08, shadow: 14)
                    .contentShape(Capsule())
                    .onTapGesture { store.tapHistoryClear() }
            }
            .animation(Motion.focus, value: searchLit)
            .animation(Motion.focus, value: clearLit)
        }
        .padding(.top, 70)
        .padding(.horizontal, margin + 28)
        .frame(width: canvas.width, height: 250, alignment: .topLeading)
        .background(LinearGradient(colors: [Color(hex: "#1C1F27"), Color(hex: "#1C1F27").opacity(0)], startPoint: .center, endPoint: .bottom))
    }

    private var rowMenu: some View {
        BrowserSheetPanel(title: nil) {
            BrowserSheetRow(title: "Remove from History", symbol: "trash", lit: true) {
                if case .row(let index)? = store.historyState?.focus, store.historyShown.indices.contains(index) {
                    store.removeFromHistory(store.historyShown[index])
                }
            }
        }
    }

    private func clearPanel(_ choice: BrowserHistoryClear) -> some View {
        BrowserSheetPanel(title: "Clear History") {
            ForEach(BrowserHistoryClear.allCases, id: \.self) { item in
                BrowserSheetRow(title: item.title, symbol: item == .cancel ? nil : "clock.arrow.circlepath", lit: item == choice) {
                    store.clearHistory(item)
                }
            }
        }
    }
}

/// History 的一行：网站图标、标题、网站、几点
private struct HistoryRow: View {
    let page: WebPage
    let focused: Bool
    let twentyFour: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return HStack(spacing: 22) {
            SiteTile(page: page, size: 44, corner: 10, minPixels: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(page.name).font(.tv(.callout)).lineLimit(1)
                Text(page.host).font(.tv(.caption2)).opacity(0.55).lineLimit(1)
            }
            Spacer(minLength: 20)
            if let visited = page.visited {
                Text(BrowserHistoryList.time(visited, twentyFour: twentyFour)).font(.tv(.caption1)).opacity(0.55)
            }
        }
        .foregroundStyle(focused ? .black : .white)
        .padding(.horizontal, 28)
        .frame(height: 92)
        .background(shape.fill(focused ? Color.white : .white.opacity(0.05)))
        .browserLift(focused: focused, in: shape, scale: 1.02, shadow: 16)
        .animation(Motion.focus, value: focused)
        .contentShape(shape)
    }
}

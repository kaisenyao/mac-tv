import AppKit
import SwiftUI

/// 开始页的个人收藏（Favorites）是 Web 自己的一份，每个人一份，存在他自己的设置里。
/// 第一个人第一次读到 Safari 时，把 Safari 的个人收藏抄一份过来（看起来什么都没变），以后增、删、改名、改网址都只改这一份，
/// 从来不往 Safari 里写。别的人从空的开始。常去网站、最近浏览、阅读列表还是 Safari 的记录（只读，只给第一个人看）。
///
/// 按住确认（鼠标按住、右键也一样）弹出那一个的菜单：
/// - 个人收藏：Open in New Tab、Rename、Edit Address…、Delete（先问，焦点在 Cancel 上）
/// - 别的几排：Open in New Tab、Add to Favorites（已经是了就是 Remove from Favorites）
/// 网页上"⋯"里也有 Add to Favorites / Remove from Favorites。
/// Rename、Edit Address… 就地变成一个输入框（和地址栏一样的样子、一样的打字方式）
struct BrowserItemMenu: Equatable {
    var page: WebPage
    /// 是个人收藏那一排里的
    var inFavorites: Bool
    var actions: [Action]
    var focus = 0
    var stage: Stage = .menu

    enum Action: Equatable {
        case openInNewTab, rename, editAddress, delete, addToFavorites, removeFromFavorites

        var title: String {
            switch self {
            case .openInNewTab: "Open in New Tab"
            case .rename: "Rename"
            case .editAddress: "Edit Address…"
            case .delete: "Delete"
            case .addToFavorites: "Add to Favorites"
            case .removeFromFavorites: "Remove from Favorites"
            }
        }

        var symbol: String {
            switch self {
            case .openInNewTab: "plus.square.on.square"
            case .rename: "pencil"
            case .editAddress: "link"
            case .delete: "trash"
            case .addToFavorites: "star"
            case .removeFromFavorites: "star.slash"
            }
        }
    }

    enum Stage: Equatable {
        case menu, rename, editAddress
        /// Delete、Remove from Favorites 先问（取消收藏都要先问）：yes 是焦点在 Delete / Remove 上，一开始在 Cancel 上
        case confirm(Action, yes: Bool)
    }
}

extension BrowserTabStorage {
    /// Web 自己的个人收藏（和别的设置存在一起，每个人一份）。nil：还没有过（第一个人等着从 Safari 抄一份）
    private static let favoritesKey = "browserFavorites"

    var favorites: [WebPage]? {
        defaults.data(forKey: Self.favoritesKey).flatMap { try? JSONDecoder().decode([WebPage].self, from: $0) }
    }

    func setFavorites(_ pages: [WebPage]) {
        if let data = try? JSONEncoder().encode(pages) { defaults.set(data, forKey: Self.favoritesKey) }
    }
}

extension BrowserStore {
    /// 开始页上个人收藏那一排：自己的那一份；还没有过时（第一个人）是 Safari 的
    var favoritePages: [WebPage] { profileStorage.favorites ?? safariFavorites }

    /// 第一个人第一次读到 Safari：把 Safari 的个人收藏抄一份（只抄一次，以后不再跟着 Safari 变）
    func seedFavorites(from safari: SafariLibrary.Snapshot) {
        guard showsSafari, safari.access == .ok, profileStorage.favorites == nil else { return }
        profileStorage.setFavorites(safari.favorites)
    }

    /// 改个人收藏：还没有自己的一份时先从现在看到的那一排（Safari 的）抄过来再改，不会一改就丢了 Safari 的那些
    func changeFavorites(_ change: (inout [WebPage]) -> Void) {
        var pages = favoritePages
        change(&pages)
        profileStorage.setFavorites(pages)
        withAnimation(Motion.navigate) { rebuildRows() }
    }

    /// 是不是同一个收藏：比 scheme、网站、路径（不分大小写，www. 和末尾的 / 不算）
    nonisolated static func sameAddress(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            var host = (url.host ?? "").lowercased()
            if host.hasPrefix("www.") { host.removeFirst(4) }
            var path = url.path
            while path.hasSuffix("/") { path.removeLast() }
            return "\((url.scheme ?? "").lowercased())://\(host)\(path)"
        }
        return key(a) == key(b)
    }

    func isFavorite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return favoritePages.contains { Self.sameAddress($0.url, url) }
    }

    func addFavorite(_ page: WebPage?) {
        guard let page, !isFavorite(page.url) else { return }
        changeFavorites { $0.append(WebPage(url: page.url, title: page.name)) }
    }

    func removeFavorite(_ url: URL?) {
        guard let url else { return }
        changeFavorites { $0.removeAll { Self.sameAddress($0.url, url) } }
    }

    /// 网页上"⋯"里的 Remove from Favorites：先问（焦点在 Cancel 上）
    func confirmRemoveFavorite(_ page: WebPage?) {
        // 问的时候用开始页上那个收藏的名字（网页的标题可能很长）
        guard let page, let favorite = favoritePages.first(where: { Self.sameAddress($0.url, page.url) }) else { return }
        withAnimation(Motion.appear) {
            itemMenu = BrowserItemMenu(page: favorite, inFavorites: false, actions: [], stage: .confirm(.removeFromFavorites, yes: false))
        }
    }

    // MARK: 按住确认的菜单

    var itemMenuKey: String {
        guard let menu = itemMenu else { return "" }
        return "item-\(menu.focus)-\(menu.stage)"
    }

    /// 按住确认（或者鼠标按住、右键）开始页上的一个网站：它的菜单。地址栏、说明那一行上没有
    @discardableResult
    func openItemMenu() -> Bool {
        guard itemMenu == nil, historyState == nil, barFocus == nil, !editing, let page = focusedPage,
              case .item(let row, _) = focus, rows.indices.contains(row) else { return false }
        let inFavorites = rows[row].id == "favorites"
        let actions: [BrowserItemMenu.Action] = inFavorites
            ? [.openInNewTab, .rename, .editAddress, .delete]
            : [.openInNewTab, isFavorite(page.url) ? .removeFromFavorites : .addToFavorites]
        withAnimation(Motion.appear) { itemMenu = BrowserItemMenu(page: page, inFavorites: inFavorites, actions: actions) }
        return true
    }

    func closeItemMenu() -> Bool {
        guard itemMenu != nil else { return false }
        if editing { stopEditing(); typed("") }
        withAnimation(Motion.appear) { itemMenu = nil }
        return true
    }

    /// 鼠标按住、右键一个网站：先选中它，再弹出菜单
    func openItemMenu(row: Int, column: Int) {
        guard itemMenu == nil, historyState == nil else { return }
        focus(row: row, column: column)
        openItemMenu()
    }

    func handleItemMenu(_ command: RemoteCommand) {
        guard let menu = itemMenu else { return }
        switch menu.stage {
        case .menu:
            switch command {
            case .move(.up): if menu.focus > 0 { withAnimation(Motion.focus) { itemMenu?.focus -= 1 } }
            case .move(.down): if menu.focus + 1 < menu.actions.count { withAnimation(Motion.focus) { itemMenu?.focus += 1 } }
            case .select: perform(menu.actions[menu.focus])
            case .back: _ = closeItemMenu()
            default: break
            }
        case .rename, .editAddress:
            switch command {
            case .text(let text): typed((replaceQuery ? "" : query) + text)
            case .deleteBackward: typed(replaceQuery ? "" : String(query.dropLast()))
            case .select: commitItemText()
            case .back: _ = closeItemMenu()
            default: break
            }
        case .confirm(let action, let yes):
            switch command {
            // 和 Arrange Apps 的一样：Cancel 在上（一开始在它上面），红的在下；上、左回 Cancel，下、右到红的
            case .move(let direction):
                let next = direction == .down || direction == .right
                if next != yes { withAnimation(Motion.focus) { itemMenu?.stage = .confirm(action, yes: next) } }
            case .select:
                if yes { removeFavorite(menu.page.url) }
                _ = closeItemMenu()
            case .back: _ = closeItemMenu()
            default: break
            }
        }
    }

    /// 菜单里的一项（遥控器的确认、鼠标点）
    func perform(_ action: BrowserItemMenu.Action) {
        guard let menu = itemMenu else { return }
        if let index = menu.actions.firstIndex(of: action) { itemMenu?.focus = index }
        switch action {
        case .openInNewTab:
            _ = closeItemMenu()
            newTab(menu.page.url)
        case .rename:
            withAnimation(Motion.focus) { itemMenu?.stage = .rename }
            startTextEntry(menu.page.name)
        case .editAddress:
            withAnimation(Motion.focus) { itemMenu?.stage = .editAddress }
            startTextEntry(menu.page.url.absoluteString)
        case .delete, .removeFromFavorites:
            withAnimation(Motion.focus) { itemMenu?.stage = .confirm(action, yes: false) }   // 先问，焦点在 Cancel 上
        case .addToFavorites:   // 加不用问
            _ = closeItemMenu()
            addFavorite(menu.page)
        }
    }

    /// 改名、改网址：确认。网址要像个网址（不然留在输入框里接着改）；名字空着就是网站名
    func commitItemText() {
        guard let menu = itemMenu else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch menu.stage {
        case .rename:
            changeFavorites { pages in
                if let index = pages.firstIndex(where: { Self.sameAddress($0.url, menu.page.url) }) { pages[index].title = text }
            }
        case .editAddress:
            guard let url = Self.address(text) else { return }
            changeFavorites { pages in
                if let index = pages.firstIndex(where: { Self.sameAddress($0.url, menu.page.url) }) { pages[index].url = url }
            }
        default: return
        }
        _ = closeItemMenu()
    }

    /// 弹出菜单的那一块：菜单、确认删除时、打字时
    var itemMenuTitle: String {
        guard let menu = itemMenu else { return "" }
        switch menu.stage {
        case .menu: return menu.page.name
        case .rename: return "Rename"
        case .editAddress: return "Edit Address"
        case .confirm(.delete, _): return "Delete “\(menu.page.name)”?"
        case .confirm: return "Remove “\(menu.page.name)” from Favorites?"
        }
    }
}

/// 开始页上那一个的菜单（盖在开始页上的一块，和"⋯"菜单一个样子）
struct BrowserItemMenuView: View {
    @ObservedObject var store: BrowserStore
    @FocusState private var typing: Bool

    var body: some View {
        if let menu = store.itemMenu {
            BrowserSheetPanel(title: store.itemMenuTitle) {
                switch menu.stage {
                case .menu:
                    ForEach(Array(menu.actions.enumerated()), id: \.offset) { index, action in
                        BrowserSheetRow(title: action.title, symbol: action.symbol, lit: index == menu.focus,
                                        destructive: action == .delete) { store.perform(action) }
                    }
                case .rename, .editAddress:
                    field(placeholder: menu.stage == .rename ? menu.page.host : "Address")
                case .confirm(let action, let yes):
                    // Cancel 在上、焦点在它上面，红的在下（和 Arrange Apps、Quit 的问法一样）
                    BrowserSheetRow(title: "Cancel", symbol: nil, lit: !yes) { _ = store.closeItemMenu() }
                    BrowserSheetRow(title: action == .delete ? "Delete" : "Remove", symbol: action.symbol, lit: yes, destructive: true) {
                        store.removeFavorite(menu.page.url)
                        _ = store.closeItemMenu()
                    }
                }
            }
            .onChange(of: store.focusRequest) { _, _ in if store.editing { typing = true } }
        }
    }

    /// 和地址栏一样的输入框：深色、蓝色的框，字整个选中，一打字就换掉
    private func field(placeholder: String) -> some View {
        let text = Binding(get: { store.query }, set: { store.typed($0) })
        return TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.45)))
            .textFieldStyle(.plain)
            .font(.tv(.callout))
            .foregroundStyle(.white)
            .focused($typing)
            .onSubmit { store.commitItemText() }
            .onAppear {
                typing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
            }
            .padding(.horizontal, 24)
            .frame(height: 72)
            .background(Capsule(style: .continuous).fill(Color(hex: "#202126")))
            .overlay(PillOutline().strokeBorder(Color(hex: "#4A8FE7"), lineWidth: 3))
    }
}

/// 盖在开始页、History 上的一块（tvOS 菜单的样子，和"⋯"菜单一样）：后面暗下去
struct BrowserSheetPanel<Rows: View>: View {
    let title: String?
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        // A Sheet (DesignSystem/Layers): the frosted backdrop, and a plain panel on it, as Add App's.
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        ZStack {
            SheetBackdrop()
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title).font(.tv(.headline, emphasized: true)).foregroundStyle(.white).lineLimit(2)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                }
                rows()
            }
            .padding(12)
            .frame(width: 640)
            .tvPanel(in: shape)
        }
        .environment(\.colorScheme, .dark)
        .transition(.opacity)
    }
}

/// 那一块里的一行：选中的变白、浮起来（和"⋯"菜单的一行一样）。Delete 是红字
struct BrowserSheetRow: View {
    let title: String
    let symbol: String?
    let lit: Bool
    var destructive = false
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 20) {
            if let symbol { Image(systemName: symbol).font(.tv(.caption1, emphasized: true)).frame(width: 36) }
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.tv(.callout))
        .foregroundStyle(destructive ? Color.destructive : lit ? .black : .white.opacity(0.9))
        .padding(.horizontal, 24)
        .frame(height: 72)
        .background(shape.fill(lit ? Color.white : .clear))
        .browserLift(focused: lit, in: shape, scale: 1.03, shadow: 12)
        .animation(Motion.focus, value: lit)
        .contentShape(shape)
        .onTapGesture(perform: action)
    }
}

extension View {
    /// 鼠标右键点它（按住确认的那个菜单）。只接右键：左键、悬停照常给下面的
    func onRightClick(_ action: @escaping () -> Void) -> some View {
        overlay(RightClickCatcher(action: action))
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(action: action) }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        /// 只在右键按下的那一下接住，别的时候（左键、悬停）当它不在
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action() }
    }
}

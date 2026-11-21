import SwiftUI

/// 浏览器的开始页（见 BrowserStore）。样子照 Safari 的开始页，放大到电视上：最上面是和网页上一样的标签栏，
/// 下面一条地址栏，再下面个人收藏、常去网站是一个个大方块（网站自己的图标），最近浏览、阅读列表是卡片（标题、网站、多久以前）。
/// 选中的那一个和 tvOS 一样浮起来。焦点下到那几排里时标签栏收上去，地址栏和那几排跟着上移（一整块一起挪，一个位移动画）。
/// 一排放不下、被屏幕边截掉的那一头淡出去（每排一张静态的渐变遮罩，见 EdgeFade）。
/// 无痕浏览时，地址栏是深紫色的（标签也是紫色的，不另外写字），下面只有个人收藏。
/// 网站图标只向那个网站自己要，不经过别人（不把你去过哪些网站告诉第三方，见 SiteIcons）。
/// 浏览器是系统的界面，字都是英文（跟系统语言走）
struct BrowserRoot: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        TVCanvas { BrowserScreen(store: store) }.ignoresSafeArea()
    }
}

struct BrowserScreen: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.canvasSize) private var canvas
    @FocusState private var typing: Bool

    // 网页默认 150%（BrowserZoomLevel.medium）。
    // 一排正好放下整数个（7 个方块、4 张卡片，左右各留 margin），再往右露出下一个的一点，淡出去
    private let margin: CGFloat = 96
    private let rowHeight: CGFloat = 352
    private let tile: CGFloat = 192
    private let tileCorner: CGFloat = 38
    /// 方块下面的名字比方块宽一点（露出方块两边，不占一排的位置，方块和标题左边对齐）
    private let tileLabel: CGFloat = 216
    private let card = CGSize(width: 402, height: 206)
    /// 地址栏：标签栏下面空出一截再开始，一进来不挤；第一屏正好放下两排
    private let fieldTop: CGFloat = BrowserTopBar.height + 80
    private let fieldHeight: CGFloat = 84
    private var rowsTop: CGFloat { fieldTop + fieldHeight + 84 }
    /// 焦点在那几排里时整块往上挪多少：标签栏整个藏到屏幕上面
    private let collapse: CGFloat = BrowserTopBar.height

    var body: some View {
        // History（⌘Y、"⋯"里的 Show All History）开着时整页换成它
        if store.historyState != nil {
            BrowserHistoryView(store: store).transition(.opacity)
        } else {
            startPage
        }
    }

    private var startPage: some View {
        ZStack(alignment: .topLeading) {
            background
            ZStack(alignment: .topLeading) {
                rowsView
                    .frame(width: canvas.width, height: canvas.height - rowsTop + collapse, alignment: .topLeading)
                    .clipped()
                    .offset(y: rowsTop)
                addressBar
                    .frame(width: canvas.width)
                    .padding(.top, fieldTop)
                // 开始页上标签栏不垫底色：开始页的底色一直到屏幕顶上
                BrowserTopBar(store: store, surface: .clear, hoverable: store.startBarSettled)
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            // 标签栏收起、出来：整块一起上下挪（BrowserStore 里那一下是 Motion.navigate）
            .offset(y: store.startBarShown ? 0 : -collapse)
            if store.menu != nil {
                DimBackdrop(close: { _ = store.closeHoldMenu() })
                    .transition(.opacity)
                BrowserMenu(store: store)
                    .padding(.top, BrowserTopBar.height + 12)
                    .padding(.trailing, 28)
                    .frame(width: canvas.width, alignment: .trailing)
                    .transition(.growing(from: .topTrailing))
            }
            // 按住确认一个网站：它的菜单（个人收藏的 Rename、Edit Address… 也在这里打字）
            if store.itemMenu != nil {
                BrowserItemMenuView(store: store).frame(width: canvas.width, height: canvas.height)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .background(Color.black)
        .animation(Motion.appear, value: store.itemMenu != nil)
        // 地址栏（不是标签栏上改地址的那个）拿着键盘
        .onChange(of: store.editing) { _, editing in typing = editing && !store.editingInBar && store.itemMenu == nil }
        .onChange(of: store.focusRequest) { _, _ in if store.editing && !store.editingInBar && store.itemMenu == nil { typing = true } }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#1C1F27"), Color(hex: "#0B0C10")], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: "#2A6CF0").opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: -0.1),
                           startRadius: 0, endRadius: canvas.width * 0.6)
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    // MARK: 地址栏

    private var addressBar: some View {
        let focused = store.focus == .field && store.barFocus == nil   // 焦点在上面的标签栏里时它不亮
        let editingHere = store.editing && !store.editingInBar && store.itemMenu == nil
        let lit = focused || editingHere
        let text = Binding(get: { store.query }, set: { store.typed($0) })
        return HStack(spacing: 19) {
            Image(systemName: "magnifyingglass").font(.tv(.body, emphasized: true))
            if editingHere {
                TextField("Search or enter website name", text: text)
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .onSubmit { store.submit() }
                    .onAppear {
                        typing = true
                        // 从工具栏的地址进来，地址栏里是这一页的网址：整个选中，键盘一打字就换掉
                        if store.replaceQuery {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                            }
                        }
                    }
            } else {
                Text(store.query.isEmpty || store.editingInBar || store.itemMenu != nil ? "Search or enter website name" : store.query)
                    .foregroundStyle(lit ? Color.black.opacity(0.55) : .white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .font(.tv(.body))
        .foregroundStyle(lit ? .black : .white.opacity(0.85))
        .padding(.horizontal, 35)
        .frame(width: 1050, height: fieldHeight)
        .background {
            // 影子只投在胶囊上，不投在字上（字周围不糊一圈）
            Capsule().fill(lit ? Color.white : store.privateBrowsing ? BrowserTopBar.privateTint.opacity(0.35) : .white.opacity(0.1))
                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 21, y: 12)
            PillOutline().strokeBorder(.white.opacity(lit ? 0 : 0.14))   // 不用 Capsule 描：两头会多出竖线（见 PillOutline）
        }
        .scaleEffect(focused && !editingHere ? 1.04 : 1)
        .environment(\.colorScheme, lit ? .light : .dark)
        .animation(Motion.focus, value: focused)
        .contentShape(Capsule())
        .onTapGesture { store.startEditing() }
    }

    // MARK: 下面几排

    private var focusedRow: Int? {
        if case .item(let row, _) = store.focus { return row }
        return nil
    }

    private var rowsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, index: index)
                    .frame(height: rowHeight, alignment: .top)
                    .opacity(focusedRow.map { index < $0 ? 0 : (index == $0 ? 1 : 0.6) } ?? (index == 0 ? 1 : 0.6))
            }
        }
        .offset(y: -CGFloat(focusedRow ?? 0) * rowHeight)
        .animation(Motion.navigate, value: focusedRow)
    }

    /// 一排里一项占多宽，按它算挪多少、哪头被截掉
    private func width(of style: BrowserStore.Row.Style) -> CGFloat {
        switch style {
        case .tiles: tile
        case .cards, .notice: card.width
        }
    }

    /// 一排里两项之间：7 个方块、4 张卡片正好占满左右 margin 之间
    private func gap(of style: BrowserStore.Row.Style) -> CGFloat {
        style == .tiles ? 64 : 40
    }

    private func rowView(_ row: BrowserStore.Row, index: Int) -> some View {
        let column = store.column(of: index)
        let active = focusedRow == index && !store.editing
        let width = width(of: row.style), gap = gap(of: row.style)
        // 选中的那一个停在第二个位置，前面露出一个；再前面的被左边截掉一截
        let shift = CGFloat(max(0, column - 1)) * (width + gap)
        let end = margin + CGFloat(row.pages.count) * (width + gap) - gap - shift
        return VStack(alignment: .leading, spacing: 24) {
            Text(row.title)
                .font(.tv(.callout, emphasized: true))
                .foregroundStyle(.white.opacity(focusedRow == index ? 1 : 0.7))
                .padding(.leading, margin)
            if row.style == .notice {
                permissionCard(focused: active)
                    .padding(.leading, margin)
                    .onTapGesture { store.focus(row: index, column: 0); store.handle(.select) }
            } else {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(row.pages.enumerated()), id: \.offset) { position, page in
                        item(position: position, column: column, width: width, row: index) {
                            if row.style == .tiles { tileView(page, focused: active && position == column) }
                            else { cardView(page, focused: active && position == column) }
                        }
                    }
                }
                .padding(.leading, margin)
                .offset(x: -shift)
                .frame(width: canvas.width, alignment: .leading)
                // 被屏幕边截掉的那一头淡出去，只在真的截掉了东西的那一边；上下多留出来，选中的放大和影子不被切
                .edgeFade(leading: column >= 2, trailing: end > canvas.width, width: margin, overflow: 60)
                .animation(Motion.focus, value: column)
            }
        }
    }

    /// 一排里的一个：离选中的远的只占个位置不画
    @ViewBuilder
    private func item<Content: View>(position: Int, column: Int, width: CGFloat, row: Int,
                                     @ViewBuilder content: () -> Content) -> some View {
        if abs(position - column) <= 8 {
            content()
                .contentShape(Rectangle())
                .onTapGesture { store.focus(row: row, column: position); store.handle(.select) }
                // 鼠标按住、右键：和遥控器按住确认一样，那一个的菜单
                .onLongPressGesture(minimumDuration: 0.5) { store.openItemMenu(row: row, column: position) }
                .onRightClick { store.openItemMenu(row: row, column: position) }
        } else {
            Color.clear.frame(width: width, height: 1)
        }
    }

    /// 个人收藏、常去网站：一个方块，是网站自己的图标（没有够大的图标就是网站名的第一个字母），下面写名字
    private func tileView(_ page: WebPage, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: tileCorner, style: .continuous)
        return VStack(spacing: 19) {
            SiteTile(page: page, size: tile, corner: tileCorner)
                .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1.5))
                .browserLift(focused: focused, in: shape, scale: 1.1, shadow: 26)
            Text(page.name)
                .font(.tv(.caption2, emphasized: focused))
                .foregroundStyle(.white.opacity(focused ? 1 : 0.72))
                .lineLimit(1)
                .frame(width: tileLabel)
                .offset(y: focused ? 10 : 0)
        }
        .frame(width: tile)
        .animation(Motion.focus, value: focused)
    }

    /// 最近浏览、阅读列表：卡片，左上角网站图标和网址，中间标题，下面多久以前
    private func cardView(_ page: WebPage, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SiteTile(page: page, size: 40, corner: 10, minPixels: 16)
                Text(page.host).font(.tv(.caption2, emphasized: true)).lineLimit(1)
                    .foregroundStyle(focused ? .black.opacity(0.6) : .white.opacity(0.6))
            }
            Text(page.name)
                .font(.tv(.caption1, emphasized: true))
                .lineLimit(2)
                .foregroundStyle(focused ? .black : .white.opacity(0.92))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let visited = page.visited {
                Text(BrowserTime.ago(visited)).font(.tv(.caption2)).foregroundStyle(focused ? .black.opacity(0.5) : .white.opacity(0.45))
            }
        }
        .padding(23)
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .background(shape.fill(focused ? Color.white : .white.opacity(0.08)))
        .overlay(shape.strokeBorder(.white.opacity(focused ? 0 : 0.1), lineWidth: 1.5))
        .browserLift(focused: focused, in: shape, scale: 1.06, shadow: 26)
        .animation(Motion.focus, value: focused)
    }

    /// 还读不到 Safari 时：一张说明卡，选它打开系统设置里那一页
    private func permissionCard(focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return HStack(spacing: 28) {
            Image(systemName: "lock.shield").font(.tv(.title2))
            VStack(alignment: .leading, spacing: 10) {
                Text("Let Mac TV read Safari's favorites and history").font(.tv(.body, emphasized: true))
                Text("Turn on Mac TV in Privacy & Security › Full Disk Access.")
                    .font(.tv(.caption2)).opacity(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(focused ? .black : .white)
        .padding(.horizontal, 38)
        .frame(width: 1224, height: 184, alignment: .leading)
        .background(shape.fill(focused ? Color.white : .white.opacity(0.08)))
        .overlay(shape.strokeBorder(.white.opacity(focused ? 0 : 0.12), lineWidth: 1.5))
        .scaleEffect(focused ? 1.03 : 1, anchor: .leading)
        .animation(Motion.focus, value: focused)
    }
}

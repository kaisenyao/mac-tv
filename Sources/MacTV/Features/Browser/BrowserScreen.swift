import SwiftUI

/// 浏览器的开始页（见 BrowserStore）。样子照 Safari 的开始页，放大到电视上：上面一条地址栏，
/// 下面个人收藏、常去网站是一个个大方块（网站自己的图标），最近浏览、阅读列表是卡片（标题、网站、多久以前）。
/// 选中的那一个和 tvOS 一样浮起来。开无痕标签页时，地址栏上面写着 Private Browsing，地址栏是深紫色的。
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

    private let margin: CGFloat = 120
    private let rowHeight: CGFloat = 400
    private let tile: CGFloat = 220
    private let card = CGSize(width: 500, height: 236)
    private let gap: CGFloat = 44
    private let rowsTop: CGFloat = 262

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            rowsView
                .frame(width: canvas.width, height: canvas.height - rowsTop, alignment: .topLeading)
                .clipped()
                .offset(y: rowsTop)
            if store.startsPrivate {
                // 无痕：选的网站开成无痕标签页
                Label("Private Browsing", systemImage: "hand.raised.fill")
                    .font(.tv(.caption1, emphasized: true))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(hex: "#5B4BA8").opacity(0.6)))
                    .frame(width: canvas.width)
                    .padding(.top, 30)
            }
            addressBar
                .frame(width: canvas.width)
                .padding(.top, 86)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .background(Color.black)
        .onChange(of: store.editing) { _, editing in typing = editing }
        .onChange(of: store.focusRequest) { _, _ in if store.editing { typing = true } }
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
        let focused = store.focus == .field
        let lit = focused || store.editing
        let text = Binding(get: { store.query }, set: { store.typed($0) })
        return HStack(spacing: 22) {
            Image(systemName: "magnifyingglass").font(.system(size: 32, weight: .semibold))
            if store.editing {
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
                Text(store.query.isEmpty ? "Search or enter website name" : store.query)
                    .foregroundStyle(lit ? Color.black.opacity(0.55) : .white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .font(.tv(.callout))
        .foregroundStyle(lit ? .black : .white.opacity(0.85))
        .padding(.horizontal, 40)
        .frame(width: 1200, height: 96)
        .background {
            Capsule().fill(lit ? Color.white : store.startsPrivate ? Color(hex: "#5B4BA8").opacity(0.35) : .white.opacity(0.1))
            Capsule().strokeBorder(.white.opacity(lit ? 0 : 0.14))
        }
        .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 24, y: 14)
        .scaleEffect(focused && !store.editing ? 1.04 : 1)
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

    private func width(of style: BrowserStore.Row.Style) -> CGFloat {
        switch style {
        case .tiles: tile
        case .cards, .notice: card.width
        }
    }

    private func rowView(_ row: BrowserStore.Row, index: Int) -> some View {
        let column = store.column(of: index)
        let active = focusedRow == index && !store.editing
        let width = width(of: row.style)
        return VStack(alignment: .leading, spacing: 28) {
            Text(row.title)
                .font(.tv(.headline, emphasized: true))
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
                // 选中的那一个停在第二个位置，前面露出一个
                .offset(x: -CGFloat(max(0, column - 1)) * (width + gap))
                .animation(Motion.focus, value: column)
            }
        }
    }

    /// 一排里的一个：离选中的远的只占个位置不画
    @ViewBuilder
    private func item<Content: View>(position: Int, column: Int, width: CGFloat, row: Int,
                                     @ViewBuilder content: () -> Content) -> some View {
        if abs(position - column) <= 6 {
            content()
                .opacity(position < column - 1 ? 0 : 1)
                .contentShape(Rectangle())
                .onTapGesture { store.focus(row: row, column: position); store.handle(.select) }
        } else {
            Color.clear.frame(width: width, height: 1)
        }
    }

    /// 个人收藏、常去网站：一个方块，是网站自己的图标（没有够大的图标就是网站名的第一个字母），下面写名字
    private func tileView(_ page: WebPage, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        return VStack(spacing: 22) {
            SiteTile(page: page, size: tile, corner: 44)
                .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1.5))
                .browserLift(focused: focused, in: shape, scale: 1.1)
            Text(page.name)
                .font(.tv(.caption1, emphasized: focused))
                .foregroundStyle(.white.opacity(focused ? 1 : 0.72))
                .lineLimit(1)
                .frame(width: tile + 30)
                .offset(y: focused ? 12 : 0)
        }
        .animation(Motion.focus, value: focused)
    }

    /// 最近浏览、阅读列表：卡片，左上角网站图标和网址，中间标题，下面多久以前
    private func cardView(_ page: WebPage, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SiteTile(page: page, size: 46, corner: 12, minPixels: 16)
                Text(page.host).font(.tv(.caption1, emphasized: true)).lineLimit(1)
                    .foregroundStyle(focused ? .black.opacity(0.6) : .white.opacity(0.6))
            }
            Text(page.name)
                .font(.tv(.body, emphasized: true))
                .lineLimit(2)
                .foregroundStyle(focused ? .black : .white.opacity(0.92))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let visited = page.visited {
                Text(BrowserTime.ago(visited)).font(.tv(.caption2)).foregroundStyle(focused ? .black.opacity(0.5) : .white.opacity(0.45))
            }
        }
        .padding(26)
        .frame(width: card.width, height: card.height, alignment: .topLeading)
        .background(shape.fill(focused ? Color.white : .white.opacity(0.08)))
        .overlay(shape.strokeBorder(.white.opacity(focused ? 0 : 0.1), lineWidth: 1.5))
        .browserLift(focused: focused, in: shape, scale: 1.06)
        .animation(Motion.focus, value: focused)
    }

    /// 还读不到 Safari 时：一张说明卡，选它打开系统设置里那一页
    private func permissionCard(focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return HStack(spacing: 32) {
            Image(systemName: "lock.shield").font(.system(size: 68, weight: .medium))
            VStack(alignment: .leading, spacing: 12) {
                Text("Let Mac TV read Safari's favorites and history").font(.tv(.callout, emphasized: true))
                Text("Turn on Mac TV in Privacy & Security › Full Disk Access.")
                    .font(.tv(.caption1)).opacity(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(focused ? .black : .white)
        .padding(.horizontal, 44)
        .frame(width: 1400, height: 210, alignment: .leading)
        .background(shape.fill(focused ? Color.white : .white.opacity(0.08)))
        .overlay(shape.strokeBorder(.white.opacity(focused ? 0 : 0.12), lineWidth: 1.5))
        .scaleEffect(focused ? 1.03 : 1, anchor: .leading)
        .animation(Motion.focus, value: focused)
    }
}

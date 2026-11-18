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

    private var topBar: some View {
        HStack(spacing: 24) {
            if let mark = NeteaseStore.wordmark {
                Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 46)
            } else {
                Text("网易云音乐").font(.system(size: 44, weight: .medium)).foregroundStyle(.white)
            }
            Spacer()
            if let song = store.current, !store.nowPlayingVisible {
                // 正在放的歌：回到列表后留一个小小的提示
                HStack(spacing: 12) {
                    Image(systemName: store.paused ? "pause.fill" : "waveform")
                    Text(song.name).lineLimit(1)
                }
                .font(.tv(.caption1))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 24).frame(height: 58)
                .background(.white.opacity(0.12), in: Capsule())
                .frame(maxWidth: 460, alignment: .trailing)
            }
            if store.account != nil, store.page == nil, !store.nowPlayingVisible { searchField }
        }
        .padding(.horizontal, margin)
        .padding(.top, 58)
        .frame(width: canvas.width)
    }

    /// 搜索框：平时是右上角一个小小的"搜索"，最上面一排再按上就变成输入框
    private var searchField: some View {
        HStack(spacing: 14) {
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
        .foregroundStyle(store.editing ? .black : .white.opacity(0.85))
        .padding(.horizontal, 24)
        .frame(width: store.editing ? 620 : nil, height: 58, alignment: .leading)
        .background(store.editing ? Color.white : Color.white.opacity(0.12), in: Capsule())
        .environment(\.colorScheme, store.editing ? .light : .dark)
        .contentShape(Capsule())
        .onTapGesture { store.tapSearch() }
        .onChange(of: store.editing) { _, editing in typing = editing }
        .animation(Self.slide, value: store.editing)
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
                if list.count > 0 { Text("\(list.count) 首").font(.tv(.body)).foregroundStyle(.white.opacity(0.72)) }
            case .logout:
                Text(store.logoutArmed ? "再按一次退出登录" : "退出登录").font(.tv(.title2, emphasized: true)).foregroundStyle(.white)
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
        let active = index == store.row && !store.editing
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
                        Image(systemName: store.paused ? "pause.fill" : "waveform").font(.system(size: 64, weight: .semibold)).foregroundStyle(.white)
                    }
                case .playlist(let list):
                    BiliImage(url: list.cover)
                case .logout:
                    let armed = store.logoutArmed
                    (armed ? Color(hex: "#C0392B") : Color.clear)
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 60, weight: .medium))
                        Text(armed ? "再按一次" : "退出登录").font(.tv(.callout, emphasized: true))
                    }
                    .foregroundStyle(.white)
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
                case .logout:
                    EmptyView()
                }
            }
            .frame(width: cardSize, alignment: .leading)
            .offset(y: focused ? 12 : 0)
        }
        .zIndex(focused ? 1 : 0)
        .animation(Motion.focus, value: focused)
        .animation(Motion.focus, value: store.logoutArmed)
    }

    // MARK: 歌单页

    /// 左边封面和歌单名，右边竖排的歌：选中的那一行是白底黑字，停在偏上的位置，列表在它下面滚
    private func playlistPage(_ page: NeteaseStore.Page) -> some View {
        let listTop: CGFloat = 190
        let anchor = 3   // 选中的行尽量停在第 4 行的位置，上面能看到刚过去的几首
        let shift = -CGFloat(max(0, page.index - anchor)) * songHeight
        return HStack(alignment: .top, spacing: 100) {
            VStack(alignment: .leading, spacing: 0) {
                BiliImage(url: page.list.cover)
                    .frame(width: 460, height: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                Text(page.list.name).font(.tv(.headline, emphasized: true)).foregroundStyle(.white).lineLimit(3).padding(.top, 36)
                Text(page.loading ? "正在载入…" : "\(page.songs.count) 首")
                    .font(.tv(.body)).foregroundStyle(.white.opacity(0.6)).padding(.top, 10)
            }
            .frame(width: 460, alignment: .leading)
            .padding(.top, listTop)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(page.songs.enumerated()), id: \.offset) { index, song in
                    // 只画选中那行附近的，几百首的歌单也不卡
                    if abs(index - page.index) <= 14 {
                        songRow(song, number: index + 1, focused: index == page.index)
                            .onTapGesture { store.tapSong(index) }
                    } else {
                        Color.clear.frame(height: songHeight)
                    }
                }
            }
            .offset(y: shift)
            .frame(width: canvas.width - margin * 2 - 560, height: canvas.height - listTop, alignment: .topLeading)
            .clipped()
            // 上下两头渐渐淡出
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                       .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .padding(.top, listTop)
        }
        .padding(.horizontal, margin)
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .animation(Self.slide, value: page.index)
    }

    private func songRow(_ song: NeteaseSong, number: Int, focused: Bool) -> some View {
        let current = store.current == song
        return HStack(spacing: 24) {
            ZStack {
                if current {
                    Image(systemName: store.paused ? "pause.fill" : "waveform").font(.system(size: 24, weight: .semibold))
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
            BiliImage(url: song.cover)
                .frame(width: 160, height: 90)
                .blur(radius: 12)
                .scaleEffect(x: canvas.width / 160 * 1.2, y: canvas.height / 90 * 1.2)
                .opacity(0.8)
                .id(song.id)
            Color.black.opacity(0.32)
            HStack(alignment: .center, spacing: 130) {
                VStack(alignment: .leading, spacing: 0) {
                    BiliImage(url: song.cover)
                        .frame(width: 600, height: 600)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.55), radius: 50, y: 30)
                        .scaleEffect(store.paused ? 0.9 : 1)
                        .animation(Self.slide, value: store.paused)
                        .id(song.id)
                        .transition(.opacity)
                    Text(song.name).font(.tv(.headline, emphasized: true)).foregroundStyle(.white).lineLimit(1).padding(.top, 44)
                    Text(song.artist).font(.tv(.body)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).padding(.top, 8)
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
                        if store.paused {
                            Image(systemName: "pause.fill")
                        } else if !store.actualLevel.isEmpty {
                            Text(NeteaseStore.name(of: store.actualLevel))   // 实际拿到的音质
                        }
                        Spacer()
                        Text("-" + clock(max(0, store.duration - store.time)))
                    }
                    .font(.system(size: 24, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 14)
                }
                .frame(width: 600, alignment: .leading)
                lyricsColumn
                    .frame(width: 800, height: 820, alignment: .leading)
            }
            qualityBar
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: song.id)
    }

    /// 音质：从屏幕上方滑下来的一行，白色高亮左右滑。和哔哩哔哩的清晰度是同一种做法。
    private var qualityBar: some View {
        let open = store.qualityVisible
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("音质").font(.tv(.callout)).foregroundStyle(.white.opacity(0.55)).padding(.trailing, 20)
                ForEach(Array(NeteaseStore.qualities.enumerated()), id: \.offset) { index, quality in
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

    /// 一句歌词。正在唱、并且有逐字时间的那一句：已经唱到的字是白的，还没唱到的是半透明的。
    private func lineText(_ line: NeteaseLyricLine, current: Bool) -> Text {
        guard current, !line.words.isEmpty else { return Text(line.text).foregroundColor(.white) }
        return line.words.reduce(Text("")) { text, word in
            text + Text(word.text).foregroundColor(.white.opacity(word.time <= store.time + 0.1 ? 1 : 0.42))
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

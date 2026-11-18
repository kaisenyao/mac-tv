import SwiftUI

struct NeteaseRoot: View {
    @ObservedObject var store: NeteaseStore

    var body: some View {
        TVCanvas { NeteaseScreen(store: store) }.ignoresSafeArea()
    }
}

/// 网易云音乐的电视式页面：上半屏是选中那首歌（或歌单）的名字，下半屏是一排排方形封面。
struct NeteaseScreen: View {
    @ObservedObject var store: NeteaseStore
    @Environment(\.canvasSize) private var canvas

    private let margin: CGFloat = 120
    private let cardSize: CGFloat = 300
    private let cardGap: CGFloat = 40
    private let rowHeight: CGFloat = 500
    private let rowsTop: CGFloat = 430

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            if store.account != nil {
                rows
                    .frame(width: canvas.width, height: canvas.height - rowsTop, alignment: .topLeading)
                    .clipped()
                    .offset(y: rowsTop)
                details
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
    }

    private var focusedCover: URL? {
        switch store.focused {
        case .song(let song): song.cover
        case .playlist(let list): list.cover
        default: nil
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
        HStack {
            if let mark = NeteaseStore.wordmark {
                Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 46)
            } else {
              HStack(spacing: 18) {
                if let icon = NeteaseStore.appIcon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 68, height: 68)
                }
                Text("网易云音乐").font(.system(size: 44, weight: .medium)).foregroundStyle(.white)
              }
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
                .frame(maxWidth: 520, alignment: .trailing)
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, 64)
        .frame(width: canvas.width)
    }

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

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch store.focused {
            case .song(let song):
                Text(song.name).font(.tv(.title2, emphasized: true)).foregroundStyle(.white).lineLimit(2)
                Text(song.artist).font(.tv(.body)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            case .playlist(let list):
                Text(list.name).font(.tv(.title2, emphasized: true)).foregroundStyle(.white).lineLimit(2)
                Text("\(list.count) 首").font(.tv(.body)).foregroundStyle(.white.opacity(0.72))
            case .logout:
                Text("退出登录").font(.tv(.title2, emphasized: true)).foregroundStyle(.white)
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
    }

    private func rowView(_ row: NeteaseStore.Row, index: Int) -> some View {
        let focusedColumn = store.column(of: row)
        let active = index == store.row
        let shift = -CGFloat(max(0, focusedColumn - 1)) * (cardSize + cardGap)
        return VStack(alignment: .leading, spacing: 26) {
            Text(row.title)
                .font(.tv(.headline, emphasized: true))
                .foregroundStyle(.white.opacity(active ? 1 : 0.7))
                .padding(.leading, margin)
            HStack(alignment: .top, spacing: cardGap) {
                ForEach(Array(row.items.enumerated()), id: \.offset) { column, item in
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
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 60, weight: .medium))
                        Text("退出登录").font(.tv(.callout, emphasized: true))
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
                    Text("\(list.count) 首").font(.tv(.caption2)).foregroundStyle(.white.opacity(0.5))
                case .logout:
                    EmptyView()
                }
            }
            .frame(width: cardSize, alignment: .leading)
            .offset(y: focused ? 12 : 0)
        }
        .zIndex(focused ? 1 : 0)
        .animation(Motion.focus, value: focused)
    }

    // MARK: 正在播放

    /// 左边封面、歌名和进度，右边跟着唱的歌词。没有按钮：左右切歌，确认暂停，返回回列表。
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
                        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: store.paused)
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
                        if store.paused { Image(systemName: "pause.fill") }
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
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: song.id)
    }

    /// 歌词：正在唱的那句又大又亮、停在中间，前后的句子越远越淡
    @ViewBuilder private var lyricsColumn: some View {
        if store.lyrics.isEmpty {
            Color.clear
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 34) {
                        Color.clear.frame(height: 360)
                        ForEach(Array(store.lyrics.enumerated()), id: \.offset) { index, line in
                            let distance = abs(index - max(0, store.lyricIndex))
                            Text(line.text)
                                .font(.system(size: 50, weight: .bold))
                                .foregroundStyle(.white.opacity(index == store.lyricIndex ? 1 : max(0.1, 0.38 - Double(distance) * 0.06)))
                                .scaleEffect(index == store.lyricIndex ? 1 : 0.94, anchor: .leading)
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

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

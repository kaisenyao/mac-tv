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
    private let red = Color(hex: "#E60026")

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            if store.account != nil {
                rows
                    .frame(width: canvas.width, height: canvas.height - rowsTop, alignment: .topLeading)
                    .clipped()
                    .offset(y: rowsTop)
                details
                if store.loading, store.rows.isEmpty { ProgressView().controlSize(.large).frame(width: canvas.width, height: canvas.height) }
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
                Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 64)
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
            Text(store.loginScanned ? "请在手机上确认" : "用网易云音乐 App 扫码登录")
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

    private func nowPlaying(_ song: NeteaseSong) -> some View {
        ZStack {
            Color.black
            BiliImage(url: song.cover)
                .frame(width: 160, height: 90)
                .blur(radius: 12)
                .scaleEffect(x: canvas.width / 160 * 1.2, y: canvas.height / 90 * 1.2)
                .opacity(0.75)
                .id(song.id)
            Color.black.opacity(0.35)
            HStack(spacing: 110) {
                BiliImage(url: song.cover)
                    .frame(width: 560, height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 50, y: 30)
                    .scaleEffect(store.paused ? 0.92 : 1)
                    .animation(.spring(response: 0.42, dampingFraction: 0.84), value: store.paused)
                    .id(song.id)
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 20) {
                    Text(song.name).font(.tv(.title1, emphasized: true)).foregroundStyle(.white).lineLimit(3)
                    Text(song.artist).font(.tv(.headline)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    Spacer().frame(height: 50)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.22))
                            Capsule().fill(.white)
                                .frame(width: geo.size.width * (store.duration > 0 ? min(1, store.time / store.duration) : 0))
                        }
                    }
                    .frame(height: 8)
                    HStack {
                        Text(clock(store.time))
                        Spacer()
                        Text(clock(store.duration))
                    }
                    .font(.system(size: 26, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                }
                .frame(width: 760, alignment: .leading)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: song.id)
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

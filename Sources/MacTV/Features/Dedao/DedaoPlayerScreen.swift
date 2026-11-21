import SwiftUI

/// 得到的播放界面，和网易云的正在播放一样的样子、一样的按法：
/// 左边封面，下面书名（右边一个"⋯"）、进度条和时间；右边是文稿，念到的那一段亮着、停在同一个高度，
/// 前后的越远越淡，跟着声音往下走（文稿不带每段的时间，念到哪是按字数估的）。
/// 没有按钮：确认 / 空格 = 放 / 停；左右 = 上一讲 / 下一讲；按住左右 = 快退 / 快进；双指横滑 = 拖进度；
/// 按住确认（或点"⋯"）= 倍速、定时关闭、讲目列表；下 = 讲目列表；返回 = 收起
struct DedaoPlayerScreen: View {
    @ObservedObject var store: DedaoStore
    @ObservedObject var player: DedaoPlayer
    @ObservedObject var reader: DedaoReader
    @Environment(\.canvasSize) private var canvas
    @State private var hovering = false
    @ObservedObject private var pointer = PointerActivity.shared

    init(store: DedaoStore, player: DedaoPlayer) {
        self.store = store
        self.player = player
        self.reader = store.reader
    }

    static let slide = Motion.slide
    /// 和网易云的播放界面一样的尺寸：左边一栏 600 宽，封面 600 高（得到的封面是竖的 3:4，在这一栏里居中），
    /// 中间隔 130，右边文稿那一栏 800 宽。字号、"⋯"、进度条也和网易云一样，换着用两个应用看着是一套
    static let columnWidth: CGFloat = 600
    static let coverSize = CGSize(width: 450, height: 600)
    static let transcriptWidth: CGFloat = 800
    static let gap: CGFloat = 130

    var body: some View {
        let track = player.current
        ZStack {
            Color.black
            // 背景：封面的小图模糊后放大铺满（直接糊全屏大图每一帧都很贵）
            BiliImage(url: track?.cover)
                .frame(width: 120, height: 160)
                .clipped()
                .blur(radius: 12)
                .scaleEffect(x: canvas.width / 120 * 1.2, y: canvas.height / 160 * 1.2)
                .opacity(0.8)
            Color.black.opacity(0.32)
            HStack(alignment: .center, spacing: Self.gap) {
                left(track)
                    .frame(width: Self.columnWidth, alignment: .leading)
                transcript(track)
                    .frame(width: Self.transcriptWidth, height: 820, alignment: .topLeading)
            }
            .fixedSize()
            .frame(width: canvas.width, height: canvas.height)
            // 讲目列表开着时，上面这些退到后面：轻微模糊、变暗（同网易云的播放列表）
            .blur(radius: store.lecturesVisible ? 22 : 0)
            .opacity(store.lecturesVisible ? 0.75 : 1)
            .animation(Self.slide, value: store.lecturesVisible)
            if store.lecturesVisible {
                // 点空白处：收起讲目列表
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissLectures() }
            }
            lectures
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    // MARK: 左边：封面、书名和"⋯"、进度条

    private func left(_ track: DedaoAPI.Track?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 暂停：封面轻轻缩小，正中间浮出一个暂停图标（同网易云）；点封面放 / 停
            BiliImage(url: track?.cover)
                .frame(width: Self.coverSize.width, height: Self.coverSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.55), radius: 50, y: 30)
                .overlay {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 68, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 168, height: 168)
                        .tvGlass(in: Circle())
                        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                        .scaleEffect(player.paused ? 1 : 0.7)
                        .opacity(player.paused ? 1 : 0)
                }
                .scaleEffect(player.paused ? 0.9 : 1)
                .animation(Self.slide, value: player.paused)
                .contentShape(Rectangle())
                .hoverLift(scale: 1.015, brighten: 0.03)
                .onTapGesture { store.tapPlayPause() }
                .frame(width: Self.columnWidth)
            HStack(alignment: .center, spacing: 16) {
                // 换一讲：旧的书名先淡出，新的随后淡入
                ZStack(alignment: .leading) {
                    let name = Self.split(track?.title ?? "")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(name.title).font(.tv(.headline, emphasized: true)).lineLimit(1)
                        Text(subtitle(track, by: name.by)).font(.tv(.body)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    .id(track?.id)
                    .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.3), value: track?.id)
                Spacer(minLength: 0)
                // "⋯"：按住确认（或点它）展开——倍速、定时关闭、讲目列表
                Image(systemName: "ellipsis")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white.opacity(store.menu?.anchor == .nowPlaying ? 1 : 0.7))
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
                    .hoverLift(scale: 1.15, brighten: 0.2)
                    .onTapGesture { store.tapMore() }
                    .anchorPreference(key: DedaoAnchors.self, value: .bounds) { ["more": $0] }
            }
            .padding(.top, 36)
            progress.padding(.top, 20)
        }
    }

    /// 得到听书的名字是"《书名》| 解读人"：大字只写书名，解读人挪到下面一行（不然一行写不下，书名被截掉）
    nonisolated static func split(_ title: String) -> (title: String, by: String?) {
        let parts = title.split(maxSplits: 1, whereSeparator: { $0 == "|" || $0 == "｜" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return (title, nil) }
        return (parts[0], parts[1])
    }

    /// 书名下面那一行：解读人 · 谁念的 · 课程名（或者"每天听本书"）
    private func subtitle(_ track: DedaoAPI.Track?, by interpreter: String?) -> String {
        let source: String
        if let page = store.currentPage, page.item.kind == .course || page.item.kind == .collection { source = page.item.title }
        else { source = track?.productType == 66 ? "课程" : "每天听本书" }
        var seen = Set<String>()
        return [interpreter ?? "", track?.reader ?? "", source].filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: " · ")
    }

    /// 进度条和两头的时间（同网易云）。拖进度条、点哪儿跳到哪儿；中间写着倍速、定时（有的话）
    private var progress: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    let fraction = player.duration > 0 ? min(1, max(0, player.shownTime / player.duration)) : 0
                    Capsule().fill(.white).frame(width: geo.size.width * fraction)
                }
                .frame(height: player.scrubbing || (hovering && pointer.active) ? 12 : 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // 按住拖：声音先停，进度条和文稿跟着走，松手跳过去接着放；点一下就是跳到那里
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        player.beginScrub()
                        player.scrub(to: Double(value.location.x / max(1, geo.size.width)) * player.duration)
                    }
                    .onEnded { _ in player.endScrub() })
                .onHover { inside in withAnimation(Motion.focus) { hovering = inside } }
                .animation(Motion.focus, value: player.scrubbing)
            }
            .frame(height: 36)
            HStack {
                Text(clockText(player.shownTime))
                Spacer()
                status
                Spacer()
                Text("−" + clockText(max(0, player.duration - player.shownTime)))
            }
            .font(.tvTimecode)
            .foregroundStyle(.white.opacity(0.6))
            if let failure = player.failure {
                Text(failure).font(.tv(.caption2)).foregroundStyle(Color(hex: "#FF8A80")).lineLimit(1).padding(.top, 10)
            }
        }
    }

    /// 进度条下面中间：正在载入；不是 1 倍速时写倍速；开着定时写还剩多久（每秒走一下）。
    /// 字号同网易云那里写音质的：数字是两头时间的字号（tvTimecode）；汉字占满字框，同样字号看着大一圈，
    /// 小一号（NeteaseProgress.cjkStatus）看起来才一样高
    @ViewBuilder private var status: some View {
        if player.loading {
            Text("正在载入…").font(NeteaseProgress.cjkStatus)
        } else {
            HStack(spacing: 18) {
                if player.speed != 1 { Text(DedaoStore.speedText(player.speed)) }
                if let timer = player.sleep {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let label = timer.label(at: context.date)
                        Label(label, systemImage: "timer").font(label.allSatisfy(\.isASCII) ? .tvTimecode : NeteaseProgress.cjkStatus.monospacedDigit())
                    }
                }
            }
            .font(.tvTimecode)
        }
    }

    // MARK: 讲目列表（按下，从屏幕下方滑上来的一排；同网易云的播放列表）

    private var lectures: some View {
        let open = store.lecturesVisible
        let size = CGSize(width: 180, height: 240), gap: CGFloat = 34
        let focus = store.lectureFocus
        let queue = player.queue
        let shift = -CGFloat(max(0, focus - 1)) * (size.width + gap)
        let lo = max(0, focus - 3), hi = min(queue.count, focus + 10)
        return VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 22) {
                Text("目录").font(.tvRowTitle).padding(.leading, 120)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(lo..<max(lo, hi), id: \.self) { index in
                        let track = queue[index]
                        let focused = index == focus
                        VStack(alignment: .leading, spacing: 12) {
                            ZStack(alignment: .topLeading) {
                                BiliImage(url: track.cover)
                                if index == player.index {
                                    Color.black.opacity(0.45)
                                    NeteaseWave(playing: !player.paused, active: open, size: 44)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                Text("\(index + 1)").font(.tvBadge.monospacedDigit())
                                    .padding(.horizontal, 10).frame(height: 30)
                                    .background(Capsule().fill(.black.opacity(0.55)))
                                    .padding(10)
                            }
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 5 : 1.5))
                            .scaleEffect(focused ? 1.08 : 1)
                            .opacity(track.playable ? 1 : 0.45)
                            Text(track.title).font(.tvCardTitle)
                                .foregroundStyle(.white.opacity(focused ? 1 : 0.75)).lineLimit(2)
                                .offset(y: focused ? 10 : 0)
                            Text(track.duration > 0 ? clockText(track.duration) : " ").font(.tvCardDetail)
                                .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                .offset(y: focused ? 10 : 0)
                        }
                        .frame(width: size.width, alignment: .leading)
                        .opacity(index < focus - 1 ? 0 : 1)
                        .contentShape(Rectangle())
                        .hoverLift()
                        .onTapGesture { store.tapLecture(index) }
                    }
                }
                .padding(.leading, 120 + CGFloat(lo) * (size.width + gap))
                .offset(x: shift)
                .animation(Motion.focus, value: focus)
            }
            .padding(.top, 70)
            .padding(.bottom, 54)
            .frame(width: canvas.width, alignment: .leading)
            // 右边露出一截的那一讲淡出屏幕（见 EdgeFade）；底下的暗色不跟着淡
            .edgeFade(trailing: true, width: EdgeFadeMask.width(screen: canvas.width, inset: 120, card: size.width, gap: gap))
            .background {
                // 后面已经模糊了，这里只需要淡淡一层暗色托住文字
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.3), location: 0.2),
                                       .init(color: .black.opacity(0.45), location: 0.45), .init(color: .black.opacity(0.55), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -400)   // 往屏幕外多铺一段：滑上来回弹时底下不露缝
            }
        }
        .offset(y: open ? 0 : 620)
        .opacity(open ? 1 : 0)
        .allowsHitTesting(open)
        .animation(Self.slide, value: open)
    }

    // MARK: 右边：文稿

    @ViewBuilder private func transcript(_ track: DedaoAPI.Track?) -> some View {
        ZStack(alignment: .topLeading) {
            switch reader.state {
            case .idle: EmptyView()
            case .loading:
                Text("正在载入文稿…").font(.tv(.caption1)).opacity(0.4)
            case .missing(let summary):
                // 没有文稿：放一句介绍，在这一栏正中间
                VStack(spacing: 22) {
                    Text("这一讲没有文稿").font(.tv(.caption1, emphasized: true)).opacity(0.45)
                    if !summary.isEmpty {
                        Text(summary).font(.system(size: 38, weight: .semibold)).multilineTextAlignment(.center)
                            .lineSpacing(10).opacity(0.85).lineLimit(8)
                    }
                }
                .frame(width: Self.transcriptWidth, height: 820)
            case .ready(let text):
                let duration = player.duration > 0 ? player.duration : (track?.duration ?? 0)
                // 念到第几段由 reader 按播放器的媒体时间算（拖、跳、换讲后马上重算）
                DedaoTranscriptColumn(transcript: text, index: reader.line, partial: text.partial(duration: duration)) { paragraph in
                    player.seek(to: text.time(of: paragraph, duration: duration))
                }
                .equatable()
            }
        }
        .id(reader.trackID ?? "")
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: reader.state)
    }
}

/// 文稿那一栏：念到的那一段又亮又停在上面三成的地方，前后的越远越淡；换段时滚动和变亮用同一条曲线（同网易云的歌词）。
/// 只在念到的那一段变了时才重画（播放时间一秒变两次，这一栏不跟着重画）
private struct DedaoTranscriptColumn: View, Equatable {
    let transcript: DedaoAPI.Transcript
    let index: Int
    let partial: Bool
    let seek: (Int) -> Void

    private static let lyric = Animation.spring(response: 0.6, dampingFraction: 0.9)
    /// 念到的那一段的顶停在这一栏的哪个高度
    private static let anchor = UnitPoint(x: 0, y: 0.3)

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.index == b.index && a.partial == b.partial && a.transcript == b.transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 只拿到开头一部分时（没登录、没买）写一句，不然以为文稿就这么长
            HStack(spacing: 14) {
                Text("文稿").font(.tv(.caption1, emphasized: true)).opacity(0.55)
                if partial { Text("节选").font(.tv(.caption2)).opacity(0.38) }
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        Color.clear.frame(height: 240)
                        ForEach(transcript.paragraphs) { paragraph in
                            VStack(alignment: .leading, spacing: 0) {
                                // 一个看不见的记号贴在这一段的顶上：滚动时让它对准固定的高度
                                Color.clear.frame(height: 1).id(paragraph.id)
                                line(paragraph)
                            }
                        }
                        Color.clear.frame(height: 620)
                    }
                    // 字一直铺满整栏宽（不会因为哪一段短就整列缩窄、挤到右边）
                    .frame(width: DedaoPlayerScreen.transcriptWidth, alignment: .leading)
                    .animation(Self.lyric, value: index)
                }
                .scrollDisabled(true)
                .onChange(of: index) { _, now in
                    withAnimation(Self.lyric) { proxy.scrollTo(now, anchor: Self.anchor) }
                }
                .onAppear { proxy.scrollTo(index, anchor: Self.anchor) }
            }
            // 上下两头渐渐淡出
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                       .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private func line(_ paragraph: DedaoAPI.Transcript.Paragraph) -> some View {
        let current = paragraph.id == index
        let distance = abs(paragraph.id - index)
        return Group {
            switch paragraph.kind {
            case .header:
                Text(paragraph.text).font(.system(size: 32, weight: .bold)).foregroundStyle(DedaoStyle.accent)
            case .quote:
                HStack(alignment: .top, spacing: 18) {
                    Capsule().fill(.white.opacity(0.5)).frame(width: 5)
                    styled(paragraph).font(.system(size: 32, weight: .medium)).italic()
                }
                .fixedSize(horizontal: false, vertical: true)
            case .point:
                VStack(alignment: .leading, spacing: 10) {
                    Text("划重点").font(.tv(.caption2, emphasized: true)).foregroundStyle(DedaoStyle.accent)
                    styled(paragraph).font(.system(size: 34, weight: .semibold))
                }
            case .text:
                styled(paragraph).font(.system(size: 36, weight: .medium))
            }
        }
        .lineSpacing(12)
        .opacity(current ? 1 : max(0.14, 0.42 - Double(distance) * 0.08))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { seek(paragraph.id) }
    }

    /// 一段字：得到划了线的重点句是暖一点的颜色、粗一点
    private func styled(_ paragraph: DedaoAPI.Transcript.Paragraph) -> Text {
        paragraph.runs.reduce(Text(verbatim: "")) { text, run in
            let piece = run.marked ? Text(verbatim: run.text).foregroundStyle(Color(hex: "#FFB27A")).bold()
                : Text(verbatim: run.text).foregroundStyle(.white)
            return Text("\(text)\(piece)")
        }
    }
}

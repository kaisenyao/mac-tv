import SwiftUI

/// 看视频时长按确认，从右边拉出来的面板：UP 主、点赞、投币、收藏、选集（分 P、合集才有）、倍速、字幕、弹幕。
/// 和账号菜单是同一种玻璃底板、同一块滑动的白色高亮；选了投币、倍速、字幕、弹幕（取消收藏要先确认），
/// 面板里换成那一项的小列表，返回回到上一层。选集是收起面板、拉出下面那一排。
/// 它一直都在，平时停在屏幕右边外面，所以拉出、推回都是连贯的滑动。
struct BilibiliPlayerPanel: View {
    @ObservedObject var player: BilibiliNativePlayer

    private let width: CGFloat = 430
    private let rowHeight: CGFloat = 76
    private let gap: CGFloat = 8
    private let pink = Color(hex: "#FB7299")

    var body: some View {
        let open = player.panelVisible
        VStack(alignment: .leading, spacing: 14) {
            if let list = player.panelList {
                listHeader(list)
                options(list)
            } else {
                Text("更多").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).padding(.leading, 20)
                rows
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .tvPanelSurface(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .tvShadow(.float)
        .padding(.trailing, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .offset(x: open ? 0 : width + 140)
        .opacity(open ? 1 : 0)
        .allowsHitTesting(open)
        .animation(BiliMotion.slide, value: open)
        .animation(BiliMotion.slide, value: player.panelIndex)
        .animation(BiliMotion.slide, value: player.panelListIndex)
        .animation(Motion.press, value: player.panelList)
        .animation(Motion.press, value: player.relation)
    }

    // MARK: 第一层：一行一项

    private var rows: some View {
        let items = player.panelRows
        let index = min(player.panelIndex, max(0, items.count - 1))
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.element) { position, row in
                rowView(row, focused: position == index)
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { player.tapPanelRow(position) }
            }
        }
        .background(alignment: .top) { highlight(at: index, danger: false) }
    }

    private func rowView(_ row: BilibiliNativePlayer.PanelRow, focused: Bool) -> some View {
        let tint: Color = focused ? .black : .white.opacity(0.88)
        return HStack(spacing: 16) {
            switch row {
            case .up:
                BiliImage(url: player.info?.owner.face)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(.white.opacity(0.15)))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.info?.owner.name ?? player.current?.owner ?? "").font(.system(size: 26, weight: .bold)).lineLimit(1)
                    Text("UP主主页").font(.system(size: 19, weight: .medium)).opacity(0.6)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(0.5)
            case .like:
                icon(player.relation.liked ? "hand.thumbsup.fill" : "hand.thumbsup", lit: player.relation.liked, focused: focused)
                label(player.relation.liked ? "已点赞" : "点赞", value: player.info.map { biliCount($0.likes) })
            case .coin:
                CoinIcon(lit: player.relation.coins > 0, focused: focused, pink: pink).frame(width: 46)
                label(player.relation.coins > 0 ? "已投 \(player.relation.coins) 枚硬币" : "投币", value: player.info.map { biliCount($0.coins) },
                      more: !player.coinChoices.isEmpty)
            case .favorite:
                icon(player.relation.favorited ? "star.fill" : "star", lit: player.relation.favorited, focused: focused)
                label(player.relation.favorited ? "已收藏" : "收藏", value: player.info.map { biliCount($0.favorites) })
            case .episodes:
                icon("square.stack", lit: false, focused: focused)
                label("选集", value: player.episodeIndex.map { "\($0 + 1)/\(player.episodes.count)" } ?? "\(player.episodes.count) 集", more: true)
            case .speed:
                icon("speedometer", lit: false, focused: focused)
                label("倍速", value: BilibiliNativePlayer.speedName(player.speed), more: true)
            case .subtitles:
                icon("captions.bubble", lit: false, focused: focused)
                label("字幕", value: player.subtitleTracks.isEmpty ? "无" : (player.subtitleTrack?.name ?? "关闭"), more: !player.subtitleTracks.isEmpty)
            case .danmaku:
                icon(player.danmakuOn ? "text.bubble.fill" : "text.bubble", lit: false, focused: focused)
                label("弹幕", value: player.danmakuOn ? "打开" : "关闭", more: true)   // 里面有好几项，这里只写开没开
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 20)
    }

    /// 图标：点过赞、收藏过的是粉色（在白色高亮上是黑色）
    private func icon(_ name: String, lit: Bool, focused: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(focused ? Color.black : (lit ? pink : .white.opacity(0.88)))
            .frame(width: 46)
    }

    /// 一行的名字和右边的值。more = 选它会进下一层（倍速、字幕、弹幕、投币、选集）：值后面带一个 ">"。
    /// 没有 ">" 的行（点赞、收藏）也留着它的位置，这样每一行的数字右边都对在同一条竖线上
    private func label(_ title: String, value: String?, more: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if let value { Text(value).font(.system(size: 23, weight: .medium).monospacedDigit()).opacity(0.6).lineLimit(1).contentTransition(value.first?.isNumber == true ? .numericText() : .opacity) }
            Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(more ? 0.5 : 0)
        }
    }


    // MARK: 第二层：投几个币、倍速、字幕、确认取消收藏

    private func listHeader(_ list: BilibiliNativePlayer.PanelList) -> some View {
        let title = switch list {
        case .coins: "投币"
        case .speed: "倍速"
        case .subtitles: "字幕"
        case .unfavorite: "要取消收藏吗？"
        case .danmaku: "弹幕"
        }
        return HStack(spacing: 12) {
            Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
            Text(title).font(.system(size: 24, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.55))
        .padding(.leading, 20)
    }

    /// 小列表里的每一项：名字、右边的值（弹幕设置那一列才有）、要不要打勾
    private func optionTitles(_ list: BilibiliNativePlayer.PanelList) -> [(title: String, value: String?, checked: Bool)] {
        switch list {
        case .coins:
            return player.coinChoices.map { ("投 \($0) 枚硬币", nil, false) }
        case .speed:
            return BilibiliNativePlayer.speeds.map { (BilibiliNativePlayer.speedName($0), nil, $0 == player.speed) }
        case .subtitles:
            return [("关闭", nil, player.subtitleTrack == nil)] + player.subtitleTracks.map { ($0.name, nil, $0 == player.subtitleTrack) }
        case .unfavorite:
            return [("取消", nil, false), ("取消收藏", nil, false)]
        case .danmaku:
            return player.danmakuOptions.map { ($0.title, $0.value, false) }
        }
    }

    private func options(_ list: BilibiliNativePlayer.PanelList) -> some View {
        let items = optionTitles(list)
        let index = min(player.panelListIndex, max(0, items.count - 1))
        let danger = list == .unfavorite && index == 1
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                let focused = position == index
                HStack(spacing: 18) {
                    if let value = item.value {
                        // 弹幕设置：左边名字，右边现在的值，按确认换下一个
                        Text(item.title).font(.system(size: 24, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 8)
                        Text(value).font(.system(size: 23, weight: .medium)).opacity(0.6).contentTransition(.opacity)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 22, weight: .bold))
                            .frame(width: 46)
                            .opacity(item.checked ? 1 : 0)
                        Text(item.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .foregroundStyle(focused ? (danger ? .white : .black) : .white.opacity(0.88))
                .padding(.horizontal, 20)
                .frame(height: rowHeight)
                .contentShape(Rectangle())
                .onTapGesture { player.tapPanelList(position) }
            }
        }
        .background(alignment: .top) { highlight(at: index, danger: danger) }
    }

    private func highlight(at index: Int, danger: Bool) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(danger ? Color.destructive : .white)
            .frame(height: rowHeight)
            .offset(y: CGFloat(index) * (rowHeight + gap))
    }
}

/// 哔哩哔哩的硬币：一个圆圈里写着"币"
private struct CoinIcon: View {
    let lit: Bool
    let focused: Bool
    let pink: Color

    var body: some View {
        let color: Color = focused ? .black : (lit ? pink : .white.opacity(0.88))
        ZStack {
            Circle().strokeBorder(color, lineWidth: 3)
            Text("币").font(.system(size: 15, weight: .heavy)).foregroundStyle(color)
        }
        .frame(width: 31, height: 31)
    }
}

/// 字幕：画面下方居中，一句一句跟着播放进度换。控制条出来时往上让开
struct BilibiliSubtitleView: View {
    @ObservedObject var player: BilibiliNativePlayer
    let lifted: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: player.paused && !player.scrubbing)) { _ in
            if let line = BiliSubtitleCue.line(at: player.displayTime(), in: player.subtitleCues) {
                Text(line)
                    .font(.system(size: 44, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 4, y: 1)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: 1500)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, lifted ? 340 : 78)
        .animation(.easeOut(duration: 0.25), value: lifted)
        .allowsHitTesting(false)
    }
}

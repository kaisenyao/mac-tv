import SwiftUI

/// 哔哩哔哩的设置页（头像菜单里的"设置"）。和网易云的设置页一个样子：左边大头像和名字，
/// 右边一行行设置（左边名字，右边现在的值），白色高亮在行之间滑。清晰度、倍速、主屏顶部显示选了以后，右边换成一列档位；
/// 弹幕换成弹幕的几项设置；左边栏显示换成可以勾选的几页。
struct BilibiliSettingsPage: View {
    @ObservedObject var store: BilibiliStore
    @ObservedObject var player: BilibiliNativePlayer
    @Environment(\.canvasSize) private var canvas

    private let rowHeight: CGFloat = 104
    private let margin: CGFloat = 176

    var body: some View {
        HStack(alignment: .top, spacing: 100) {
            VStack(alignment: .leading, spacing: 0) {
                BiliImage(url: largeFace)
                    .frame(width: 400, height: 400)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                Text(store.account?.name ?? "").font(.tv(.headline, emphasized: true)).foregroundStyle(.white).lineLimit(1).padding(.top, 30)
                Text("设置").font(.tv(.body)).foregroundStyle(.white.opacity(0.6)).padding(.top, 8)
            }
            .frame(width: 460, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                if let list = store.settingList {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.left")
                        Text(title(of: list))
                    }
                    .font(.tvListDetail)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 30)
                    .frame(height: 56, alignment: .leading)
                    lines(options(list), index: store.settingListIndex) { store.tapSettingOption($0) }
                } else {
                    Color.clear.frame(height: 56)
                    lines(settings, index: store.settingIndex) { store.tapSetting($0) }
                }
            }
            .frame(width: 900, alignment: .topLeading)
            .padding(.top, 48)
        }
        .padding(.leading, margin)
        .padding(.top, 190)
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .animation(Motion.focus, value: store.settingIndex)
        .animation(Motion.focus, value: store.settingListIndex)
        .animation(Motion.press, value: store.settingList)
    }

    /// 设置页的大头像（列表上用的是小图，这里换成大一些的）
    private var largeFace: URL? { BiliAPI.resized(store.account?.face, to: "800w_800h_1c") }

    private var settings: [(title: String, value: String, checked: Bool, pick: Bool)] {
        BilibiliStore.Setting.allCases.map { setting in
            switch setting {
            case .quality: ("清晰度", BiliStream.name(of: player.preferredQuality), false, true)
            case .speed: ("倍速", BilibiliNativePlayer.speedName(player.speed), false, true)
            case .subtitles: ("字幕", player.subtitlesOn ? "打开" : "关闭", false, false)   // 开着时，视频有字幕就自动显示
            case .danmaku: ("弹幕", player.danmakuOn ? "打开" : "关闭", false, true)
            case .sidebar: ("边栏", BiliSidebar.summary(hidden: store.hiddenTabs), false, true)
            case .shelf: ("主屏幕顶部", BiliShelfSource.current.title, false, true)
            }
        }
    }

    private func title(of list: BilibiliStore.SettingList) -> String {
        switch list {
        case .quality: "清晰度"
        case .speed: "倍速"
        case .danmaku: "弹幕"
        case .sidebar: "边栏"
        case .shelf: "主屏幕顶部"
        }
    }

    private func options(_ list: BilibiliStore.SettingList) -> [(title: String, value: String, checked: Bool, pick: Bool)] {
        switch list {
        case .quality:
            let chosen = BilibiliStore.settableQualities.first { $0 <= player.preferredQuality }
            return BilibiliStore.settableQualities.map { (BiliStream.name(of: $0), "", $0 == chosen, false) }
        case .speed:
            return BilibiliNativePlayer.speeds.map { (BilibiliNativePlayer.speedName($0), "", $0 == player.speed, false) }
        case .danmaku:
            return player.danmakuOptions.map { ($0.title, $0.value, false, false) }
        case .sidebar:
            // 可以勾好几个：勾上的显示在左边栏里
            return BiliSidebar.choices.map { ($0.title, "", !store.hiddenTabs.contains($0), false) }
        case .shelf:
            // 选中哔哩哔哩的图标时，主屏上方轮播哪一种（各取最新的 8 个）
            return BiliShelfSource.allCases.map { ($0.title, "", $0 == BiliShelfSource.current, false) }
        }
    }

    private func lines(_ items: [(title: String, value: String, checked: Bool, pick: Bool)], index: Int,
                       tap: @escaping (Int) -> Void) -> some View {
        let focused = min(index, max(0, items.count - 1))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                let on = position == focused
                HStack(spacing: 18) {
                    if store.settingList != nil, store.settingList != .danmaku {
                        Image(systemName: "checkmark").font(.tvMenuSymbol).frame(width: 30).opacity(item.checked ? 1 : 0)
                    }
                    Text(item.title).font(.tvListTitle)
                    Spacer(minLength: 20)
                    Text(item.value).font(.tvListDetail).opacity(0.6).contentTransition(.opacity)
                    // 进下一层的行带 ">"；别的行也留着它的位置，右边的值对在同一条竖线上
                    Image(systemName: "chevron.right").font(.tvListDetail).opacity(item.pick ? 0.45 : 0)
                }
                .foregroundStyle(on ? .black : .white.opacity(0.9))
                .padding(.horizontal, 30)
                .frame(height: rowHeight - 8)
                .frame(height: rowHeight)
                .contentShape(Rectangle())
                .hoverWash()
                .onTapGesture { tap(position) }
            }
        }
        .background(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white)
                .frame(height: rowHeight - 8)
                .offset(y: CGFloat(focused) * rowHeight + 4)
        }
    }
}

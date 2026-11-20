import SwiftUI

/// 设置 › Apps › Top Shelf：YouTube 在主屏顶部放什么（为你推荐、继续观看、订阅更新）。
/// 哔哩哔哩、网易云、得到放什么在它们各自的设置里选
struct TopShelfPreferencesPanel: Equatable {
    /// 换过几次：放在面板的状态里，左右换一下按键音、震动才响
    var changes = 0
}

extension TVController {
    func openTopShelfPreferences() { topShelfPreferences = TopShelfPreferencesPanel() }

    func handleTopShelfPreferences(_ command: RemoteCommand) {
        guard topShelfPreferences != nil else { return }
        switch command {
        case .back: topShelfPreferences = nil
        case .move(.left): changeTopShelfPreference(direction: -1)
        case .move(.right), .select: changeTopShelfPreference(direction: 1)
        default: break
        }
    }

    /// 左右换 YouTube 放什么；连着按的话，停下来以后才按最后选的取一次
    func changeTopShelfPreference(direction: Int) {
        guard topShelfPreferences != nil else { return }
        topShelfPreferences?.changes += 1
        let all = YouTubeShelfSource.allCases
        let current = all.firstIndex(of: YouTubeShelfSource.current) ?? 0
        YouTubeShelfSource.current = all[(current + direction + all.count) % all.count]
        appShelf.sourceChangedSoon("youtube")
    }
}

struct TopShelfPreferencesSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Top Shelf").font(.system(size: 48, weight: .heavy))
                Spacer()
                Button("Done") { tv.topShelfPreferences = nil }.buttonStyle(.plain).font(.system(size: 24, weight: .semibold))
            }
            Button { tv.changeTopShelfPreference(direction: 1) } label: {
                HStack {
                    Text("YouTube")
                    Spacer()
                    Text(YouTubeShelfSource.current.title)
                    Image(systemName: "chevron.left.chevron.right")
                }
                .font(.system(size: 25, weight: .semibold)).padding(.horizontal, 24).frame(height: 58)
                .foregroundStyle(.black)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .padding(48).frame(width: 1100, alignment: .leading)
        .tvGlass(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white).frame(width: canvas.width, height: canvas.height)
    }
}

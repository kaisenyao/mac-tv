import AppKit
import Foundation
import Testing
@testable import MacTV

/// 打开它的键再按一次就收起（TVController.toggle）：手机上的快捷键、按住确认、按住 TV 键都一样。
/// 收起和按返回一样；开着的是别的菜单时，按下去换成它自己的
@Suite @MainActor
struct OpenAgainClosesTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    @Test func aShortcutOpensItsMenuThenClosesIt() throws {
        try withWatching { tv in
            let player = tv.bilibiliStore.player
            tv.runShortcut("bilibili.quality", from: .remote)       // 清晰度栏从上面下来
            #expect(player.qualityMenuVisible)
            tv.runShortcut("bilibili.quality", from: .remote)       // 再按一次：推回去，同返回
            #expect(!player.qualityMenuVisible && !player.panelVisible)

            tv.runShortcut("bilibili.speed", from: .remote)         // 面板拉出来，倍速的小列表开着
            #expect(player.panelVisible && player.panelList == .speed)
            tv.runShortcut("bilibili.speed", from: .remote)         // 再按一次：整个面板推回去，不只是收起小列表
            #expect(!player.panelVisible && player.panelList == nil)
            #expect(player.current != nil)                          // 视频还在放，没被当成返回关掉
        }
    }

    @Test func anotherShortcutSwitchesToItsOwnMenu() throws {
        try withWatching { tv in
            let player = tv.bilibiliStore.player
            tv.runShortcut("bilibili.quality", from: .remote)
            tv.runShortcut("bilibili.speed", from: .remote)         // 清晰度栏开着时按倍速：换成倍速
            #expect(!player.qualityMenuVisible && player.panelVisible && player.panelList == .speed)
            tv.runShortcut("bilibili.quality", from: .remote)       // 再换回清晰度
            #expect(player.qualityMenuVisible && !player.panelVisible)
            tv.runShortcut("bilibili.quality", from: .remote)
            #expect(!player.qualityMenuVisible)

            // 按住确认拉出来的面板停在倍速那一行、没展开：按倍速是展开它，不是收起
            #expect(tv.holdSelect(from: .keyboard))
            #expect(player.panelVisible && player.panelRow == .speed && player.panelList == nil)
            tv.runShortcut("bilibili.speed", from: .remote)
            #expect(player.panelVisible && player.panelList == .speed)
        }
    }

    @Test func aMenuUnderASheetComesBackInsteadOfClosing() throws {
        try withWatching { tv in
            let player = tv.bilibiliStore.player
            tv.runShortcut("bilibili.quality", from: .remote)
            tv.openControlCenter()                                  // 控制中心盖在上面：清晰度栏不在最上面
            tv.runShortcut("bilibili.quality", from: .remote)
            #expect(tv.controlCenter == nil && player.qualityMenuVisible)
        }
    }

    @Test func holdingOKTwiceOpensThenClosesTheHoldMenu() throws {
        try withWatching { tv in
            let player = tv.bilibiliStore.player
            @MainActor func hold() {
                tv.handle(.press(.select, .hold), from: .keyboard)
                tv.handle(.press(.select, .release), from: .keyboard)
            }
            hold()                                                  // 手机、Siri Remote 上按住 OK：面板拉出来
            #expect(player.panelVisible)
            hold()                                                  // 再按住：推回去，松手也不是一次确认
            #expect(!player.panelVisible && player.current != nil)

            tv.handle(.longSelect, from: .keyboard)                 // 旧版手机页的 okhold 也一样
            #expect(player.panelVisible)
            tv.handle(.longSelect, from: .keyboard)
            #expect(!player.panelVisible)

            // 快捷键拉出来的（面板里展开着倍速）：按住确认也是整个收起
            tv.runShortcut("bilibili.speed", from: .remote)
            hold()
            #expect(!player.panelVisible && player.panelList == nil)

            // 清晰度栏开着时按住确认不收它（它不是按住打开的）：照常是一次确认
            tv.runShortcut("bilibili.quality", from: .remote)
            #expect(!tv.holdSelect(from: .keyboard) && player.qualityMenuVisible)
        }
    }

    @Test func holdingHomeTwiceStillOpensThenClosesControlCenter() throws {
        try withTV { tv in
            @MainActor func hold() {
                tv.handle(.press(.home, .hold), from: .keyboard)
                tv.handle(.press(.home, .release), from: .keyboard)
            }
            hold()
            #expect(tv.controlCenter != nil)
            hold()
            #expect(tv.controlCenter == nil)
        }
    }

    // MARK: 搭台子

    private func withTV(_ body: @MainActor (TVController) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/open-again-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(TVController(library: AppLibrary(folder: folder)))
    }

    /// 哔哩哔哩开着、正看着一个视频（不联网：当作已经取到了三档清晰度）
    private func withWatching(_ body: @MainActor (TVController) throws -> Void) throws {
        try withTV { tv in
            tv.bilibiliOpen = true
            tv.bilibiliStore.player.pretendOpen(BiliVideo(bvid: "BV1open", title: "视频", cover: nil, duration: 600, owner: "UP", views: 0),
                                                qualities: [116, 80, 64])
            try body(tv)
        }
    }
}

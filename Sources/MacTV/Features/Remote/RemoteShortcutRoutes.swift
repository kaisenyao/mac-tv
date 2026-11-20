import AppKit

// The phone remote's shortcut chips on the Mac side: what `/state` says about them, the `/shortcuts` settings
// routes, and what a press does. The choice and the catalog are in RemoteShortcuts.

extension RemoteCoordinator {
    /// `/shortcuts` and below. Guests never get here: the server only lets them read `/state` and send `/cmd`.
    func handleShortcutsRequest(_ request: HTTPRequest) -> HTTPResponse? {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/shortcuts"):
            return .json(shortcutSettings())
        case ("POST", "/shortcuts/set"):
            guard let scope = body["scope"] as? String, let ids = body["ids"] as? [String] else {
                return .json(["error": "Send a scope and a list of shortcuts."], status: "400 Bad Request")
            }
            var choice = shortcutChoice
            if let problem = choice.choose(ids, for: scope) { return .json(["error": problem], status: "400 Bad Request") }
            shortcutChoice = choice
            return .json(shortcutSettings())
        case ("GET", "/shortcuts/apple"):
            // Asking the Shortcuts app takes a moment: off the main thread, and the answer follows when it's ready
            let list = listAppleShortcuts
            return .deferred {
                guard let names = await list() else {
                    return .json(["error": "Couldn't read your shortcuts from the Shortcuts app."], status: "500 Internal Server Error")
                }
                return .json(["names": names])
            }
        case ("POST", "/shortcuts/apple"):
            var choice = shortcutChoice
            guard let name = body["name"] as? String, choice.chooseAppleShortcut(name) else {
                return .json(["error": "Choose one of your shortcuts."], status: "400 Bad Request")
            }
            shortcutChoice = choice
            return .json(shortcutSettings())
        default:
            return nil
        }
    }

    /// What the settings pages need: each place's set, what each app can pick from, every shortcut's title and
    /// icon, and the Apple Shortcut "Run Shortcut" runs.
    func shortcutSettings() -> [String: Any] {
        let choice = shortcutChoice
        var catalog: [String: Any] = [:]
        for entry in RemoteShortcuts.catalog { catalog[entry.id] = ["title": entry.title, "icon": entry.icon] }
        return [
            "home": choice.set(for: RemoteShortcuts.home),
            "apps": RemoteShortcuts.apps.map { app -> [String: Any] in
                ["id": app.id, "name": app.name, "picked": choice.picked(in: app.id),
                 "available": RemoteShortcuts.own(of: app.id), "own": choice.hasOwn(app.id)]
            },
            "everywhere": RemoteShortcuts.everywhere,
            "catalog": catalog,
            "appleShortcut": choice.appleShortcut,
        ]
    }

    /// Runs the chosen Apple Shortcut (off the main thread, with a time limit). The TV says something only when it
    /// fails. False when there's none chosen or the last one hasn't finished.
    func runAppleShortcut() -> Bool {
        let name = shortcutChoice.appleShortcut
        guard tv != nil, !name.isEmpty, !appleShortcutRunning else { return false }
        appleShortcutRunning = true
        let run = runAppleShortcutNamed
        Task { @MainActor [weak self] in
            let outcome = await run(name)
            guard let self else { return }
            self.appleShortcutRunning = false
            if outcome != .done { self.tv?.showToast("Couldn't Run “\(name)”") }
        }
        return true
    }
}

extension TVController {
    /// How a shortcut chip looks right now: its value ("打开", "1080P+", "25 min"), whether pressing it does anything,
    /// and whether the phone handles the press itself.
    struct ShortcutStatus: Equatable {
        var value: String?
        var enabled = true
        var phone = false
    }

    /// Which set the phone shows: the app on screen when it has shortcuts of its own, otherwise Home's.
    /// 哔哩哔哩, 网易云音乐 and 得到 are Mac TV's own screens over the home screen (`mode` stays `.launcher`).
    var shortcutContext: String {
        guard mode == .launcher, externalBrowser == nil, !playbackCoordinator.iinaOpen else { return RemoteShortcuts.home }
        if bilibiliOpen { return BilibiliStore.appID }
        if neteaseOpen { return NeteaseStore.appID }
        if dedaoOpen { return DedaoStore.appID }
        return RemoteShortcuts.home
    }

    /// `/state`'s shortcuts: the context and its chips. Polled every few seconds, so it only reads what's at hand.
    func shortcutState() -> [String: Any] {
        let context = shortcutContext
        let choice = remoteCoordinator.shortcutChoice
        let items = choice.picked(in: context).compactMap { id -> [String: Any]? in
            guard let entry = RemoteShortcuts.entry(id) else { return nil }
            let status = shortcutStatus(id, appleShortcut: choice.appleShortcut)
            var item: [String: Any] = ["id": id, "title": entry.title, "icon": entry.icon,
                                       "enabled": status.enabled, "phone": status.phone]
            if let value = status.value { item["value"] = value }
            return item
        }
        return ["context": context, "items": items]
    }

    func shortcutStatus(_ id: String, appleShortcut: String) -> ShortcutStatus {
        // First-run setup and "Who's watching?" come first; the phone's own shortcuts still work
        let free = setup == nil && profilePicker == nil
        let bili = bilibiliStore.player, netease = neteaseStore, dedao = dedaoStore
        switch id {
        case "shortcut":
            return ShortcutStatus(value: appleShortcut.isEmpty ? nil : appleShortcut, phone: appleShortcut.isEmpty)
        case "screensaver":
            return ShortcutStatus(enabled: free && mode == .launcher && externalBrowser == nil && !playbackCoordinator.iinaOpen)
        case "sleepTimer":
            return ShortcutStatus(value: sleepMinutesLeft > 0 ? RemoteShortcuts.minutesText(sleepMinutesLeft) : nil, phone: true)
        case "files":
            return ShortcutStatus(phone: true)

        case "bilibili.danmaku":
            return ShortcutStatus(value: bili.danmakuOn ? "打开" : "关闭", enabled: free && bili.current != nil)
        case "bilibili.quality":
            return ShortcutStatus(value: bili.current == nil ? nil : bili.qualityShortName, enabled: free && bili.canOpenQualityMenu)
        case "bilibili.speed":
            return ShortcutStatus(value: bili.current == nil || bili.isLive ? nil : BilibiliNativePlayer.speedName(bili.speed),
                                  enabled: free && bili.panelOffers(.speed))
        case "bilibili.subtitles":
            let tracks = bili.subtitleTracks
            return ShortcutStatus(value: bili.current == nil || bili.isLive ? nil : (tracks.isEmpty ? "无" : bili.subtitleTrack?.name ?? "关闭"),
                                  enabled: free && bili.panelOffers(.subtitles) && !tracks.isEmpty)
        case "bilibili.episodes":
            return ShortcutStatus(value: bili.canShowEpisodes ? bili.episodeIndex.map { "\($0 + 1)/\(bili.episodes.count)" } : nil,
                                  enabled: free && bili.canShowEpisodes)
        case "bilibili.coin":
            return ShortcutStatus(enabled: free && bili.panelOffers(.coin))
        case "bilibili.favorite":
            return ShortcutStatus(value: bili.current != nil && bili.relation.favorited ? "已收藏" : nil,
                                  enabled: free && bili.panelOffers(.favorite))

        case "netease.like":
            return ShortcutStatus(value: netease.currentLiked ? "已喜欢" : nil, enabled: free && netease.remoteReady && netease.current != nil)
        case "netease.lyrics":
            return ShortcutStatus(value: netease.current == nil ? nil : (netease.nowPlayingVisible ? "打开" : "关闭"),
                                  enabled: free && netease.canToggleNowPlaying)
        case "netease.mode":
            return ShortcutStatus(value: netease.account == nil ? nil : netease.mode.title, enabled: free && netease.remoteReady)
        case "netease.daily":
            return ShortcutStatus(enabled: free && netease.remoteReady)

        case "dedao.speed":
            return ShortcutStatus(value: dedao.remoteReady ? DedaoStore.speedText(dedao.player.speed) : nil, enabled: free && dedao.remoteReady)
        case "dedao.transcript":
            return ShortcutStatus(value: dedao.remoteReady ? (dedao.playerOpen ? "打开" : "关闭") : nil, enabled: free && dedao.remoteReady)
        case "dedao.timer":
            return ShortcutStatus(value: dedao.sleepLeft(), enabled: free && dedao.remoteReady)
        case "dedao.next":
            return ShortcutStatus(enabled: free && dedao.canStepLecture(1))
        case "dedao.previous":
            return ShortcutStatus(enabled: free && dedao.canStepLecture(-1))
        default:
            return ShortcutStatus(enabled: false)
        }
    }

    /// A shortcut chip pressed on the phone. One that isn't for the screen that's up, does nothing right now, or is
    /// the phone's own (the sleep timer, files) is ignored. What it does is what the TV's own key, menu or panel
    /// does, with the select sound when it did something on Mac TV's screens. A shortcut whose menu is the one up
    /// closes it instead, like Back (TVController.toggle).
    func runShortcut(_ id: String, from source: Feedback.Source) {
        guard let entry = RemoteShortcuts.entry(id), entry.app == nil || entry.app == shortcutContext else { return }
        let status = shortcutStatus(id, appleShortcut: remoteCoordinator.shortcutChoice.appleShortcut)
        guard status.enabled, !status.phone else { return }
        // The app's menus and toasts show in Mac TV's window
        if entry.app != nil || id == "screensaver", !NSApp.isActive { bringToFront() }
        guard let cue = toggle(close: { closeShortcutMenu(id) }, open: { performShortcut(id) }) else { return }
        if mode == .launcher { feedback.play(cue, from: source) }
    }

    /// The menu, list or page this shortcut opens is the one on top: closes it, as Back does (all of it: a panel the
    /// shortcut slid out goes back in, not just its list). False when it isn't up, so the press opens it. Shortcuts
    /// that open nothing (弹幕, 喜欢, 播放模式, 得到's 倍速 and 上一讲 / 下一讲) or already flip (歌词, 文稿) never close.
    private func closeShortcutMenu(_ id: String) -> Bool {
        guard activeSheet == nil else { return false }   // under a sheet it isn't the one up: the press brings it back
        let bili = bilibiliStore.player
        switch id {
        case "bilibili.quality": return bili.closeQualityMenu()
        case "bilibili.speed": return bili.closePanel(showing: .speed)
        case "bilibili.subtitles": return bili.closePanel(showing: .subtitles)
        case "bilibili.coin": return bili.closePanel(showing: .coin)
        case "bilibili.favorite": return bili.closePanel(showing: .favorite)   // 取消收藏？ goes away as 取消 would
        case "bilibili.episodes": return bili.closeEpisodes()
        case "netease.daily": return neteaseStore.closeDaily()
        case "dedao.timer": return dedaoStore.closeSleepMenu()
        default: return false
        }
    }

    private func performShortcut(_ id: String) -> Bool {
        let bili = bilibiliStore.player
        switch id {
        case "shortcut": return remoteCoordinator.runAppleShortcut()
        case "screensaver":
            showScreensaver()
            return screensaver
        case "bilibili.danmaku": bili.toggleDanmaku(); return true
        case "bilibili.quality": return overSheets { bili.openQualityMenu() }
        case "bilibili.speed": return overSheets { bili.openPanel(at: .speed) }
        case "bilibili.subtitles": return overSheets { bili.openPanel(at: .subtitles) }
        case "bilibili.episodes": return overSheets { bili.showEpisodes() }
        case "bilibili.coin": return overSheets { bili.openPanel(at: .coin) }
        case "bilibili.favorite": return overSheets { bili.favoriteFromRemote() }
        case "netease.like": return neteaseStore.toggleLikeCurrent()
        case "netease.lyrics": return overSheets { neteaseStore.toggleNowPlaying() }
        case "netease.mode": return neteaseStore.cycleModeFromRemote()
        case "netease.daily": return overSheets { neteaseStore.openDaily() }
        case "dedao.speed": return dedaoStore.nextSpeed()
        case "dedao.transcript": return overSheets { dedaoStore.togglePlayerFromRemote() }
        case "dedao.timer": return overSheets { dedaoStore.openSleepMenu() }
        case "dedao.next": return dedaoStore.stepLecture(1)
        case "dedao.previous": return dedaoStore.stepLecture(-1)
        default: return false
        }
    }

    /// Opens one of the app's own menus or screens: the sheets over the app close first, as for Home and Control Center.
    private func overSheets(_ open: () -> Bool) -> Bool {
        sheets.closeDismissible()
        return open()
    }
}

import AppKit

// Focus on the home screen: the app grid, the Top Shelf and the status row.
extension TVController {
    /// The status row's buttons, left to right. The lid staying awake is a glyph beside the time, not a button:
    /// Control Center's Lid Closed switches it.
    var statusItems: [StatusItem] { [.controlCenter, .profile] }

    /// The top-row app whose content the Top Shelf shows.
    var shelfService: Service { services.indices.contains(shelfAppIndex) ? services[shelfAppIndex] : services[0] }

    /// True when focus is below the top row; the Top Shelf scrolls away.
    var inGrid: Bool {
        if case .app(let index) = focus { return index >= columns }
        return false
    }

    /// How many things in the Top Shelf can take focus: its Open button, for apps.
    var shelfCount: Int {
        // 哔哩哔哩、网易云、YouTube：顶部轮播的按钮（播放，或者直播的观看直播）
        if AppShelf.services.contains(shelfService.id), appShelf.current(for: shelfService.id) != nil {
            return appShelf.actions(for: shelfService.id).count
        }
        switch shelfService.kind {
        case .web, .app, .steam, .movies: return 1
        case .addApp, .settings: return 0
        }
    }

    func hover(_ index: Int, tilt: CGSize) {
        guard !suppressHover else { return }
        switch focus {
        case .shelf, .status: return
        case .app: break
        }
        guard (index >= columns) == inGrid else { return }
        if focus != .app(index) { feedback.play(.move, from: .pointer) }
        setFocus(.app(index))
        self.tilt = tilt
    }

    func moveFocus(_ direction: RemoteCommand.Direction) {
        switch focus {
        case .app(let index):
            let row = index / columns, column = index % columns
            switch direction {
            case .left:
                if column > 0 { setFocus(.app(index - 1)) }
            case .right:
                if column < columns - 1, index + 1 < services.count { setFocus(.app(index + 1)) }
            case .down:
                if index + columns < services.count {
                    setFocus(.app(index + columns))
                } else if (row + 1) * columns < services.count {
                    setFocus(.app(services.count - 1))
                }
            case .up:
                if row > 0 {
                    setFocus(.app(index - columns))
                } else if shelfCount > 0 {
                    setFocus(.shelf(0))
                } else {
                    setFocus(.status(.controlCenter))
                }
            }
        case .shelf(let index):
            // 哔哩哔哩、网易云、YouTube 的轮播：在第一个按钮上再往左是上一个，最后一个上再往右是下一个（焦点回到"播放"）
            let carousel = AppShelf.services.contains(shelfService.id) && appShelf.current(for: shelfService.id) != nil
            switch direction {
            case .left:
                if index > 0 { setFocus(.shelf(index - 1)) }
                else if carousel { appShelf.step(shelfService.id, by: -1); setFocus(.shelf(0)) }
            case .right:
                if index + 1 < shelfCount { setFocus(.shelf(index + 1)) }
                else if carousel { appShelf.step(shelfService.id, by: 1); setFocus(.shelf(0)) }
            case .down: setFocus(.app(shelfAppIndex))
            case .up: setFocus(.status(.controlCenter))
            }
        case .status(let item):
            let items = statusItems
            let index = items.firstIndex(of: item) ?? items.firstIndex(of: .controlCenter) ?? 0
            switch direction {
            case .left: setFocus(.status(items[max(0, index - 1)]))
            case .right: setFocus(.status(items[min(items.count - 1, index + 1)]))
            case .down: setFocus(shelfCount > 0 ? .shelf(0) : .app(shelfAppIndex))
            case .up: break
            }
        }
    }

    func activateStatus(_ item: StatusItem) {
        setFocus(.status(item))
        switch item {
        case .lid: openSettings(to: .lidOverride)
        case .controlCenter: openControlCenter()
        case .profile: openProfiles(dropdown: true)
        }
    }

    /// The film showing on Videos' Top Shelf now (its films take turns on the shelf's beat).
    var videosShelfFilm: Movie? {
        let shelf = movieLibrary.shelf
        guard !shelf.isEmpty else { return nil }
        return movieLibrary.movie(shelf[appShelf.beat % shelf.count].path)
    }

    func activateShelf(_ index: Int) {
        let id = shelfService.id
        // Videos: Play (or Resume) the film showing, as Apple TV's Top Shelf does; with none, the app
        if case .movies = shelfService.kind, let film = videosShelfFilm {
            openApp(shelfService.id)
            playFromMovies(film)
            return
        }
        if AppShelf.services.contains(id), appShelf.current(for: id) != nil {
            let actions = appShelf.actions(for: id)
            if actions.indices.contains(index) { appShelf.activate(actions[index], for: id) }
            return
        }
        open(shelfService)
    }
}

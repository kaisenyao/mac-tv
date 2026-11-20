import AppKit

// The home screen's apps: arranging, adding, hiding and deleting them. Home's first six apps are its top row,
// the dock; Arrange Apps (and the phone's Edit) move apps into and out of it.
extension TVController {
    var arrangedServices: [Service] { services.filter { $0.kind != .addApp && $0.kind != .settings } }

    /// The apps Home shows, by id, in order. The first six are the dock.
    var appOrder: [String] { arrangedServices.map(\.id) }

    /// Moves an app to `index` in Home's order. Into a full dock, its last app goes to the first place below;
    /// out of the dock, the first app below comes up into it.
    @discardableResult
    func moveApp(_ id: String, to index: Int) -> Bool {
        guard appOrder.contains(id) else { return false }
        guard library.move(id, to: index) else { showToast("Couldn't save that app's position."); return false }
        reloadServices()
        return true
    }

    /// Adds a website. Its tile appears at once; the official icon follows when found. A site someone already
    /// added comes back instead, shown again here if this profile hid it.
    func addWebsite(name: String?, address: String) -> AddedApp? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host(), host.contains(".") else { return nil }
        if let existing = reuseAddedApp(library.addedApp(url: url)) { return existing }
        let fallbackName = host.replacingOccurrences(of: "www.", with: "").split(separator: ".").first.map {
            $0.prefix(1).uppercased() + $0.dropFirst()
        } ?? host
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let app = library.add(name: trimmed.isEmpty ? fallbackName : trimmed, url: url, bundleID: nil)
        reloadServices()
        let origin = library
        Task { [weak self] in
            let png = await IconFinder.icon(forSite: url, name: app.name)
            await MainActor.run { self?.useIcon(png, for: app.id, in: origin) }
        }
        return app
    }

    func addMacApp(bundleID: String) -> AddedApp? {
        guard let installed = InstalledApps.all.first(where: { $0.bundleID == bundleID }) else { return nil }
        if let existing = services.first(where: { $0.kind == .app(bundleID: bundleID) }) {
            showToast("\(existing.name) is already on the home screen")
            return nil
        }
        if let existing = reuseAddedApp(library.addedApp(bundleID: bundleID)) { return existing }
        let app = library.add(name: installed.name, url: nil, bundleID: bundleID)
        useIcon(IconFinder.icon(forAppAt: installed.path), for: app.id)
        return app
    }

    /// Adds a Steam game (or Steam Big Picture). Its tile appears at once; Steam's artwork follows.
    func addSteamGame(_ game: SteamLibrary.Game) -> AddedApp? {
        if let existing = services.first(where: { $0.kind == .steam(appID: game.appID) }) {
            showToast("\(existing.name) is already on the home screen")
            return nil
        }
        if let existing = reuseAddedApp(library.addedApp(steamID: game.appID)) { return existing }
        let app = library.add(name: game.name, url: nil, bundleID: nil, steamID: game.appID)
        reloadServices()
        if game == SteamLibrary.bigPicture {
            useIcon(SteamLibrary.appURL.flatMap { IconFinder.icon(forAppAt: $0.path) }, for: app.id)
        } else {
            Task { await fetchSteamArt(appID: game.appID, id: app.id, in: library) }
        }
        return app
    }

    /// An app someone already added: shown again (last on Home) if this profile hid it.
    private func reuseAddedApp(_ existing: AddedApp?) -> AddedApp? {
        guard let existing else { return nil }
        if library.isHidden(existing.id) || !appOrder.contains(existing.id) {
            library.showAgain(existing.id)
            reloadServices()
        }
        return existing
    }

    /// Downloads missing Steam tile / Top Shelf art for games already on the dock.
    func ensureSteamHeroes() {
        let origin = library
        for service in services {
            guard case .steam(let appID) = service.kind, appID != SteamLibrary.bigPicture.appID else { continue }
            let tileMissing = !FileManager.default.fileExists(atPath: origin.iconFile(for: service.id).path)
            let heroMissing = !FileManager.default.fileExists(atPath: origin.heroFile(for: service.id).path)
            guard tileMissing || heroMissing else { continue }
            Task { await fetchSteamArt(appID: appID, id: service.id, in: origin, tile: tileMissing) }
        }
    }

    /// Adds shelf-art samples if needed and (re)downloads tile + hero for each.
    func seedSteamShelfSamples() async {
        for game in SteamLibrary.shelfArtSamples {
            let id: String
            if let existing = services.first(where: { $0.kind == .steam(appID: game.appID) }) {
                id = existing.id
            } else if let existing = reuseAddedApp(library.addedApp(steamID: game.appID)) {
                id = existing.id
            } else {
                let app = library.add(name: game.name, url: nil, bundleID: nil, steamID: game.appID)
                reloadServices()
                id = app.id
            }
            await fetchSteamArt(appID: game.appID, id: id, in: library)
        }
    }

    @discardableResult
    private func fetchSteamArt(appID: String, id: String, in origin: AppLibrary, tile: Bool = true) async -> Bool {
        async let tilePNG: Data? = tile ? SteamLibrary.tile(for: appID) : nil
        async let heroJPEG = SteamLibrary.hero(for: appID)
        let (png, hero) = await (tilePNG, heroJPEG)
        return await MainActor.run {
            guard origin.containsAddedApp(id) else { return false }
            if let png { useIcon(png, for: id, in: origin) }
            if let hero {
                origin.setHero(hero, for: id)
                if origin === library { objectWillChange.send() }
            }
            return png != nil || hero != nil
        }
    }

    /// The icon of an app someone added. Icons are everyone's, so Home redraws whoever is watching now.
    func useIcon(_ png: Data?, for id: String, in origin: AppLibrary? = nil) {
        let target = origin ?? library
        guard target.containsAddedApp(id) else { return }
        if let png, let image = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            target.setIcon(png, accent: TileArt.brandColor(from: image), for: id)
        }
        Icons.forget(id)
        if target === library || library.containsAddedApp(id) { reloadServices() }
    }

    /// Hide: the app leaves this profile's Home. Built-in apps come back with Restore Built-in Apps; an app
    /// someone added comes back by adding it again.
    func hideApp(_ id: String) {
        guard appOrder.contains(id) else { return }
        library.hide(id)
        reloadServices()
    }

    /// Delete for Everyone: an app someone added goes from every profile's Home; its icon and art go to the Trash.
    /// Built-in apps can only be hidden. Returns what went wrong, if anything.
    @discardableResult
    func deleteAppForEveryone(_ id: String) -> String? {
        let name = services.first { $0.id == id }?.name ?? "the app"
        switch library.deleteForEveryone(id) {
        case .deleted:
            Icons.forget(id)
            reloadServices()
            return nil
        case .notAdded:
            return "Built-in apps can’t be deleted. You can hide them."
        case .trashFailed:
            let message = "Couldn’t move “\(name)” to the Trash. Nothing was deleted."
            showToast(message)
            return message
        case .notSaved:
            let message = "Couldn’t delete “\(name)”. Check available storage and folder permissions."
            showToast(message)
            return message
        }
    }

    func restoreBuiltInApps() {
        library.restoreBuiltIns()
        reloadServices()
    }

    func iconPNG(for id: String) -> Data? {
        services.first { $0.id == id }.flatMap { Icons.png(for: $0) }
    }
}

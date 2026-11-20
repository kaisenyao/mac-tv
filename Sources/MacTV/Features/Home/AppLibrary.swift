import AppKit

/// ~/Library/Application Support/Mac TV, where added apps and their icons live.
/// Data from the app's earlier name ("Matinee") moves over on first run.
enum AppFolder {
    static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["MACTV_DATA_DIR"], path.hasPrefix("/") {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Mac TV", isDirectory: true)
        let earlier = support.appendingPathComponent("Matinee", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path), FileManager.default.fileExists(atPath: earlier.path) {
            Log.app.attempt("Moving the Matinee folder") { try FileManager.default.moveItem(at: earlier, to: folder) }
        }
        Log.app.attempt("Creating the data folder") {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Earlier versions kept a list of what was watched; Mac TV no longer records one.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("history.json"))
        return folder
    }()
}

/// An app the user added: a website, or a Mac app.
struct AddedApp: Codable, Hashable {
    let id: String
    var name: String
    var url: URL?
    var bundleID: String?
    var steamID: String?
    /// The icon's brand colour, found once the icon arrives; tints its Top Shelf.
    var accent: String?
}

/// Mac TV's files that people made or chose (an added app's icon and art, a profile's folder and photo) go to the
/// Mac's Trash, never straight out of existence: there's no server or store to get them back from.
enum MacTrash {
    /// Moves an item to the Trash and says where it went.
    typealias Mover = @Sendable (URL) throws -> URL?

    static let system: Mover = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    /// For a test or a separate data folder: a Trash folder inside it, so the Mac's own Trash is never touched.
    static func folder(_ folder: URL) -> Mover {
        { url in
            let bin = folder.appendingPathComponent("Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let target = bin.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    /// The Mac's Trash for Mac TV's real folder in Application Support, a Trash folder inside any other.
    static func `for`(_ folder: URL) -> Mover {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Mac TV", isDirectory: true).standardizedFileURL.path
        return folder.standardizedFileURL.path == support ? system : Self.folder(folder)
    }
}

/// The home screen's apps for one profile. The apps people add are everyone's: apps.json keeps them, with the
/// main profile's layout beside them as before. Every other profile keeps only its own layout, the apps it
/// hides and Home's order, in apps-<profile>.json. Home's first six apps are its top row, the dock.
@MainActor
final class AppLibrary {
    /// How many apps Home's top row, the dock, holds. Every row below holds as many.
    nonisolated static let dockSize = 6

    /// apps.json or apps-<profile>.json. Only apps.json has `added`. `pinned` is from earlier versions: it's read
    /// once so Home keeps its order (see `keepHomeOrder`), and written only while a file still has it.
    private struct Saved: Codable {
        var added: [AddedApp]?
        var hidden: Set<String> = []
        var order: [String] = []
        var pinned: Set<String> = []

        init() {}

        private enum CodingKeys: String, CodingKey { case added, hidden, order, pinned }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            added = try values.decodeIfPresent([AddedApp].self, forKey: .added)
            hidden = try values.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
            order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
            pinned = try values.decodeIfPresent(Set<String>.self, forKey: .pinned) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(added, forKey: .added)
            try values.encode(hidden, forKey: .hidden)
            try values.encode(order, forKey: .order)
            if !pinned.isEmpty { try values.encode(pinned, forKey: .pinned) }
        }
    }

    /// The apps people added, everyone's (apps.json).
    private var added: [AddedApp] = []
    /// This profile's layout: the apps it hides, and Home's order (hidden and unavailable apps keep their places).
    private var hidden: Set<String> = []
    private var order: [String] = []
    private let isMain: Bool
    private let sharedFile: URL
    private let layoutFile: URL
    let iconsFolder: URL
    let storageFolder: URL
    /// Where Delete for Everyone moves an app's files: the Mac's Trash for Mac TV's own folder (see MacTrash.for).
    let trash: MacTrash.Mover

    init(profileID: String = Profile.mainID, folder: URL = AppFolder.url, trash: MacTrash.Mover? = nil) {
        storageFolder = folder
        self.trash = trash ?? MacTrash.for(folder)
        let icons = folder.appendingPathComponent("Icons", isDirectory: true)
        iconsFolder = icons
        Log.app.attempt("Creating the icons folder") {
            try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        }
        isMain = profileID == Profile.mainID
        sharedFile = folder.appendingPathComponent("apps.json")
        layoutFile = isMain ? sharedFile : folder.appendingPathComponent("apps-\(profileID).json")
        Self.gatherAddedApps(in: folder, into: sharedFile)
        added = (try? Self.read(sharedFile))?.added ?? []
        let layout = try? Self.read(layoutFile)
        hidden = layout?.hidden ?? []
        order = layout?.order ?? []
        if let pinned = layout?.pinned, !pinned.isEmpty { keepHomeOrder(pinned) }
    }

    // MARK: Home's order

    /// Home's apps in order: the ones this profile shows, then Add App and Settings. The first six are the dock.
    func services() -> [Service] {
        visibleApps + Catalog.services.filter { !Self.canArrange($0) }
    }

    /// The apps Home shows, in order, by id. Add App and Settings, which always come last, aren't among them.
    func arrangement() -> [String] { visibleApps.map(\.id) }

    /// Puts the apps on show in this order. It must hold exactly those apps, each once. Hidden and unavailable
    /// apps keep their places.
    @discardableResult
    func arrange(_ ids: [String]) -> Bool {
        let shown = Set(arrangement())
        guard ids.count == shown.count, Set(ids) == shown else { return false }
        var newOrder = orderedApps.map(\.id)
        for (slot, id) in zip(newOrder.indices.filter { shown.contains(newOrder[$0]) }, ids) { newOrder[slot] = id }
        let previous = order
        order = newOrder
        guard saveLayout() else { order = previous; return false }
        return true
    }

    /// Moves an app to `index` in Home's order (0 is the dock's first place). The apps from there on move along
    /// one place: into a full dock, its last app goes to the first place below; out of the dock, the first app
    /// below comes up into it.
    @discardableResult
    func move(_ id: String, to index: Int) -> Bool {
        var ids = arrangement()
        guard let from = ids.firstIndex(of: id) else { return false }
        ids.remove(at: from)
        ids.insert(id, at: min(max(index, 0), ids.count))
        return arrange(ids)
    }

    private static func canArrange(_ service: Service) -> Bool {
        service.kind != .addApp && service.kind != .settings
    }

    private static func isBuiltIn(_ id: String) -> Bool {
        Catalog.services.contains { $0.id == id && canArrange($0) }
    }

    /// Every app this profile could show, in Home's order, hidden and unavailable ones too so their places
    /// survive. Apps added since the order was saved, by anyone, come last.
    private var orderedApps: [Service] {
        let apps = Catalog.services.filter(Self.canArrange) + added.compactMap(service(for:))
        var remaining = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = order.compactMap { remaining.removeValue(forKey: $0) }
        return ordered + apps.filter { remaining.removeValue(forKey: $0.id) != nil }
    }

    private var visibleApps: [Service] {
        orderedApps.filter { !hidden.contains($0.id) && $0.isAvailable }
    }

    /// Earlier versions put favorites first on Home (at most six of them). That order becomes Home's order,
    /// once, so Home looks the same, and the favorites go.
    private func keepHomeOrder(_ pinned: Set<String>) {
        let dock = Array(visibleApps.map(\.id).filter(pinned.contains).prefix(Self.dockSize))
        order = dock + orderedApps.map(\.id).filter { !dock.contains($0) }
        saveLayout()
    }

    // MARK: Hiding

    func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    /// This profile hides a built-in app (Restore Built-in Apps brings them back).
    var hasHiddenBuiltIns: Bool { hidden.contains(where: Self.isBuiltIn) }

    /// This profile has arranged or hidden apps at some point.
    var hasSavedApps: Bool { FileManager.default.fileExists(atPath: layoutFile.path) }

    /// Shows or hides an app for this profile only, a built-in app or one someone added.
    @discardableResult
    func setHidden(_ id: String, _ hide: Bool) -> Bool {
        let previous = hidden
        if hide { hidden.insert(id) } else { hidden.remove(id) }
        guard saveLayout() else { hidden = previous; return false }
        return true
    }

    /// Hide: the app leaves this profile's Home only.
    @discardableResult
    func hide(_ id: String) -> Bool {
        guard orderedApps.contains(where: { $0.id == id }) else { return false }
        return setHidden(id, true)
    }

    /// Brings back the built-in apps this profile hid.
    func restoreBuiltIns() {
        let previous = hidden
        hidden = hidden.filter { !Self.isBuiltIn($0) }
        if !saveLayout() { hidden = previous }
    }

    // MARK: Apps people added

    func containsAddedApp(_ id: String) -> Bool { added.contains { $0.id == id } }

    /// The app someone already added for this website, Mac app or Steam game.
    func addedApp(url: URL? = nil, bundleID: String? = nil, steamID: String? = nil) -> AddedApp? {
        reloadAdded()
        return added.first { app in
            if let bundleID { return app.bundleID == bundleID }
            if let steamID { return app.steamID == steamID }
            if let url, let other = app.url { return Self.site(url) == Self.site(other) }
            return false
        }
    }

    /// A website by host and path: www., letter case and a trailing slash don't make it another site.
    private static func site(_ url: URL) -> String {
        var host = (url.host() ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host + "/" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    /// Adds an app for everyone; it comes last on every profile's Home. Its id is new among everyone's apps.
    @discardableResult
    func add(name: String, url: URL?, bundleID: String?, steamID: String? = nil) -> AddedApp {
        let base = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let stem = "user-" + (base.isEmpty ? "app" : base)
        var app = AddedApp(id: stem, name: name, url: url, bundleID: bundleID, steamID: steamID)
        let pick = { (list: [AddedApp]) -> AddedApp in
            let taken = Set(Catalog.services.map(\.id) + list.map(\.id))
            var id = stem
            while taken.contains(id) { id = "\(stem)-\(Int.random(in: 1000...9999))" }
            return AddedApp(id: id, name: name, url: url, bundleID: bundleID, steamID: steamID)
        }
        if !updateAdded({ list in app = pick(list); list.append(app) }) {
            app = pick(added)
            added.append(app)
        }
        // A new app doesn't inherit an old entry of this profile's layout.
        if order.contains(app.id) || hidden.contains(app.id) {
            order.removeAll { $0 == app.id }
            hidden.remove(app.id)
            saveLayout()
        }
        return app
    }

    /// Shows an app this profile hid again, last on Home, as if just added.
    @discardableResult
    func showAgain(_ id: String) -> Bool {
        let previous = (hidden, order)
        hidden.remove(id)
        order.removeAll { $0 == id }
        guard saveLayout() else { (hidden, order) = previous; return false }
        return true
    }

    enum DeleteOutcome: Equatable {
        case deleted
        /// Only an app someone added can be deleted; built-in apps can only be hidden.
        case notAdded
        /// Its files couldn't go to the Trash: everything is kept as it was.
        case trashFailed
        case notSaved
    }

    /// Delete for Everyone: an app someone added (a website, a Mac app or a Steam game) goes from every profile.
    /// The files Mac TV keeps for it, its icon and art in Mac TV's Icons folder, go to the Trash, never straight
    /// away; nothing outside that folder is touched (the Mac app itself, Steam's files, the website). If they
    /// can't go to the Trash, nothing changes.
    @discardableResult
    func deleteForEveryone(_ id: String) -> DeleteOutcome {
        reloadAdded()
        guard !Self.isBuiltIn(id), Catalog.services.allSatisfy({ $0.id != id }), containsAddedApp(id) else { return .notAdded }
        var trashed: [(from: URL, to: URL)] = []
        for file in ownFiles(of: id) {
            do {
                if let to = try trash(file) { trashed.append((file, to)) }
            } catch {
                putBack(trashed)
                return .trashFailed
            }
        }
        guard updateAdded({ $0.removeAll { $0.id == id } }) else {
            putBack(trashed)
            return .notSaved
        }
        SteamShelfArt.forget(heroFile(for: id))
        order.removeAll { $0 == id }
        hidden.remove(id)
        // Every profile's layout forgets it, so an app added later under the same id starts afresh.
        for file in [sharedFile] + Self.profileFiles(in: storageFolder) {
            _ = Self.update(file) { $0.order.removeAll { $0 == id }; $0.hidden.remove(id); $0.pinned.remove(id) }
        }
        return .deleted
    }

    /// The files Mac TV keeps for an added app that exist: only ever inside its own Icons folder.
    private func ownFiles(of id: String) -> [URL] {
        let icons = iconsFolder.standardizedFileURL.path
        return [iconFile(for: id), heroFile(for: id)].filter { file in
            file.standardizedFileURL.deletingLastPathComponent().path == icons
                && FileManager.default.fileExists(atPath: file.path)
        }
    }

    /// Brings files back from the Trash when the rest of a delete couldn't happen.
    private func putBack(_ trashed: [(from: URL, to: URL)]) {
        for item in trashed {
            Log.app.attempt("Putting back an app's file") { try FileManager.default.moveItem(at: item.to, to: item.from) }
        }
    }

    func iconFile(for id: String) -> URL { iconsFolder.appendingPathComponent("\(id).png") }
    /// Steam library hero (often 3840×1240) for the Top Shelf; separate from the dock tile PNG.
    func heroFile(for id: String) -> URL { iconsFolder.appendingPathComponent("\(id)-hero.jpg") }

    private func service(for app: AddedApp) -> Service? {
        let kind: Service.Kind
        if let url = app.url { kind = .web(url) }
        else if let bundleID = app.bundleID { kind = .app(bundleID: bundleID) }
        else if let steamID = app.steamID { kind = .steam(appID: steamID) }
        else { return nil }
        let icon = iconFile(for: app.id)
        let accent = app.accent ?? "#8E8E93"
        return Service(id: app.id, name: app.name, kind: kind,
                       iconFile: FileManager.default.fileExists(atPath: icon.path) ? icon : nil,
                       accent: accent, deep: Self.darkened(accent))
    }

    func setIcon(_ png: Data, accent: String?, for id: String) {
        guard containsAddedApp(id) else { return }
        Log.app.attempt("Saving an app icon") { try png.write(to: iconFile(for: id), options: .atomic) }
        updateAdded { list in
            if let index = list.firstIndex(where: { $0.id == id }) { list[index].accent = accent }
        }
    }

    func setHero(_ jpeg: Data, for id: String) {
        guard containsAddedApp(id) else { return }
        Log.app.attempt("Saving Steam hero art") { try jpeg.write(to: heroFile(for: id), options: .atomic) }
        SteamShelfArt.forget(heroFile(for: id))
    }

    // MARK: Files

    /// This profile's layout: in apps.json for the main profile, beside the shared apps, as it always was; in
    /// its own file for the others. The parts of the file it doesn't own stay as they are on disk.
    @discardableResult
    private func saveLayout() -> Bool {
        let hidden = hidden, order = order
        return Self.update(layoutFile) { file in
            file.hidden = hidden
            file.order = order
            file.pinned = []
        }
    }

    /// Changes the shared list as it is on disk now, so apps another profile added meanwhile stay.
    @discardableResult
    private func updateAdded(_ change: (inout [AddedApp]) -> Void) -> Bool {
        var list: [AddedApp] = []
        let saved = Self.update(sharedFile) { file in
            list = file.added ?? []
            change(&list)
            file.added = list
        }
        if saved { added = list }
        return saved
    }

    private func reloadAdded() {
        if let file = try? Self.read(sharedFile), let list = file.added { added = list }
    }

    private static func profileFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("apps-") && $0.hasSuffix(".json") }
            .map { folder.appendingPathComponent($0) }
    }

    /// A missing file reads as nil. One that can't be read throws, so it's never written over.
    private static func read(_ url: URL) throws -> Saved? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
    }

    /// Changes a file as it is on disk now, keeping what the change doesn't touch.
    private static func update(_ url: URL, _ change: (inout Saved) -> Void) -> Bool {
        var file: Saved
        do { file = try read(url) ?? Saved() } catch { return false }
        change(&file)
        do {
            try JSONEncoder().encode(file).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    /// Earlier versions kept the apps each profile added in its own file. They're everyone's now: gathered into
    /// apps.json with their ids, and so their icon files, unchanged, and taken out of a profile's file only once
    /// apps.json is saved.
    private static func gatherAddedApps(in folder: URL, into shared: URL) {
        let strays = profileFiles(in: folder).compactMap { url -> (URL, [AddedApp])? in
            guard let file = try? read(url), let apps = file.added, !apps.isEmpty else { return nil }
            return (url, apps)
        }
        guard !strays.isEmpty else { return }
        let gathered = update(shared) { file in
            var list = file.added ?? []
            for app in strays.flatMap({ $0.1 }) where !list.contains(where: { $0.id == app.id }) { list.append(app) }
            file.added = list
        }
        guard gathered else { return }
        for (url, _) in strays { _ = update(url) { $0.added = nil } }
    }

    private static func darkened(_ hex: String) -> String {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        let r = Double((value >> 16) & 0xFF) * 0.18, g = Double((value >> 8) & 0xFF) * 0.18, b = Double(value & 0xFF) * 0.18
        return String(format: "#%02X%02X%02X", Int(r), Int(g), Int(b))
    }
}

/// Finds an official-looking square icon for an app the user adds.
enum IconFinder {
    /// For a website: its App Store app's icon (crisp, 1024 px) when the name matches one,
    /// else the largest home-screen icon the site publishes.
    static func icon(forSite site: URL, name: String) async -> Data? {
        if let data = await appStoreIcon(named: name) { return data }
        return await siteIcon(site)
    }

    /// A Mac app's own icon.
    @MainActor
    static func icon(forAppAt path: String) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 512, height: 512)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func appStoreIcon(named name: String) async -> Data? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        var query = URLComponents(string: "https://itunes.apple.com/search")!
        query.queryItems = [.init(name: "term", value: name), .init(name: "entity", value: "software"),
                            .init(name: "limit", value: "8"),
                            .init(name: "country", value: Locale.current.region?.identifier ?? "US")]
        guard let url = query.url, let data = await fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        // Only trust a result whose name actually matches, e.g. "Crunchyroll" or "Crunchyroll: Anime".
        let match = results.first { result in
            let title = normalized(result["trackName"] as? String ?? "")
            return title == wanted || title.hasPrefix(wanted) || (wanted.count > 3 && wanted.hasPrefix(title) && title.count > 3)
        }
        guard let artwork = match?["artworkUrl512"] as? String,
              let large = URL(string: artwork.replacingOccurrences(of: "512x512bb.jpg", with: "1024x1024bb.png"))
        else { return nil }
        return await fetchImage(large)
    }

    private static func siteIcon(_ site: URL) async -> Data? {
        var candidates: [(url: URL, size: Int)] = []
        if let page = await fetch(site), let html = String(data: page, encoding: .utf8) ?? String(data: page, encoding: .isoLatin1) {
            for tag in matches(of: "<link\\b[^>]*>", in: html) {
                guard let rel = attribute("rel", in: tag)?.lowercased(), let href = attribute("href", in: tag),
                      let url = URL(string: href, relativeTo: site)?.absoluteURL else { continue }
                if rel.contains("manifest") {
                    candidates += await manifestIcons(url)
                } else if rel.contains("icon") {
                    let size = attribute("sizes", in: tag).flatMap { Int($0.split(separator: "x").first ?? "") }
                    candidates.append((url, size ?? (rel.contains("apple-touch") ? 180 : 32)))
                }
            }
        }
        for path in ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"] {
            if let url = URL(string: path, relativeTo: site)?.absoluteURL { candidates.append((url, 180)) }
        }
        for candidate in candidates.sorted(by: { $0.size > $1.size }) {
            if let data = await fetchImage(candidate.url, minimumSide: 96) { return data }
        }
        return nil
    }

    private static func manifestIcons(_ url: URL) async -> [(url: URL, size: Int)] {
        guard let data = await fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = json["icons"] as? [[String: Any]] else { return [] }
        return icons.compactMap { icon in
            guard let src = icon["src"] as? String, let iconURL = URL(string: src, relativeTo: url)?.absoluteURL else { return nil }
            let size = (icon["sizes"] as? String)?.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max()
            return (iconURL, size ?? 192)
        }
    }

    // MARK: Helpers

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(UserAgent.safari, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return nil }
        return data
    }

    /// Downloads an image and returns it as PNG, if it's a real image of a usable size.
    private static func fetchImage(_ url: URL, minimumSide: Int = 0) async -> Data? {
        guard let data = await fetch(url), let image = NSImage(data: data),
              let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
              rep.pixelsWide >= minimumSide,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }
}

/// Mac apps installed on this machine, for adding to the home screen.
enum InstalledApps {
    struct App: Hashable {
        let name: String
        let bundleID: String
        let path: String
    }

    static let all: [App] = {
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       NSHomeDirectory() + "/Applications"]
        var found: [String: App] = [:]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".app") {
                let path = folder + "/" + name
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier else { continue }
                let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? String(name.dropLast(4))
                found[id] = App(name: display, bundleID: id, path: path)
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func matching(_ query: String) -> [App] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(all.prefix(40)) }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(40).map { $0 }
    }
}

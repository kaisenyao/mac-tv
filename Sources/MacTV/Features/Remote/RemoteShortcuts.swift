import Foundation

/// The shortcut chips under the phone remote's pad: what there is to pick, which ones each place shows, and what
/// the choice may hold. The Mac owns all of it; the page draws what `/state` sends and edits the choice through
/// `/shortcuts` (see RemoteShortcutRoutes).
///
/// Home has its set, and 哔哩哔哩, 网易云音乐 and 得到 each have one too, which can mix in the shortcuts that work
/// everywhere. An app whose set is empty uses Home's; any other app always uses Home's.
enum RemoteShortcuts {
    struct Entry: Equatable, Sendable {
        let id: String
        let title: String
        /// The page's icon name; it draws no icon for a name it doesn't know.
        let icon: String
        /// The app it belongs to; nil for the ones that work everywhere.
        let app: String?
    }

    struct App: Equatable, Sendable {
        let id: String
        let name: String
    }

    /// The most a set may hold: the remote has four slots.
    static let limit = 4
    /// The scope and context name for the home screen and every app without shortcuts of its own.
    static let home = "home"

    static let catalog: [Entry] = [
        Entry(id: "shortcut", title: "Run Shortcut", icon: "shortcut", app: nil),
        Entry(id: "screensaver", title: "Screen Saver", icon: "screensaver", app: nil),
        Entry(id: "sleepTimer", title: "Sleep Timer", icon: "sleep", app: nil),
        Entry(id: "files", title: "Files", icon: "files", app: nil),
        Entry(id: "bilibili.danmaku", title: "弹幕", icon: "danmaku", app: "bilibili"),
        Entry(id: "bilibili.quality", title: "清晰度", icon: "quality", app: "bilibili"),
        Entry(id: "bilibili.speed", title: "倍速", icon: "speed", app: "bilibili"),
        Entry(id: "bilibili.subtitles", title: "字幕", icon: "subtitles", app: "bilibili"),
        Entry(id: "bilibili.episodes", title: "选集", icon: "episodes", app: "bilibili"),
        Entry(id: "bilibili.coin", title: "投币", icon: "coin", app: "bilibili"),
        Entry(id: "bilibili.favorite", title: "收藏", icon: "star", app: "bilibili"),
        Entry(id: "netease.like", title: "喜欢", icon: "heart", app: "netease"),
        Entry(id: "netease.lyrics", title: "歌词", icon: "lyrics", app: "netease"),
        Entry(id: "netease.mode", title: "播放模式", icon: "mode", app: "netease"),
        Entry(id: "netease.daily", title: "每日推荐", icon: "daily", app: "netease"),
        Entry(id: "dedao.speed", title: "倍速", icon: "speed", app: "dedao"),
        Entry(id: "dedao.transcript", title: "文稿", icon: "transcript", app: "dedao"),
        Entry(id: "dedao.timer", title: "定时关闭", icon: "sleep", app: "dedao"),
        Entry(id: "dedao.next", title: "下一讲", icon: "next", app: "dedao"),
        Entry(id: "dedao.previous", title: "上一讲", icon: "previous", app: "dedao"),
    ]

    /// The apps with shortcuts of their own, in the order the settings list them.
    static let apps: [App] = [App(id: "bilibili", name: "哔哩哔哩"), App(id: "netease", name: "网易云音乐"), App(id: "dedao", name: "得到")]

    /// What each place shows until it's changed.
    static let defaults: [String: [String]] = [
        home: ["shortcut", "screensaver", "sleepTimer", "files"],
        "bilibili": ["bilibili.danmaku", "bilibili.quality", "bilibili.speed", "bilibili.subtitles"],
        "netease": ["netease.like", "netease.lyrics", "netease.mode", "netease.daily"],
        "dedao": ["dedao.speed", "dedao.transcript", "dedao.timer", "dedao.next"],
    ]

    static func entry(_ id: String) -> Entry? { catalog.first { $0.id == id } }

    /// The shortcuts that work everywhere, Home's only choices.
    static var everywhere: [String] { catalog.filter { $0.app == nil }.map(\.id) }

    /// An app's own shortcuts (without the everywhere ones).
    static func own(of app: String) -> [String] { catalog.filter { $0.app == app }.map(\.id) }

    static func isScope(_ scope: String) -> Bool { scope == home || apps.contains { $0.id == scope } }

    /// Whether a set for this scope may hold this shortcut: everywhere ones anywhere, an app's own only in its set.
    static func allowed(_ id: String, in scope: String) -> Bool {
        guard let entry = entry(id), isScope(scope) else { return false }
        return entry.app == nil || entry.app == scope
    }

    /// Why this set can't be saved for this scope, or nil when it can.
    static func problem(with ids: [String], in scope: String) -> String? {
        guard isScope(scope) else { return "Choose Home or an app with its own shortcuts." }
        guard ids.count <= limit else { return "Choose up to four shortcuts." }
        guard Set(ids).count == ids.count else { return "Each shortcut can be picked once." }
        if let unknown = ids.first(where: { entry($0) == nil }) { return "There's no shortcut called \(unknown)." }
        if let misplaced = ids.first(where: { !allowed($0, in: scope) }) {
            let title = entry(misplaced)?.title ?? misplaced
            return scope == home ? "\(title) only works in its own app." : "\(title) belongs to another app."
        }
        return nil
    }

    /// A saved set read back as far as it still makes sense: shortcuts that are gone, moved or repeated drop out.
    static func cleaned(_ ids: [String], in scope: String) -> [String] {
        var seen = Set<String>()
        return Array(ids.filter { allowed($0, in: scope) && seen.insert($0).inserted }.prefix(limit))
    }

    /// The `/state` shortcuts as a guest remote gets them: drawn, but nothing it can press, and not the name of
    /// the owner's Apple Shortcut.
    static func forGuest(_ shortcuts: [String: Any]) -> [String: Any] {
        var view = shortcuts
        view["items"] = (shortcuts["items"] as? [[String: Any]] ?? []).map { item in
            var item = item
            item["enabled"] = false
            if item["id"] as? String == "shortcut" { item.removeValue(forKey: "value") }
            return item
        }
        return view
    }

    /// Time left on a sleep timer, as a chip shows it: "25 min", "1 hr", "1 hr 30 min".
    static func minutesText(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }
}

/// What the person watching picked: each place's set and the Apple Shortcut "Run Shortcut" runs. Kept in their
/// profile's defaults (UserDefaults.standard for the first profile), so each person has their own.
struct RemoteShortcutChoice: Equatable, Sendable {
    /// Each scope's saved set. A scope that has none shows its default; an app saved empty uses Home's.
    private(set) var sets: [String: [String]]
    /// The Apple Shortcut's name; empty when none is chosen.
    private(set) var appleShortcut: String

    static let setsKey = "remoteShortcutSets"
    static let appleShortcutKey = "remoteAppleShortcut"

    init(sets: [String: [String]] = [:], appleShortcut: String = "") {
        var kept: [String: [String]] = [:]
        for (scope, ids) in sets where RemoteShortcuts.isScope(scope) { kept[scope] = RemoteShortcuts.cleaned(ids, in: scope) }
        self.sets = kept
        self.appleShortcut = Self.appleShortcutName(appleShortcut) ?? ""
    }

    /// The set saved for a scope, or its default. An app's may be empty.
    func set(for scope: String) -> [String] {
        sets[scope] ?? RemoteShortcuts.defaults[scope] ?? []
    }

    /// Whether an app shows a set of its own rather than Home's.
    func hasOwn(_ app: String) -> Bool {
        app != RemoteShortcuts.home && RemoteShortcuts.apps.contains { $0.id == app } && !set(for: app).isEmpty
    }

    /// What the remote shows in this context (Home, or an app): an app without a set of its own shows Home's.
    func picked(in context: String) -> [String] {
        hasOwn(context) ? set(for: context) : set(for: RemoteShortcuts.home)
    }

    /// Saves a set for a scope. Returns why it can't, leaving the choice as it was.
    mutating func choose(_ ids: [String], for scope: String) -> String? {
        if let problem = RemoteShortcuts.problem(with: ids, in: scope) { return problem }
        sets[scope] = ids
        return nil
    }

    /// Chooses the Apple Shortcut to run; an empty name clears it. Returns false for a name that can't be one.
    mutating func chooseAppleShortcut(_ name: String) -> Bool {
        guard let clean = Self.appleShortcutName(name) else { return false }
        appleShortcut = clean
        return true
    }

    /// A shortcut's name as the phone sent it, trimmed; nil when it can't be a name (too long, or has line breaks or
    /// other control characters). Empty means none.
    static func appleShortcutName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard name.count <= 200, name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }

    static func load(from defaults: UserDefaults) -> RemoteShortcutChoice {
        let stored = defaults.dictionary(forKey: setsKey) ?? [:]
        var sets: [String: [String]] = [:]
        for (scope, value) in stored { if let ids = value as? [String] { sets[scope] = ids } }
        return RemoteShortcutChoice(sets: sets, appleShortcut: defaults.string(forKey: appleShortcutKey) ?? "")
    }

    func save(to defaults: UserDefaults) {
        defaults.set(sets, forKey: Self.setsKey)
        if appleShortcut.isEmpty { defaults.removeObject(forKey: Self.appleShortcutKey) }
        else { defaults.set(appleShortcut, forKey: Self.appleShortcutKey) }
    }
}

/// The owner's own Apple Shortcuts, through `/usr/bin/shortcuts`: run directly (no shell, the name is one argument),
/// on a background thread, and stopped when it takes too long. Nothing in System Settings changes for this.
enum AppleShortcuts {
    enum Outcome: Equatable, Sendable { case done, failed, timedOut }

    static let tool = "/usr/bin/shortcuts"
    /// The phone waits for the list, and the remote server gives up on a request after 15 seconds.
    static let listLimit: TimeInterval = 8
    /// A shortcut may take a while (dimming lights, waiting a moment), but not forever.
    static let runLimit: TimeInterval = 60

    /// The user's shortcuts by name, or nil when the tool fails or takes too long.
    static func names() async -> [String]? {
        let result = await execute(["list"], limit: listLimit, keepOutput: true)
        guard case .done = result.outcome else { return nil }
        return names(fromList: result.output)
    }

    /// `shortcuts list` prints one name per line.
    static func names(fromList output: Data) -> [String] {
        var seen = Set<String>()
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(500).map { $0 }
    }

    static func run(_ name: String) async -> Outcome {
        await execute(["run", name], limit: runLimit, keepOutput: false).outcome
    }

    private static func execute(_ arguments: [String], limit: TimeInterval, keepOutput: Bool) async -> (outcome: Outcome, output: Data) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runAndWait(arguments, limit: limit, keepOutput: keepOutput))
            }
        }
    }

    /// Blocks the calling (background) thread until the tool exits or is stopped at the limit.
    private static func runAndWait(_ arguments: [String], limit: TimeInterval, keepOutput: Bool) -> (outcome: Outcome, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = keepOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice
        do { try process.run() } catch { return (.failed, Data()) }
        let deadline = Deadline(process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) { deadline.stop() }
        let output = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        if deadline.finish() { return (.timedOut, Data()) }
        return (process.terminationStatus == 0 ? .done : .failed, output)
    }

    /// Stops the tool at its time limit, unless it finished first.
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var finished = false
        private var stopped = false

        init(_ process: Process) { self.process = process }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            guard !finished, process.isRunning else { return }
            stopped = true
            process.terminate()
        }

        /// The tool has exited. Returns whether it was stopped at the limit.
        func finish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            finished = true
            return stopped
        }
    }
}

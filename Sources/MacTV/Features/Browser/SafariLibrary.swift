import Foundation
import SQLite3

/// 一个网页：收藏、常去的网站、看过的页面都是它
struct WebPage: Codable, Hashable, Identifiable, Sendable {
    var url: URL
    var title: String
    /// 什么时候看的（历史记录才有）
    var visited: Date? = nil

    var id: String { url.absoluteString }
    var host: String { (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "") }
    /// 卡片上的名字：页面标题，没有就是网站名
    var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : title }
}

/// 读这台 Mac 上 Safari 的东西：个人收藏（收藏栏）、阅读列表、常去的网站、最近看过的页面。
///
/// Safari 的文件在 ~/Library/Safari，macOS 只让有"完全磁盘访问权限"的应用读（系统设置 → 隐私与安全性 →
/// 完全磁盘访问权限，给 Mac TV 打勾，这一步只能你自己做）。没打勾时读不到，浏览器照样能用，只是没有 Safari 的记录。
/// 只读：历史记录先复制一份再读，不锁 Safari 的文件，也不往里写任何东西
enum SafariLibrary {
    enum Access: Equatable { case ok, needsPermission, missing }

    struct Snapshot: Sendable {
        var access: Access
        var favorites: [WebPage] = []
        var readingList: [WebPage] = []
        var frequent: [WebPage] = []
        var recent: [WebPage] = []
    }

    private static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true) }

    static func read() -> Snapshot {
        let bookmarks = folder.appendingPathComponent("Bookmarks.plist")
        let history = folder.appendingPathComponent("History.db")
        guard FileManager.default.fileExists(atPath: history.path) || FileManager.default.fileExists(atPath: bookmarks.path) else {
            return Snapshot(access: .missing)
        }
        // 没有权限时连读都读不了（文件在，但打不开）
        guard let data = try? Data(contentsOf: bookmarks) else { return Snapshot(access: .needsPermission) }
        var snapshot = Snapshot(access: .ok)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let lists = plist["Children"] as? [[String: Any]] ?? []
            snapshot.favorites = leaves(lists.first { $0["Title"] as? String == "BookmarksBar" })
            snapshot.readingList = leaves(lists.first { $0["Title"] as? String == "com.apple.ReadingList" })
        }
        let pages = historyPages(history)
        snapshot.frequent = pages.frequent
        snapshot.recent = pages.recent
        return snapshot
    }

    /// 一个书签文件夹里的网页（子文件夹里的也算，按顺序摊平）
    private static func leaves(_ folder: [String: Any]?) -> [WebPage] {
        guard let folder else { return [] }
        var pages: [WebPage] = []
        for child in folder["Children"] as? [[String: Any]] ?? [] {
            if child["WebBookmarkType"] as? String == "WebBookmarkTypeList" { pages += leaves(child); continue }
            guard let address = child["URLString"] as? String, let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { continue }
            let title = (child["URIDictionary"] as? [String: Any])?["title"] as? String ?? child["Title"] as? String ?? ""
            pages.append(WebPage(url: url, title: title))
        }
        return pages
    }

    /// 常去的网站（按网站算访问次数，最多的在前）和最近看过的页面（同一页只留最近一次）
    private static func historyPages(_ database: URL) -> (frequent: [WebPage], recent: [WebPage]) {
        // 先复制一份（连同还没写进主文件的那部分），在副本上读
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacTV-Safari-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        guard (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil else { return ([], []) }
        let copy = work.appendingPathComponent("History.db")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return ([], []) }
        defer { sqlite3_close(db) }

        func rows(_ sql: String, _ each: (OpaquePointer) -> Void) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
        }
        func text(_ statement: OpaquePointer, _ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        // 最近：成功打开的、不是跳转中间页的，最新的在前；同一个地址只留一次
        var recent: [WebPage] = []
        var seen = Set<String>()
        rows("""
            SELECT i.url, v.title, v.visit_time FROM history_visits v JOIN history_items i ON i.id = v.history_item
            WHERE v.load_successful = 1 AND v.redirect_destination IS NULL ORDER BY v.visit_time DESC LIMIT 400
            """) { statement in
            let address = text(statement, 0)
            guard recent.count < 40, let url = URL(string: address), url.scheme?.hasPrefix("http") == true,
                  seen.insert(address).inserted else { return }
            // Safari 记的时间是从 2001 年起的秒数
            let time = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            recent.append(WebPage(url: url, title: text(statement, 1), visited: time))
        }

        // 常去：把访问次数按网站加起来；每个网站用它首页的地址，名字用访问最多的那一页的标题里网站的那一段
        var byHost: [String: (count: Int, title: String, best: Int)] = [:]
        rows("""
            SELECT i.url, i.visit_count,
                   (SELECT v.title FROM history_visits v WHERE v.history_item = i.id ORDER BY v.visit_time DESC LIMIT 1)
            FROM history_items i ORDER BY i.visit_count DESC LIMIT 600
            """) { statement in
            guard let url = URL(string: text(statement, 0)), url.scheme?.hasPrefix("http") == true, let host = url.host else { return }
            let count = Int(sqlite3_column_int(statement, 1))
            var entry = byHost[host] ?? (0, "", 0)
            entry.count += count
            if count > entry.best { entry.best = count; entry.title = text(statement, 2) }
            byHost[host] = entry
        }
        let frequent = byHost.sorted { $0.value.count > $1.value.count }.prefix(24).compactMap { host, entry -> WebPage? in
            guard let url = URL(string: "https://\(host)/") else { return nil }
            return WebPage(url: url, title: siteName(fromTitle: entry.title, host: host))
        }
        return (frequent, recent)
    }

    /// "某个视频标题 - 哔哩哔哩"、"Inbox (3) | Gmail" 这样的标题，取最后那一段当网站名；取不出就用网址
    static func siteName(fromTitle title: String, host: String) -> String {
        for separator in [" - ", " | ", " – ", " — ", "_"] {
            if let last = title.components(separatedBy: separator).last, title.contains(separator) {
                let name = last.trimmingCharacters(in: .whitespacesAndNewlines)
                if (1...16).contains(name.count) { return name }
            }
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

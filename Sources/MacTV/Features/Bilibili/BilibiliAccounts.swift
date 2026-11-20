import Foundation
import WebKit

/// 登录过的哔哩哔哩账号（可以有好几个，在头像菜单里切换）。
///
/// 名字、头像记在本机设置里（只是显示用）；登录信息（哔哩哔哩的 cookie）存在钥匙串里，
/// 只有这台 Mac 上的 Mac TV 读得到，也只会发给哔哩哔哩。退出登录时连同钥匙串里的那一份一起删掉。
/// 每个人（个人资料）各有各的一份（他的设置、他名下的钥匙串项，见 ProfileSpace）：别人切换不到他的账号上。
/// 第一个人的还是原来的地方（偏好设置里的同一个键、钥匙串里同一个名字）
struct BiliSavedAccount: Codable, Hashable, Sendable {
    let mid: Int
    var name: String
    var face: URL?
}

enum BiliAccounts {
    static let listKey = "bilibiliAccounts"
    static let service = "Mac TV Bilibili"
    private static let label = "Mac TV 哔哩哔哩登录"

    /// 登录过的账号，最近用过的在前
    static func list(in space: ProfileSpace = .current) -> [BiliSavedAccount] {
        guard let data = space.defaults.data(forKey: listKey),
              let accounts = try? JSONDecoder().decode([BiliSavedAccount].self, from: data) else { return [] }
        return accounts
    }

    private static func save(_ accounts: [BiliSavedAccount], in space: ProfileSpace) {
        if let data = try? JSONEncoder().encode(accounts) { space.defaults.set(data, forKey: listKey) }
    }

    /// 记下（或更新）一个账号和它现在的登录信息，放到最前面（只存哔哩哔哩自己的 cookie）
    static func remember(_ account: BiliAccount, cookies: [HTTPCookie], in space: ProfileSpace = .current) {
        let cookies = cookies.filter(\.isBilibili)
        guard account.mid > 0, cookies.contains(where: { $0.name == "SESSDATA" }) else { return }
        let properties = cookies.compactMap { cookie -> [String: Any]? in
            guard let raw = cookie.properties else { return nil }
            return Dictionary(uniqueKeysWithValues: raw.map { ($0.key.rawValue, $0.value) })
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0) else { return }
        space.keychain.set(data, service: space.keychainService(service), account: "\(account.mid)", label: label)
        var accounts = list(in: space).filter { $0.mid != account.mid }
        accounts.insert(BiliSavedAccount(mid: account.mid, name: account.name, face: account.face), at: 0)
        save(accounts, in: space)
    }

    /// 某个账号存下来的登录信息
    static func cookies(for mid: Int, in space: ProfileSpace = .current) -> [HTTPCookie] {
        guard let data = space.keychain.data(service: space.keychainService(service), account: "\(mid)"),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
        return list.compactMap { properties in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
    }

    /// 忘掉一个账号：列表里去掉，钥匙串里的登录信息也删掉
    static func forget(_ mid: Int, in space: ProfileSpace = .current) {
        space.keychain.delete(service: space.keychainService(service), account: "\(mid)")
        save(list(in: space).filter { $0.mid != mid }, in: space)
    }

    /// 把一个账号（列表里那一项和钥匙串里的登录信息）从一个人名下挪到另一个人名下。先在新的地方存好，
    /// 存上了才删旧的；存不上就留在原处。挪成了返回 true
    @discardableResult
    static func move(_ mid: Int, from source: ProfileSpace, to target: ProfileSpace) -> Bool {
        guard source.profileID != target.profileID, let entry = list(in: source).first(where: { $0.mid == mid }),
              let data = source.keychain.data(service: source.keychainService(service), account: "\(mid)") else { return false }
        guard target.keychain.set(data, service: target.keychainService(service), account: "\(mid)", label: label) else { return false }
        save([entry] + list(in: target).filter { $0.mid != mid }, in: target)
        guard list(in: target).contains(where: { $0.mid == mid }) else { return false }
        forget(mid, in: source)
        return true
    }

    // MARK: 以前登录过的账号是谁的

    /// 做过了（只做一次）：记在这台 Mac 的设置里
    static let attributedKey = "bilibiliAccountsAttributed"

    /// 有个人资料以前，登录过的账号都记在一处（谁都切换得到）。哪个账号是谁的：现在登录在谁的网页数据里
    ///（DedeUserID 这个 cookie 就是账号编号），就是谁的；都不是的、第一个人自己也登录着的，留给第一个人。
    /// others：别的每个人，和他的网页数据里现在登录着的账号编号（没有是 nil）
    static func attribute(main: ProfileSpace, others: [(space: ProfileSpace, loggedIn: Int?)], mainLoggedIn: Int?) {
        let saved = Set(list(in: main).map(\.mid))
        for (space, mid) in others {
            guard let mid, saved.contains(mid), mid != mainLoggedIn else { continue }
            move(mid, from: main, to: space)
        }
    }

    /// 一份网页数据里现在登录着的哔哩哔哩账号编号
    @MainActor
    static func loggedInMid(_ store: WKWebsiteDataStore) async -> Int? {
        let cookies = await store.httpCookieStore.allCookies()
        return cookies.first { $0.isBilibili && $0.name == "DedeUserID" }.flatMap { Int($0.value) }
    }

    /// 同上；网页数据的 cookie 要有网页开过才读得到（懒加载），读不到就用一个看不见的网页唤醒它，再读几次
    @MainActor
    static func wakeAndReadMid(_ store: WKWebsiteDataStore) async -> Int? {
        if let found = await loggedInMid(store) { return found }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let waker = WKWebView(frame: .zero, configuration: config)
        waker.loadHTMLString("", baseURL: URL(string: "https://www.bilibili.com/"))
        defer { waker.stopLoading() }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(150))
            if let found = await loggedInMid(store) { return found }
        }
        return nil
    }
}

extension HTTPCookie {
    /// 是哔哩哔哩自己的 cookie（bilibili.com 和它下面的子域名；别的站名字里带 bilibili.com 的不算）
    var isBilibili: Bool { domain == "bilibili.com" || domain.hasSuffix(".bilibili.com") }
}

extension TVController {
    /// 一次性：以前登录过的哔哩哔哩账号分给登录着它的人（见 BiliAccounts.attribute）。启动时在后台做，只做一次
    func attributeBilibiliAccounts() {
        let device = UserDefaults.standard
        guard !device.bool(forKey: BiliAccounts.attributedKey) else { return }
        let main = spaces.space(for: Profile.mainID, epoch: 0)
        let others = profiles.all.filter { $0.id != Profile.mainID && $0.store != nil }
        guard !BiliAccounts.list(in: main).isEmpty, !others.isEmpty else {
            device.set(true, forKey: BiliAccounts.attributedKey)
            return
        }
        Task { @MainActor in
            let mainMid = await BiliAccounts.wakeAndReadMid(.default())
            var found: [(space: ProfileSpace, loggedIn: Int?)] = []
            for profile in others {
                found.append((spaces.space(for: profile.id, epoch: 0), await BiliAccounts.wakeAndReadMid(profile.websiteDataStore)))
            }
            BiliAccounts.attribute(main: main, others: found, mainLoggedIn: mainMid)
            device.set(true, forKey: BiliAccounts.attributedKey)
            bilibiliStore.savedAccountsChanged()
        }
    }
}

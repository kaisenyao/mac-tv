import Foundation
import Security

/// 登录过的哔哩哔哩账号（可以有好几个，在头像菜单里切换）。
///
/// 名字、头像记在本机设置里（只是显示用）；登录信息（哔哩哔哩的 cookie）存在钥匙串里，
/// 只有这台 Mac 上的 Mac TV 读得到，也只会发给哔哩哔哩。退出登录时连同钥匙串里的那一份一起删掉
struct BiliSavedAccount: Codable, Hashable, Sendable {
    let mid: Int
    var name: String
    var face: URL?
}

enum BiliAccounts {
    private static let listKey = "bilibiliAccounts"
    private static let service = "Mac TV Bilibili"

    /// 登录过的账号，最近用过的在前
    static func list() -> [BiliSavedAccount] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let accounts = try? JSONDecoder().decode([BiliSavedAccount].self, from: data) else { return [] }
        return accounts
    }

    private static func save(_ accounts: [BiliSavedAccount]) {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: listKey) }
    }

    /// 记下（或更新）一个账号和它现在的登录信息，放到最前面（只存哔哩哔哩自己的 cookie）
    static func remember(_ account: BiliAccount, cookies: [HTTPCookie]) {
        let cookies = cookies.filter(\.isBilibili)
        guard account.mid > 0, cookies.contains(where: { $0.name == "SESSDATA" }) else { return }
        let properties = cookies.compactMap { cookie -> [String: Any]? in
            guard let raw = cookie.properties else { return nil }
            return Dictionary(uniqueKeysWithValues: raw.map { ($0.key.rawValue, $0.value) })
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0) else { return }
        let query = keychainQuery(account.mid)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Mac TV 哔哩哔哩登录"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
        var accounts = list().filter { $0.mid != account.mid }
        accounts.insert(BiliSavedAccount(mid: account.mid, name: account.name, face: account.face), at: 0)
        save(accounts)
    }

    /// 某个账号存下来的登录信息
    static func cookies(for mid: Int) -> [HTTPCookie] {
        var query = keychainQuery(mid)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
        return list.compactMap { properties in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
    }

    /// 忘掉一个账号：列表里去掉，钥匙串里的登录信息也删掉
    static func forget(_ mid: Int) {
        SecItemDelete(keychainQuery(mid) as CFDictionary)
        save(list().filter { $0.mid != mid })
    }

    private static func keychainQuery(_ mid: Int) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(mid)"]
    }
}

extension HTTPCookie {
    /// 是哔哩哔哩自己的 cookie（bilibili.com 和它下面的子域名；别的站名字里带 bilibili.com 的不算）
    var isBilibili: Bool { domain == "bilibili.com" || domain.hasSuffix(".bilibili.com") }
}

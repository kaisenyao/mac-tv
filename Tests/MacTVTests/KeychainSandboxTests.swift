import Foundation
import Testing
@testable import MacTV

/// The tests never reach the real Keychain: TestSandbox switches every Keychain user to memory before any test runs,
/// and SystemKeychain, the only place that calls SecItem, refuses (and counts) any call that would still get there.
@Suite @MainActor
struct KeychainSandboxTests {
    @Test func onlySystemKeychainCallsSecItem() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MacTV", isDirectory: true)
        let calls = try Regex(#"\bSecItem(CopyMatching|Add|Update|Delete)\b"#)
        var found: [String] = []
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "Keychain.swift" {
            if try String(contentsOf: file, encoding: .utf8).contains(calls) { found.append(file.lastPathComponent) }
        }
        #expect(found.isEmpty, "SecItem is called outside SystemKeychain: \(found)")
    }

    @Test func everyKeychainUserKeepsItsItemsInMemory() throws {
        #expect(SystemKeychain.inMemory)
        let id = UUID().uuidString

        // Profiles' sign-ins in the real places, as the app keeps the first profile's.
        let keychain = ProfileKeychain.system
        #expect(ProfileSpaces.live.space(for: Profile.mainID, epoch: 0).keychain === keychain)
        let service = "MacTVTests \(id)"
        #expect(keychain.set(Data("secret".utf8), service: service, account: "a", label: "Mac TV test"))
        #expect(keychain.data(service: service, account: "a") == Data("secret".utf8))
        keychain.delete(service: service, account: "a")
        #expect(keychain.data(service: service, account: "a") == nil)
        keychain.set(Data("secret".utf8), service: service, account: "b", label: "Mac TV test")
        keychain.deleteAll(service: service)
        #expect(keychain.data(service: service, account: "b") == nil)

        // A 哔哩哔哩 sign-in in the first profile's space.
        let main = ProfileSpaces.live.space(for: Profile.mainID, epoch: 0)
        let cookie = try #require(HTTPCookie(properties: [.domain: ".bilibili.com", .path: "/", .name: "SESSDATA", .value: id]))
        BiliAccounts.remember(BiliAccount(name: "测试", mid: 424_242), cookies: [cookie], in: main)
        #expect(BiliAccounts.cookies(for: 424_242, in: main).map(\.value) == [id])
        BiliAccounts.forget(424_242, in: main)
        #expect(BiliAccounts.cookies(for: 424_242, in: main).isEmpty)

        // A network share's password and a Jellyfin token.
        ShareKeychain.save("password", host: "\(id).local", user: "me")
        #expect(ShareKeychain.read(host: "\(id).local", user: "me") == "password")
        ShareKeychain.delete(host: "\(id).local", user: "me")
        #expect(ShareKeychain.read(host: "\(id).local", user: "me") == nil)
        JellyfinKeychain.save("token", server: id)
        #expect(JellyfinKeychain.token(server: id) == "token")
        JellyfinKeychain.delete(server: id)
        #expect(JellyfinKeychain.token(server: id) == nil)

        // Nothing in this run has reached the real Keychain so far.
        #expect(SystemKeychain.refused == 0)
    }
}

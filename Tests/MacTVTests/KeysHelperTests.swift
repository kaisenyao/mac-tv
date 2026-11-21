import Foundation
import Security
import Testing
@testable import MacTV

/// SystemKeychain's requests to the keys helper (KeysHelper/main.swift) and its answers, as pure functions: no
/// Keychain, no helper run. The queries are the shapes ProfileKeychain, ShareKeychain, JellyfinKeychain and
/// JasmineKeychain build.
@Suite(.timeLimit(.minutes(1)))
struct KeysHelperTests {
    private let generic: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                          kSecAttrService as String: "Mac TV Jellyfin",
                                          kSecAttrAccount as String: "server-1"]
    private let share: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                        kSecAttrServer as String: "nas.local",
                                        kSecAttrAccount as String: "me",
                                        kSecAttrProtocol as String: kSecAttrProtocolSMB,
                                        kSecAttrLabel as String: "Mac TV network share"]
    private let data = Data("secret".utf8)

    private func reading(_ query: [String: Any]) -> [String: Any] {
        query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
    }

    @Test func readsAGenericPassword() throws {
        let request = try #require(KeysRequest.read(reading(generic)))
        #expect(request.fields == ["op": "read", "class": "generic", "service": "Mac TV Jellyfin", "account": "server-1"])
    }

    @Test func readsANetworkSharePassword() throws {
        let request = try #require(KeysRequest.read(reading(share)))
        #expect(request.fields == ["op": "read", "class": "internet", "server": "nas.local", "account": "me",
                                   "protocol": "smb", "label": "Mac TV network share"])
    }

    @Test func addsWithItsLabelAndAccessibility() throws {
        // Jellyfin and Jasmine: the item, its data and a label
        var item = generic
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Mac TV Jellyfin sign-in"
        #expect(KeysRequest.add(item)?.fields == ["op": "write", "mode": "add", "class": "generic",
                                                  "service": "Mac TV Jellyfin", "account": "server-1",
                                                  "data": data.base64EncodedString(), "label": "Mac TV Jellyfin sign-in"])
        // A profile's sign-in: also readable only on this Mac, after the first unlock
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #expect(KeysRequest.add(item)?.fields["accessible"] == "afterFirstUnlockThisDeviceOnly")
        // A network share's password: its label is part of the item
        var password = share
        password[kSecValueData as String] = data
        #expect(KeysRequest.add(password)?.fields == ["op": "write", "mode": "add", "class": "internet",
                                                      "server": "nas.local", "account": "me", "protocol": "smb",
                                                      "label": "Mac TV network share",
                                                      "data": data.base64EncodedString()])
    }

    @Test func updatesAProfileSignIn() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Mac TV Bilibili (2)", kSecAttrAccount as String: "42"]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "Mac TV 哔哩哔哩登录"]
        #expect(KeysRequest.update(query, attributes)?.fields == [
            "op": "write", "mode": "update", "class": "generic", "service": "Mac TV Bilibili (2)", "account": "42",
            "data": data.base64EncodedString(), "label": "Mac TV 哔哩哔哩登录"])
    }

    @Test func deletesAnItemOrAService() throws {
        #expect(KeysRequest.delete(generic)?.fields == ["op": "delete", "class": "generic",
                                                        "service": "Mac TV Jellyfin", "account": "server-1"])
        #expect(KeysRequest.delete(share)?.fields["op"] == "delete")
        let service: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "Mac TV Bilibili (2)"]
        #expect(KeysRequest.delete(service)?.fields == ["op": "deleteService", "class": "generic",
                                                        "service": "Mac TV Bilibili (2)"])
    }

    /// Anything the helper wouldn't carry exactly is no request, and Mac TV calls SecItem itself.
    @Test func refusesWhatItCannotCarry() {
        // Reads: every match, attributes instead of data, no account, a shape with something more
        #expect(KeysRequest.read(generic.merging([kSecReturnData as String: true,
                                                  kSecMatchLimit as String: kSecMatchLimitAll]) { $1 }) == nil)
        #expect(KeysRequest.read(generic.merging([kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }) == nil)
        #expect(KeysRequest.read(reading(generic).filter { $0.key != kSecAttrAccount as String }) == nil)
        #expect(KeysRequest.read(reading(generic).merging([kSecAttrLabel as String: "x"]) { $1 }) == nil)
        // Writes: no data, empty data, an unknown attribute, another accessibility, a service-wide update
        #expect(KeysRequest.add(generic) == nil)
        #expect(KeysRequest.add(generic.merging([kSecValueData as String: Data()]) { $1 }) == nil)
        #expect(KeysRequest.add(generic.merging([kSecValueData as String: data,
                                                 kSecAttrComment as String: "x"]) { $1 }) == nil)
        #expect(KeysRequest.add(generic.merging([kSecValueData as String: data,
                                                 kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]) { $1 }) == nil)
        #expect(KeysRequest.update(generic.filter { $0.key != kSecAttrAccount as String },
                                   [kSecValueData as String: data]) == nil)
        #expect(KeysRequest.update(generic, [kSecValueData as String: data, kSecAttrComment as String: "x"]) == nil)
        // Items: another class, no service, a share without its label or over another protocol, an empty account
        #expect(KeysRequest.delete([kSecClass as String: kSecClassKey]) == nil)
        #expect(KeysRequest.delete([kSecClass as String: kSecClassGenericPassword]) == nil)
        #expect(KeysRequest.delete(share.filter { $0.key != kSecAttrLabel as String }) == nil)
        #expect(KeysRequest.delete(share.merging([kSecAttrProtocol as String: kSecAttrProtocolAFP]) { $1 }) == nil)
        #expect(KeysRequest.delete(generic.merging([kSecAttrAccount as String: ""]) { $1 }) == nil)
        #expect(KeysRequest.delete([kSecAttrService as String: "Mac TV Jellyfin"]) == nil)
    }

    @Test func sendsOneJSONObjectOfStrings() throws {
        var item = generic
        item[kSecValueData as String] = Data([0, 255, 10])
        let request = try #require(KeysRequest.add(item))
        let sent = try #require(try JSONSerialization.jsonObject(with: request.json) as? [String: String])
        #expect(sent == request.fields)
        #expect(Data(base64Encoded: try #require(sent["data"])) == Data([0, 255, 10]))
        // Always the same bytes for the same request (kept reads are found by them)
        #expect(KeysRequest.add(item)?.json == request.json)
        #expect(String(decoding: request.json, as: UTF8.self).hasPrefix(#"{"account":"server-1","class":"generic""#))
    }

    @Test func exitCodesAreKeychainStatuses() {
        #expect(KeysHelper.status(exitCode: 0) == errSecSuccess)
        #expect(KeysHelper.status(exitCode: 1) == errSecIO)
        #expect(KeysHelper.status(exitCode: 2) == errSecItemNotFound)
        #expect(KeysHelper.status(exitCode: 3) == errSecDuplicateItem)
        #expect(KeysHelper.status(exitCode: 4) == nil)  // not Mac TV's certificate: Mac TV calls SecItem itself
        #expect(KeysHelper.status(exitCode: 5) == errSecAuthFailed)
        #expect(KeysHelper.status(exitCode: 64) == errSecParam)
        #expect(KeysHelper.status(exitCode: 65) == errSecParam)
        #expect(KeysHelper.status(exitCode: -1) == errSecIO)  // ended by a signal
        #expect(KeysHelper.status(exitCode: 70) == errSecIO)
    }

    @Test func onlyASuccessfulReadKeepsItsOutput() {
        #expect(KeysHelper.answer(exitCode: 0, output: data) == KeysHelper.Answer(status: errSecSuccess, output: data))
        #expect(KeysHelper.answer(exitCode: 2, output: data) == KeysHelper.Answer(status: errSecItemNotFound, output: Data()))
        #expect(KeysHelper.answer(exitCode: 5, output: data)?.output == Data())
        #expect(KeysHelper.answer(exitCode: 4, output: data) == nil)
    }

    /// The helper refuses any item that isn't Mac TV's: it must know every service and label the app uses.
    @Test func helperKnowsMacTVsItems() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = try String(contentsOf: root.appendingPathComponent("KeysHelper/main.swift"), encoding: .utf8)
        for name in [BiliAccounts.service, "Mac TV Jellyfin", "Mac TV Jasmine"] {
            #expect(helper.contains("\"\(name)\""), "KeysHelper/main.swift doesn't list \(name)")
        }
        #expect(helper.contains(#"let shareLabel = "Mac TV network share""#))
        #expect(ProfileSpaces.keychainService(BiliAccounts.service, for: "2").hasPrefix("Mac TV "))
        // Under the tests no helper is found, and nothing would reach one: every Keychain user is in memory
        #expect(KeysHelper.installed == nil)
        #expect(SystemKeychain.inMemory)
    }
}

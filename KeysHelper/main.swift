// Mac TV Keys: the one program that reads and writes Mac TV's items in the login Keychain (Sources/MacTV/Core/
// Keychain.swift, SystemKeychain, runs it). Mac TV is signed with its own certificate, "Mac TV Local Signing", and has
// no Apple team, so the login keychain lets it at an item only by the program's own hash (the item's partition list
// holds cdhash:…), which every new build of Mac TV changes: every update asked again, for every item. This helper is
// built once and kept as it is (KeysHelper/build.sh): signed again with each build of Mac TV, it keeps its hash, and
// once allowed ("Always Allow") it is never asked again. Items Mac TV made itself before the helper are the same items
// (same service and account): the first time the helper touches each of them the keychain asks once more, naming
// Mac TV Keys, and after Always Allow never again; nothing is lost.
//
// It answers only its parent, and only when that is Mac TV signed with Mac TV's own certificate (its designated
// requirement, below), so that another program running it reads nothing (a check by the parent's process ID: no
// more than the app's own protection against a program already running as the user). Signed with the hardened
// runtime, so that no library can be put into it. It is the program of a small app, Mac TV Keys.app
// (KeysHelper/build.sh), only so that the keychain's window shows Mac TV's icon and the name Mac TV Keys with its
// question; Mac TV runs this program in it directly.
//
// One request per run: a JSON object on standard input, every value a string, no key besides those listed.
//   {"op":"read",   "class":"generic",  "service":S, "account":A}
//   {"op":"read",   "class":"internet", "server":H, "account":A, "protocol":"smb", "label":L}
//   {"op":"write",  …the same item…, "mode":"add"|"update", "data":<base64>
//                   [, "label":L (generic only)] [, "accessible":"afterFirstUnlockThisDeviceOnly" (add only)]}
//   {"op":"delete", …the same item…}                 every item that matches, as SecItemDelete
//   {"op":"deleteService", "class":"generic", "service":S}   every item under that service
// A generic item's service must be Mac TV's (macTVServices, or a name beginning "Mac TV "), an internet password's
// label Mac TV's network share label. A read writes the item's data, as it is, on standard output; nothing else
// writes anything.
// Exit: 0 done; 1 the keychain failed; 2 no such item; 3 the item is there already (write add); 4 the caller is not
// Mac TV; 5 not allowed now (the keychain's question denied or not shown); 64 not a request; 65 not Mac TV's item.
// Not changed between releases without need: a new build is a new hash, which has the keychain ask once more for
// every item.
import Foundation
import Security

let macTV = #"identifier "local.couch.tv" and "#
    + #"certificate leaf = H"2eae0495835c9ecddf36371b7a9245f3a87090db""#

/// The services Mac TV keeps generic passwords under (a second profile's are "<service> (<profile>)").
let macTVServices = ["Mac TV Bilibili", "Mac TV Jellyfin", "Mac TV Jasmine"]
/// The label of every network share password (an internet password: it has no service).
let shareLabel = "Mac TV network share"

func isMacTVService(_ service: String) -> Bool {
    macTVServices.contains(service) || service.hasPrefix("Mac TV ")
}

func parentIsMacTV() -> Bool {
    var code: SecCode?
    var requirement: SecRequirement?
    let parent = [kSecGuestAttributePid: getppid()] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, parent, [], &code) == errSecSuccess,
          let code,
          SecRequirementCreateWithString(macTV as CFString, [], &requirement) == errSecSuccess,
          let requirement
    else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

func finish(_ status: OSStatus) -> Never {
    switch status {
    case errSecSuccess: exit(0)
    case errSecItemNotFound: exit(2)
    case errSecDuplicateItem: exit(3)
    case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecNoAccessForItem: exit(5)
    default: exit(1)
    }
}

guard parentIsMacTV() else { exit(4) }

// The request, to its end: at most 1 MB (Mac TV's largest item, a sign-in's cookies, is a few kB).
let limit = 1 << 20
var input = Data()
var chunk = [UInt8](repeating: 0, count: 16 * 1024)
while input.count <= limit {
    let count = read(0, &chunk, chunk.count)
    if count < 0, errno == EINTR { continue }
    guard count > 0 else { break }
    input.append(contentsOf: chunk[..<count])
}
guard input.count <= limit,
      let request = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let fields = request as? [String: String],
      let op = fields["op"], let kind = fields["class"]
else { exit(64) }

func field(_ name: String) -> String {
    guard let value = fields[name], !value.isEmpty else { exit(64) }
    return value
}

// The item, by the attributes that name it.
var item: [String: Any]
var allowed: Set<String> = ["op", "class"]
switch (kind, op) {
case ("generic", "deleteService"):
    let service = field("service")
    guard isMacTVService(service) else { exit(65) }
    item = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    allowed.insert("service")
case ("generic", "read"), ("generic", "write"), ("generic", "delete"):
    let service = field("service")
    guard isMacTVService(service) else { exit(65) }
    item = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: field("account")]
    allowed.formUnion(["service", "account"])
case ("internet", "read"), ("internet", "write"), ("internet", "delete"):
    guard field("protocol") == "smb" else { exit(64) }
    guard field("label") == shareLabel else { exit(65) }
    item = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: field("server"),
            kSecAttrAccount as String: field("account"), kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecAttrLabel as String: shareLabel]
    allowed.formUnion(["server", "account", "protocol", "label"])
default:
    exit(64)
}

switch op {
case "read":
    guard Set(fields.keys).isSubset(of: allowed) else { exit(64) }
    var found: CFTypeRef?
    let query = item.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    guard status == errSecSuccess else { finish(status) }
    guard let data = found as? Data else { exit(1) }
    FileHandle.standardOutput.write(data)
    exit(0)
case "write":
    let mode = field("mode")
    allowed.formUnion(["mode", "data"])
    if kind == "generic" { allowed.insert("label") }
    if mode == "add" { allowed.insert("accessible") }
    // Never an empty item: data is required, and not empty
    guard Set(fields.keys).isSubset(of: allowed), let data = Data(base64Encoded: field("data")) else { exit(64) }
    var attributes: [String: Any] = [kSecValueData as String: data]
    if kind == "generic", let label = fields["label"] { attributes[kSecAttrLabel as String] = label }
    if let accessible = fields["accessible"] {
        guard accessible == "afterFirstUnlockThisDeviceOnly" else { exit(64) }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
    switch mode {
    case "add": finish(SecItemAdd(item.merging(attributes) { $1 } as CFDictionary, nil))
    case "update": finish(SecItemUpdate(item as CFDictionary, attributes as CFDictionary))
    default: exit(64)
    }
case "delete", "deleteService":
    guard Set(fields.keys).isSubset(of: allowed) else { exit(64) }
    finish(SecItemDelete(item as CFDictionary))
default:
    exit(64)
}

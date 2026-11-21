import Darwin
import Foundation
import os
import Security

/// The only place Mac TV calls the Keychain (SecItem): profiles' sign-ins (ProfileKeychain), network share passwords
/// (ShareKeychain), Jellyfin tokens (JellyfinKeychain) and Jasmine's API keys (JasmineKeychain) all come through here.
///
/// In the app, Mac TV doesn't touch its items itself: its keys helper does (Contents/Helpers/Mac TV Keys.app,
/// KeysHelper/main.swift), a program built once and kept as it is. Mac TV has no Apple team, so the login keychain
/// knows a program by its own hash, which every build of Mac TV changes: every update asked again, for every item.
/// The helper keeps its hash, so once the keychain allowed it, it never asks again, whatever build runs it. Items
/// Mac TV made itself before the helper are the same items (same service and account), and nothing is lost: the first
/// time the helper touches each of them the keychain asks once more, naming Mac TV Keys ("Always Allow"), then never
/// again. Without the helper (`swift run`, or a build not signed with Mac TV's certificate, which the helper doesn't
/// answer) Mac TV calls SecItem itself, as it always did.
///
/// Under the tests (TestSandbox sets MACTV_KEYCHAIN to "memory" before any test runs) each of them keeps its items
/// in memory instead, and these refuse every call, so a test never reads, writes or deletes a real item, whatever
/// order the tests run in. The app always uses the real Keychain.
///
/// A call can wait as long as the keychain's question is on screen ("Always Allow"), so every call runs on one queue of
/// its own (KeysHelper.queue), one at a time: never on the main thread, nor on a Swift concurrency thread, which
/// many waiting image loads would use up. The async forms wait there without holding their caller's thread; a read
/// kept from before (KeysHelper.reads) comes back at once in either form. The synchronous forms wait for the queue.
enum SystemKeychain {
    /// Under the tests: every Keychain user keeps its items in memory.
    static let inMemory = ProcessInfo.processInfo.environment["MACTV_KEYCHAIN"] == "memory"

    private static let refusedCalls = OSAllocatedUnfairLock(initialState: 0)
    /// Calls refused under the tests because they would have reached the real Keychain. A test checks it stays 0.
    static var refused: Int { refusedCalls.withLock { $0 } }

    static func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        let (status, data) = kept(query) ?? KeysHelper.queue.sync { readNow(query) }
        if let data { result = data as NSData }
        return status
    }

    static func add(_ item: [String: Any]) -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        return KeysHelper.queue.sync { addNow(item) }
    }

    static func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        return KeysHelper.queue.sync { updateNow(query, attributes) }
    }

    @discardableResult
    static func delete(_ query: [String: Any]) -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        return KeysHelper.queue.sync { deleteNow(query) }
    }

    // MARK: Async: the caller's thread is free while the keychain answers

    /// SecItemCopyMatching of one item's data: the status, and the data when it was read.
    static func copyMatching(_ query: [String: Any]) async -> (status: OSStatus, data: Data?) {
        guard allowed() else { return (errSecNotAvailable, nil) }
        if let kept = kept(query) { return kept }
        let query = Carried(query)
        return await KeysHelper.onQueue { readNow(query.value) }
    }

    static func add(_ item: [String: Any]) async -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        let item = Carried(item)
        return await KeysHelper.onQueue { addNow(item.value) }
    }

    static func update(_ query: [String: Any], _ attributes: [String: Any]) async -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        let query = Carried(query), attributes = Carried(attributes)
        return await KeysHelper.onQueue { updateNow(query.value, attributes.value) }
    }

    @discardableResult
    static func delete(_ query: [String: Any]) async -> OSStatus {
        guard allowed() else { return errSecNotAvailable }
        let query = Carried(query)
        return await KeysHelper.onQueue { deleteNow(query.value) }
    }

    /// A query on its way to the queue. Only property-list values (strings, data, booleans, CF constants) are in it.
    private struct Carried: @unchecked Sendable {
        let value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }

    /// The helper's read of `query` kept from before, if there is one.
    private static func kept(_ query: [String: Any]) -> (OSStatus, Data?)? {
        guard KeysHelper.answering != nil, let request = KeysRequest.read(query),
              let answer = KeysHelper.reads.answer(request) else { return nil }
        return (answer.status, answer.status == errSecSuccess ? answer.output : nil)
    }

    // On KeysHelper.queue only.

    private static func readNow(_ query: [String: Any]) -> (OSStatus, Data?) {
        if let answer = viaHelper(KeysRequest.read(query)) {
            return (answer.status, answer.status == errSecSuccess ? answer.output : nil)
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private static func addNow(_ item: [String: Any]) -> OSStatus {
        if let answer = viaHelper(KeysRequest.add(item)) { return answer.status }
        return SecItemAdd(item as CFDictionary, nil)
    }

    private static func updateNow(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        if let answer = viaHelper(KeysRequest.update(query, attributes)) { return answer.status }
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    private static func deleteNow(_ query: [String: Any]) -> OSStatus {
        if let answer = viaHelper(KeysRequest.delete(query)) { return answer.status }
        return SecItemDelete(query as CFDictionary)
    }

    private static func allowed() -> Bool {
        guard inMemory else { return true }
        refusedCalls.withLock { $0 += 1 }
        Log.app.error("Refused a Keychain call under the tests")
        return false
    }

    /// The keys helper's answer to the call; nil to call SecItem here (no helper, one that doesn't answer this build,
    /// or a query it can't carry).
    private static func viaHelper(_ request: @autoclosure () -> KeysRequest?) -> KeysHelper.Answer? {
        guard let helper = KeysHelper.answering else { return nil }
        guard let request = request() else {
            KeysHelper.once("unsupported", "A Keychain call the keys helper can't carry: Mac TV calls the Keychain itself")
            return nil
        }
        return helper.answer(request)
    }

    /// Items kept in memory under the tests, by a key each Keychain user makes from its own attributes.
    static func memoryStore() -> OSAllocatedUnfairLock<[String: Data]>? {
        inMemory ? OSAllocatedUnfairLock(initialState: [:]) : nil
    }
}

/// One request to the keys helper (KeysHelper/main.swift has the protocol): a JSON object of strings, made from the
/// query dictionaries SystemKeychain's users pass. Nil for a query the helper doesn't know, checked attribute by
/// attribute, so that nothing a caller asked for is silently left out.
struct KeysRequest: Equatable, Sendable {
    let fields: [String: String]

    /// What the helper reads on its standard input.
    var json: Data { (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data() }

    /// SecItemCopyMatching of one item's data.
    static func read(_ query: [String: Any]) -> KeysRequest? {
        var rest = query
        guard rest.removeValue(forKey: kSecReturnData as String) as? Bool == true,
              rest.removeValue(forKey: kSecMatchLimit as String) as? String == kSecMatchLimitOne as String,
              let fields = item(&rest, op: "read"), fields["account"] != nil, rest.isEmpty else { return nil }
        return KeysRequest(fields: fields)
    }

    /// SecItemAdd: the item, its data, a generic password's label, and how it may be read.
    static func add(_ item: [String: Any]) -> KeysRequest? {
        var rest = item
        guard var fields = Self.item(&rest, op: "write"), fields["account"] != nil,
              take(&rest, into: &fields) else { return nil }
        fields["mode"] = "add"
        if let accessible = rest.removeValue(forKey: kSecAttrAccessible as String) {
            guard accessible as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String else { return nil }
            fields["accessible"] = "afterFirstUnlockThisDeviceOnly"
        }
        return rest.isEmpty ? KeysRequest(fields: fields) : nil
    }

    /// SecItemUpdate of an item's data (and a generic password's label).
    static func update(_ query: [String: Any], _ attributes: [String: Any]) -> KeysRequest? {
        var rest = query, changes = attributes
        guard var fields = item(&rest, op: "write"), fields["account"] != nil, rest.isEmpty,
              take(&changes, into: &fields), changes.isEmpty else { return nil }
        fields["mode"] = "update"
        return KeysRequest(fields: fields)
    }

    /// SecItemDelete of an item, or of every generic password under a service.
    static func delete(_ query: [String: Any]) -> KeysRequest? {
        var rest = query
        guard var fields = item(&rest, op: "delete"), rest.isEmpty else { return nil }
        if fields["account"] == nil { fields["op"] = "deleteService" }
        return KeysRequest(fields: fields)
    }

    /// The attributes that name the item, taken out of `query`: a generic password's service (and account), or a
    /// network share's internet password (server, account, SMB, its label).
    private static func item(_ query: inout [String: Any], op: String) -> [String: String]? {
        var fields = ["op": op]
        /// Moves a string attribute into the fields; false when it is there but isn't a string, or is empty.
        func move(_ key: CFString, to name: String) -> Bool {
            guard let value = query.removeValue(forKey: key as String) else { return true }
            guard let value = value as? String, !value.isEmpty else { return false }
            fields[name] = value
            return true
        }
        let kind = query.removeValue(forKey: kSecClass as String) as? String
        if kind == kSecClassGenericPassword as String {
            fields["class"] = "generic"
            guard move(kSecAttrService, to: "service"), move(kSecAttrAccount, to: "account"),
                  fields["service"] != nil else { return nil }
        } else if kind == kSecClassInternetPassword as String {
            fields["class"] = "internet"
            fields["protocol"] = "smb"
            guard query.removeValue(forKey: kSecAttrProtocol as String) as? String == kSecAttrProtocolSMB as String,
                  move(kSecAttrServer, to: "server"), move(kSecAttrAccount, to: "account"),
                  move(kSecAttrLabel, to: "label"),
                  fields["server"] != nil, fields["account"] != nil, fields["label"] != nil else { return nil }
        } else {
            return nil
        }
        return fields
    }

    /// The data written (required, never empty), and a generic password's label, taken out of `attributes`.
    private static func take(_ attributes: inout [String: Any], into fields: inout [String: String]) -> Bool {
        guard let data = attributes.removeValue(forKey: kSecValueData as String) as? Data, !data.isEmpty else { return false }
        fields["data"] = data.base64EncodedString()
        if fields["class"] == "generic", let label = attributes.removeValue(forKey: kSecAttrLabel as String) {
            guard let label = label as? String else { return false }
            fields["label"] = label
        }
        return true
    }
}

/// The keys helper in this app, run once per call.
struct KeysHelper: Sendable {
    let executable: URL

    /// Where the app keeps it.
    static let bundled = Bundle.main.bundleURL
        .appending(path: "Contents/Helpers/Mac TV Keys.app/Contents/MacOS/Mac TV Keys")

    /// The helper, when this app has one: nil under `swift run` and in a build without it.
    static let installed: KeysHelper? = {
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            Log.app.notice("No keys helper in this build: Mac TV calls the Keychain itself")
            return nil
        }
        return KeysHelper(executable: bundled)
    }()

    private static let unanswered = OSAllocatedUnfairLock(initialState: false)

    /// The helper, while it answers this build of Mac TV.
    static var answering: KeysHelper? { unanswered.withLock { $0 } ? nil : installed }

    /// What the helper answered: the keychain's status, and a read's data.
    struct Answer: Equatable, Sendable {
        let status: OSStatus
        let output: Data
    }

    /// The helper's exit code as the status SecItem would have given. Nil when it doesn't answer this build of Mac TV
    /// (4: not signed with Mac TV's certificate), which then calls the Keychain itself.
    static func status(exitCode: Int32) -> OSStatus? {
        switch exitCode {
        case 0: errSecSuccess
        case 2: errSecItemNotFound
        case 3: errSecDuplicateItem
        case 4: nil
        case 5: errSecAuthFailed  // the keychain's question denied, or not shown
        case 64, 65: errSecParam  // not a request, or not Mac TV's item
        default: errSecIO  // 1, the keychain failed; or the helper ended some other way
        }
    }

    /// The answer from the helper's exit code and output: a read's data only when it read one.
    static func answer(exitCode: Int32, output: Data) -> Answer? {
        guard let status = status(exitCode: exitCode) else { return nil }
        return Answer(status: status, output: status == errSecSuccess ? output : Data())
    }

    /// Where every Keychain call runs, one at a time (SystemKeychain): a read that waited behind the same read finds
    /// its answer kept, so the keychain asks once, not once per caller.
    static let queue = DispatchQueue(label: "local.couch.tv.keys", qos: .userInitiated)

    /// Runs `work` on the queue; the caller's thread is free until it's done.
    static func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: work()) } }
    }

    /// The helper's answer to `request`, as `answer(_:)`, without holding the caller's thread while it runs.
    func answer(_ request: KeysRequest) async -> Answer? {
        if request.fields["op"] == "read", let kept = Self.reads.answer(request) { return kept }
        return await Self.onQueue { self.answer(request) }
    }

    /// The helper's answer to `request`, a read kept from before when there is one. Nil when it doesn't answer this
    /// build (from then on, Mac TV calls the Keychain itself); a helper that doesn't start is errSecNotAvailable.
    /// It runs the helper on the calling thread: SystemKeychain calls it on the queue.
    func answer(_ request: KeysRequest) -> Answer? {
        let reading = request.fields["op"] == "read"
        if reading, let kept = Self.reads.answer(request) { return kept }
        let generation = Self.reads.generation
        if !reading { Self.reads.forget() }
        defer { if !reading { Self.reads.forget() } }
        guard let (exitCode, output) = Self.spawn(executable.path, input: request.json) else {
            Self.once("spawn", "The keys helper didn't start")
            return Answer(status: errSecNotAvailable, output: Data())
        }
        guard let answer = Self.answer(exitCode: exitCode, output: output) else {
            Self.unanswered.withLock { $0 = true }
            Self.once("refused", "The keys helper doesn't answer this build: Mac TV calls the Keychain itself")
            return nil
        }
        if answer.status != errSecSuccess, answer.status != errSecItemNotFound {
            Log.app.error("The keys helper ended with \(exitCode, privacy: .public)")
        }
        if reading { Self.reads.keep(request, answer, generation: generation) }
        return answer
    }

    /// Runs `path` with `input` on its standard input until it ends: its exit code (-1 when a signal ended it) and
    /// its standard output. posix_spawn and waitpid, not Process, whose waitUntilExit runs the run loop while it
    /// waits. Only standard input, output and error (/dev/null) are passed to it. Nil when it doesn't start.
    private static func spawn(_ path: String, input: Data) -> (Int32, Data)? {
        var request: [Int32] = [-1, -1], reply: [Int32] = [-1, -1]
        guard pipe(&request) == 0 else { return nil }
        guard pipe(&reply) == 0 else { close(request[0]); close(request[1]); return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, request[0], 0)
        posix_spawn_file_actions_adddup2(&actions, reply[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + environment).forEach { free($0) } }
        let started = posix_spawn(&pid, path, &actions, &attributes, argv, environment)
        close(request[0])
        close(reply[1])
        guard started == 0 else { close(request[1]); close(reply[0]); return nil }

        // A helper that ends before it reads its input doesn't end the app (no SIGPIPE on that pipe)
        _ = fcntl(request[1], F_SETNOSIGPIPE, 1)
        input.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(request[1], buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { break }
                offset += written
            }
        }
        close(request[1])
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(reply[0], &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            output.append(contentsOf: chunk[..<count])
        }
        close(reply[0])
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return (status & 0x7f == 0 ? (status >> 8) & 0xff : -1, output)
    }

    private static let logged = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Logs `message` the first time only.
    static func once(_ key: String, _ message: String) {
        guard logged.withLock({ $0.insert(key).inserted }) else { return }
        Log.app.notice("\(message, privacy: .public)")
    }

    /// The helper's reads, kept for this run so that Mac TV doesn't start it for every Jellyfin request; every write
    /// or delete forgets them all.
    static let reads = Reads()

    final class Reads: Sendable {
        private struct State { var generation = 0, answers: [Data: Answer] = [:] }
        private let state = OSAllocatedUnfairLock(initialState: State())

        var generation: Int { state.withLock { $0.generation } }

        func answer(_ request: KeysRequest) -> Answer? { state.withLock { $0.answers[request.json] } }

        /// Keeps a read's answer, the data or that there's no such item, unless something changed since it began.
        func keep(_ request: KeysRequest, _ answer: Answer, generation: Int) {
            guard answer.status == errSecSuccess || answer.status == errSecItemNotFound else { return }
            state.withLock { if $0.generation == generation { $0.answers[request.json] = answer } }
        }

        func forget() { state.withLock { $0.generation += 1; $0.answers = [:] } }
    }
}

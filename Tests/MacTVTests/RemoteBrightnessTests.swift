import AppKit
import Foundation
import Testing
@testable import MacTV

/// A display's brightness in memory: what a read gives, and every value written.
private actor MemoryBrightness: BrightnessControl {
    private let start: Int?
    private(set) var writes: [Int] = []

    init(_ level: Int?) { start = level }

    nonisolated var writeInterval: Duration { .zero }
    func read() async -> Int? { start }
    func write(_ percent: Int) async { writes.append(percent) }
}

/// The phone's Settings › Brightness (/display/brightness): the Display sheet's brightness, set from the phone. Each
/// test has its own DisplayBrightness on a display in memory, so nothing touches a real display or the shared one.
@Suite(.timeLimit(.minutes(1))) @MainActor struct RemoteBrightnessTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    private func withTV(brightness level: Int?, _ body: (TVController, MemoryBrightness) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let display = MemoryBrightness(level)
        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)
        tv.remoteCoordinator.brightness = DisplayBrightness(control: { _ in display })
        try await body(tv, display)
    }

    /// The answer's status and its "level" (NSNull when Not Available).
    private func ask(_ tv: TVController, _ method: String, _ body: Any? = nil) async throws -> (String, Any?) {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var response = try #require(tv.handleAppsRequest(HTTPRequest(method: method, path: "/display/brightness", query: [:],
                                                                    headers: [:], body: data)))
        if let pending = response.pending { response = await pending() }
        let answer = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return (response.status, answer?["level"] ?? answer?["error"])
    }

    @Test func readsAndSetsTheDisplaysBrightness() async throws {
        try await withTV(brightness: 40) { tv, display in
            let (status, level) = try await ask(tv, "GET")
            #expect(status == "200 OK" && level as? Int == 40)

            let answer1 = try await ask(tv, "POST", ["level": 75])
            #expect(answer1.1 as? Int == 75)
            let answer2 = try await ask(tv, "POST", ["level": 62.6])
            #expect(answer2.1 as? Int == 63)
            let answer3 = try await ask(tv, "POST", ["level": 140])
            #expect(answer3.1 as? Int == 100)   // 0–100
            let answer4 = try await ask(tv, "POST", ["level": -5])
            #expect(answer4.1 as? Int == 0)
            #expect(tv.remoteCoordinator.brightness.level == 0)
            await tv.remoteCoordinator.brightness.finishWriting()
            #expect(await display.writes.last == 0)
            // The shared one, the Display sheet's in the app, was never touched
            #expect(tv.remoteCoordinator.brightness !== DisplayBrightness.shared)
        }
    }

    @Test func aSetBeforeAnyReadReadsFirst() async throws {
        try await withTV(brightness: 30) { tv, display in
            let answer5 = try await ask(tv, "POST", ["level": 55])
            #expect(answer5.1 as? Int == 55)
            await tv.remoteCoordinator.brightness.finishWriting()
            #expect(await display.writes == [55])
        }
    }

    @Test func notAvailableAnswersNoLevel() async throws {
        try await withTV(brightness: nil) { tv, display in
            let (status, level) = try await ask(tv, "GET")
            #expect(status == "200 OK" && level is NSNull)
            let answer6 = try await ask(tv, "POST", ["level": 80])
            #expect(answer6.1 is NSNull)
            #expect(await display.writes.isEmpty)
        }
    }

    @Test func onlyANumberIsABrightness() async throws {
        try await withTV(brightness: 40) { tv, display in
            for body: Any in [["level": true], ["level": "50"], ["other": 1], [1, 2]] {
                let answer7 = try await ask(tv, "POST", body)
                #expect(answer7.0 == "400 Bad Request")
            }
            let answer8 = try await ask(tv, "PUT")
            #expect(answer8.0 == "404 Not Found")
            #expect(await display.writes.isEmpty)
        }
    }

    /// Like choosing the display, it's for a trusted remote: a guest's phone is turned away before it gets here.
    @Test func guestsCantSetTheBrightness() async throws {
        try await withTV(brightness: 40) { tv, display in
            let pairing = tv.remoteCoordinator.pairingStore
            let guest = try pairing.issue(name: "Guest", guest: true)
            let owner = try pairing.issue(name: "Owner", guest: false)
            let server = RemoteServer(token: "", onCommand: { _ in }, state: { [:] }, icon: { _ in nil },
                                      routes: { tv.handleAppsRequest($0) }, pairing: pairing)
            defer { server.stop() }
            let body = try JSONSerialization.data(withJSONObject: ["level": 20])
            let post = { (token: String) in HTTPRequest(method: "POST", path: "/display/brightness", query: [:],
                                                        headers: ["x-couch-key": token], body: body) }
            #expect(await server.answer(post(guest)).status == "403 Forbidden")
            #expect(await server.answer(post(owner)).status == "200 OK")
            await tv.remoteCoordinator.brightness.finishWriting()
            #expect(await display.writes == [20])
        }
    }
}

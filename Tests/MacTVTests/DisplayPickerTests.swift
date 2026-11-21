import AppKit
import Foundation
import Testing
@testable import MacTV

/// A display's brightness that lives in memory: what a read gives, and every value written.
private actor FakeBrightness: BrightnessControl {
    private let start: Int?
    private(set) var writes: [Int] = []

    init(_ level: Int?) { start = level }

    nonisolated var writeInterval: Duration { .zero }
    func read() async -> Int? { start }
    func write(_ percent: Int) async { writes.append(percent) }
}

/// What the sheet chose, in order.
@MainActor private final class ChoiceRecorder {
    var chosen: [ControlCenterPanel.Choice] = []
}

/// Control Center's Display tile: the Display sheet, built like Audio Output. Fakes stand in for the displays, for
/// choosing one and for the brightness, so nothing here moves the window or touches a real display.
@Suite(.timeLimit(.minutes(1))) @MainActor struct DisplayPickerTests {
    init() {
        _ = NSApplication.shared
        AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) }
    }

    private static let choices: [ControlCenterPanel.Choice] = [.fullScreen, .automaticDisplay, .display("A"), .display("B")]
    private static let brightnessRow = choices.count

    /// A TV with two displays to choose from and a brightness of `brightness` (nil: not available).
    private func withTV(brightness: Int?, _ body: (TVController, FakeBrightness, ChoiceRecorder) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let saved = (DisplayPickerPanel.choices, DisplayPickerPanel.choose, DisplayBrightness.control)
        defer { (DisplayPickerPanel.choices, DisplayPickerPanel.choose, DisplayBrightness.control) = saved }
        let fake = FakeBrightness(brightness)
        let recorder = ChoiceRecorder()
        DisplayPickerPanel.choices = { _ in Self.choices }
        DisplayPickerPanel.choose = { _, choice in recorder.chosen.append(choice) }
        DisplayBrightness.control = { _ in fake }

        let tv = TVController(library: AppLibrary(folder: folder), profiles: ProfileStore(folder: folder))
        tv.remoteCoordinator.pairingStore = PairingStore(folder: folder)
        try await body(tv, fake, recorder)
    }

    @Test func rowsAreTheDisplayChoicesThenBrightness() async throws {
        try await withTV(brightness: 50) { tv, _, _ in
            #expect(tv.displayPicker == nil)
            tv.openDisplayPicker()
            #expect(tv.activeSheet == .displayPicker && tv.isTopSheet(.displayPicker))
            #expect(tv.displayPickerChoices == Self.choices)
            #expect(tv.controlCenterChoice(.fullScreen).title == "Full Screen")
            #expect(tv.controlCenterChoice(.fullScreen).accessory == .toggle(tv.dedicatedTVMode))
            #expect(tv.controlCenterChoice(.automaticDisplay).title == "Automatic")
            // Focus starts on the choice in use: Automatic, with no display preferred.
            if tv.preferences.preferredTVDisplay == nil { #expect(tv.displayPicker?.row == 1) }

            tv.displayPicker?.row = 0
            tv.handleDisplayPicker(.move(.up))
            #expect(tv.displayPicker?.row == 0)
            for row in 1...Self.brightnessRow {
                tv.handleDisplayPicker(.move(.down))
                #expect(tv.displayPicker?.row == row)
            }
            // The Brightness slider is last.
            tv.handleDisplayPicker(.move(.down))
            #expect(tv.displayPicker?.row == Self.brightnessRow)
            // Left and right on a choice do nothing.
            tv.displayPicker?.row = 2
            tv.handleDisplayPicker(.move(.right))
            tv.handleDisplayPicker(.move(.left))
            #expect(tv.displayPicker?.row == 2)
        }
    }

    @Test func choosingADisplayOrFullScreenUsesControlCenterChoices() async throws {
        try await withTV(brightness: 50) { tv, _, recorder in
            tv.openDisplayPicker()
            for row in [0, 3, 1, Self.brightnessRow] {
                tv.displayPicker?.row = row
                tv.handleDisplayPicker(.select)
            }
            // Full Screen, display B, Automatic; Select on the slider chooses nothing.
            #expect(recorder.chosen == [.fullScreen, .display("B"), .automaticDisplay])
            // Choosing keeps the sheet open, focus where it was, as Audio Output does.
            #expect(tv.activeSheet == .displayPicker && tv.displayPicker?.row == Self.brightnessRow)
        }
    }

    @Test func brightnessStepsByFiveLive() async throws {
        try await withTV(brightness: 50) { tv, fake, _ in
            tv.openDisplayPicker()
            #expect(DisplayBrightness.shared.pending)
            await DisplayBrightness.shared.finishReading()
            #expect(DisplayBrightness.shared.level == 50 && !DisplayBrightness.shared.pending)

            tv.displayPicker?.row = Self.brightnessRow
            tv.handleDisplayPicker(.move(.right))
            #expect(DisplayBrightness.shared.level == 55)
            await DisplayBrightness.shared.finishWriting()
            #expect(await fake.writes == [55])

            tv.handleDisplayPicker(.move(.left))
            tv.handleDisplayPicker(.move(.left))
            #expect(DisplayBrightness.shared.level == 45)
            await DisplayBrightness.shared.finishWriting()
            #expect(await fake.writes.last == 45)
            #expect(tv.displayPicker?.row == Self.brightnessRow)

            // It stops at either end, and writes nothing more there.
            for _ in 0..<12 { tv.handleDisplayPicker(.move(.left)) }
            await DisplayBrightness.shared.finishWriting()
            #expect(DisplayBrightness.shared.level == 0)
            let writes = await fake.writes.count
            tv.handleDisplayPicker(.move(.left))
            await DisplayBrightness.shared.finishWriting()
            #expect(await fake.writes.count == writes)
            DisplayBrightness.shared.set(140)
            #expect(DisplayBrightness.shared.level == 100)
        }
    }

    @Test func brightnessNotAvailableWhenTheDisplayDoesNotSay() async throws {
        try await withTV(brightness: nil) { tv, fake, _ in
            tv.openDisplayPicker()
            await DisplayBrightness.shared.finishReading()
            #expect(DisplayBrightness.shared.level == nil && !DisplayBrightness.shared.pending)
            tv.displayPicker?.row = Self.brightnessRow
            tv.handleDisplayPicker(.move(.right))
            tv.handleDisplayPicker(.move(.left))
            DisplayBrightness.shared.set(80)
            #expect(DisplayBrightness.shared.level == nil)
            #expect(await fake.writes.isEmpty)
        }
        // Nothing to set the brightness with at all says the same.
        try await withTV(brightness: 50) { tv, _, _ in
            DisplayBrightness.control = { _ in nil }
            tv.openDisplayPicker()
            await DisplayBrightness.shared.finishReading()
            #expect(DisplayBrightness.shared.level == nil && !DisplayBrightness.shared.pending)
        }
    }

    @Test func backReturnsToControlCenterOnTheDisplayTile() async throws {
        try await withTV(brightness: 50) { tv, _, _ in
            tv.openControlCenter()
            tv.controlCenter?.item = .display
            tv.openDisplayPicker()
            #expect(tv.sheets.open == [.controlCenter, .displayPicker])
            #expect(tv.activeSheet == .displayPicker)
            #expect(SheetStack.Layer.displayPicker.remoteName == "display-picker")
            // Through the remote's own path, as a press arrives.
            tv.handle(.back)
            #expect(tv.displayPicker == nil)
            #expect(tv.activeSheet == .controlCenter && tv.controlCenter?.item == .display)
            // Home closes it with Control Center under it.
            tv.openDisplayPicker()
            tv.handle(.home)
            #expect(tv.sheets.open.isEmpty)
        }
    }

    @Test func realBrightnessWritesAreRefusedInTests() async {
        SystemGuard.forgetRefused()
        await SystemBrightness(display: CGMainDisplayID()).write(40)
        #expect(SystemGuard.refused.contains { $0.contains("display brightness") })
    }
}

import AppKit

// The brightness of the display Mac TV is on, 0–100%, for the Display sheet's slider. Two ways to set it:
// - macOS's own DisplayServices (what the brightness keys use): the built-in display, and Apple's external ones
//   (Studio Display, Pro Display XDR). No permission needed.
// - DDC/CI VCP 0x10 (luminance) for any other external display, over the same IOAVService path the display volume
//   uses (DisplayVolume.swift: AVServiceDDC). Many TVs ignore it: then there is no brightness, and the slider says
//   Not Available.
// Every write passes SystemGuard (DisplayServices here, DDC in AVServiceDDC.write), so a test run never changes the
// real brightness; tests swap `DisplayBrightness.control` for a fake, so they never read a real display either.

extension VCP {
    /// Luminance: the display's brightness (current value and the display's own maximum).
    static let luminance: UInt8 = 0x10
}

/// What reads and sets one display's brightness. Tests use a fake.
protocol BrightnessControl: Sendable {
    /// The least time between two writes: a slider dragged quickly sends only the latest value at this pace.
    var writeInterval: Duration { get }
    /// 0–100, or nil when the display doesn't say (it ignores DDC brightness, or DisplayServices can't read it).
    func read() async -> Int?
    func write(_ percent: Int) async
}

/// The private DisplayServices functions the brightness keys go through, found at run time.
private struct DisplayServicesAPI: @unchecked Sendable {
    typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    let canChange: CanChange
    let get: GetBrightness
    let set: SetBrightness

    static let shared: DisplayServicesAPI? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let canChange = dlsym(framework, "DisplayServicesCanChangeBrightness"),
              let get = dlsym(framework, "DisplayServicesGetBrightness"),
              let set = dlsym(framework, "DisplayServicesSetBrightness") else { return nil }
        return DisplayServicesAPI(canChange: unsafeBitCast(canChange, to: CanChange.self),
                                  get: unsafeBitCast(get, to: GetBrightness.self),
                                  set: unsafeBitCast(set, to: SetBrightness.self))
    }()
}

/// A display macOS sets the brightness of itself: the built-in one, or an Apple display.
struct SystemBrightness: BrightnessControl {
    let display: CGDirectDisplayID

    var writeInterval: Duration { .milliseconds(16) }

    /// macOS can set this display's brightness.
    static func available(_ display: CGDirectDisplayID) -> Bool {
        DisplayServicesAPI.shared?.canChange(display) ?? false
    }

    func read() async -> Int? {
        guard let api = DisplayServicesAPI.shared else { return nil }
        var value: Float = 0
        guard api.get(display, &value) == 0, value.isFinite else { return nil }
        return Int((max(0, min(1, value)) * 100).rounded())
    }

    func write(_ percent: Int) async {
        guard SystemGuard.allows("set the display brightness to \(percent)%"), let api = DisplayServicesAPI.shared else { return }
        let status = api.set(display, Float(max(0, min(100, percent))) / 100)
        if status != 0 { Log.display.error("Couldn't set the display brightness: \(status, privacy: .public)") }
    }
}

/// An external display's brightness over DDC/CI (VCP 0x10), in the display's own units up to the maximum it gives.
actor DDCBrightness: BrightnessControl {
    private let ddc: any DisplayDDC
    private var maximum = 100

    init(ddc: any DisplayDDC) { self.ddc = ddc }

    nonisolated var writeInterval: Duration { .milliseconds(60) }

    func read() async -> Int? {
        guard let value = await ddc.read(VCP.luminance), value.max > 0 else { return nil }
        maximum = value.max
        return DisplayVolumeScale.percent(value.current, max: value.max)
    }

    func write(_ percent: Int) async {
        await ddc.write(VCP.luminance, value: DisplayVolumeScale.raw(percent, max: maximum))
    }
}

/// The Display sheet's brightness: read once when the sheet opens (and when Mac TV moves to another display), then
/// stepped here and written in the background, only the latest value, as the display volume is.
@MainActor
final class DisplayBrightness: ObservableObject {
    static let shared = DisplayBrightness()

    /// What sets a display's brightness, or nil when nothing can. Tests swap it for a fake.
    static var control: @MainActor (CGDirectDisplayID?) async -> (any BrightnessControl)? = { await systemControl(for: $0) }

    /// 0–100; nil when the display has no brightness Mac TV can set (Not Available).
    @Published private(set) var level: Int?
    /// Still asking the display: the slider waits empty rather than saying Not Available.
    @Published private(set) var pending = false

    private var writer: LatestValueWriter<Int>?
    private var reading: Task<Void, Never>?
    private var generation = 0
    private let control: @MainActor (CGDirectDisplayID?) async -> (any BrightnessControl)?

    /// `control`: what sets the display's brightness; a test's own, or `DisplayBrightness.control`.
    init(control: (@MainActor (CGDirectDisplayID?) async -> (any BrightnessControl)?)? = nil) {
        self.control = control ?? { await DisplayBrightness.control($0) }
    }

    /// Reads the brightness of `display` (the one Mac TV is on) afresh.
    func refresh(display: CGDirectDisplayID?) {
        generation += 1
        let generation = generation
        pending = true
        let find = control
        reading = Task { [weak self] in
            let control = await find(display)
            let level = await control?.read()
            guard let self, self.generation == generation else { return }
            if let control, let level {
                let writer = LatestValueWriter<Int>(interval: control.writeInterval) { _, next in await control.write(next) }
                writer.reset(to: level)
                self.writer = writer
            } else {
                self.writer = nil
            }
            self.level = level
            self.pending = false
        }
    }

    /// Sets it to `percent` (0–100), live. Nothing while it's unknown or not available.
    func set(_ percent: Int) {
        guard level != nil, !pending, let writer else { return }
        let clamped = max(0, min(100, percent))
        guard clamped != level else { return }
        level = clamped
        writer.submit(clamped)
    }

    func step(by delta: Int) {
        guard let level else { return }
        set(level + delta)
    }

    /// For tests: wait for the read, or for the writes to reach the display.
    func finishReading() async { await reading?.value }
    func finishWriting() async { await writer?.finish() }

    /// The real display: DisplayServices when macOS can set it, otherwise DDC on an external display (Apple silicon).
    static func systemControl(for display: CGDirectDisplayID?) async -> (any BrightnessControl)? {
        guard let display else { return nil }
        if SystemBrightness.available(display) { return SystemBrightness(display: display) }
        guard CGDisplayIsBuiltin(display) == 0 else { return nil }
        #if arch(arm64)
        // DDC talks to the display over I²C: a test run never does.
        guard SystemGuard.allows("read the display brightness over DDC") else { return nil }
        let screen = NSScreen.screens.first { $0.displayID == display }
        let name = screen?.localizedName ?? ""
        let uid = CGDisplayCreateUUIDFromDisplayID(display).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
        guard let ddc = await DDCQueue.run({ AVServiceDDC.scan(uid: uid, name: name) }) else { return nil }
        return DDCBrightness(ddc: ddc)
        #else
        return nil
        #endif
    }
}

import AVFoundation
import AppKit
import WebKit
import CoreAudio
import Foundation
import Testing
@testable import MacTV

/// 一块假的显示器：记着 VCP 的值和每一次读写，不碰硬件
actor FakeDisplay: DisplayDDC {
    var values: [UInt8: DDCValue]
    /// 说认 0x8D，写了却不静音
    var ignoresMute = false
    var answers = true
    private(set) var reads: [UInt8] = []
    private(set) var writes: [(code: UInt8, value: Int)] = []
    private let delay: Duration

    init(volume: Int = 75, max: Int = 100, mute: Int? = VCP.muteOff, delay: Duration = .milliseconds(2)) {
        values = [VCP.volume: DDCValue(current: volume, max: max)]
        if let mute { values[VCP.mute] = DDCValue(current: mute, max: 2) }
        self.delay = delay
    }

    func read(_ code: UInt8) async -> DDCValue? {
        try? await Task.sleep(for: delay)
        reads.append(code)
        return answers ? values[code] : nil
    }

    @discardableResult
    func write(_ code: UInt8, value: Int) async -> Bool {
        try? await Task.sleep(for: delay)
        writes.append((code, value))
        guard answers, var current = values[code] else { return answers }
        if code == VCP.mute, ignoresMute { return true }
        current.current = value
        values[code] = current
        return true
    }

    /// 别处（MonitorControl、显示器自己的按键）调了音量
    func setVolume(_ value: Int) { values[VCP.volume]?.current = value }
    func setAnswers(_ value: Bool) { answers = value }
    func setIgnoresMute(_ value: Bool) { ignoresMute = value }
    func volumeWrites() -> [Int] { writes.filter { $0.code == VCP.volume }.map(\.value) }
    func muteWrites() -> [Int] { writes.filter { $0.code == VCP.mute }.map(\.value) }
}

/// 等到条件成立（异步的读写），最多等 2 秒
@MainActor
func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct DisplayVolumeTests {
    // MARK: 包

    @Test func requestsAreDDCCIPackets() {
        // 和 MonitorControl、m1ddc 发的一样：读的校验从 0x6E 算起，写的从 0x6E ^ 0x51 算起
        #expect(DDCPacket.getRequest(0x62) == [0x82, 0x01, 0x62, 0x8F])
        #expect(DDCPacket.setRequest(0x62, value: 75) == [0x84, 0x03, 0x62, 0x00, 0x4B, 0x91])
        #expect(DDCPacket.setRequest(0x8D, value: 1).prefix(5) == [0x84, 0x03, 0x8D, 0x00, 0x01])
    }

    @Test func repliesParseLikeTheXG27UCSAnswers() {
        // 实测：XG27UCS 回的音量 75 / 100，静音 2（没静音）/ 2
        let volume: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x4B, 0xF9]
        #expect(DDCPacket.parse(volume, code: 0x62) == .value(DDCValue(current: 75, max: 100)))
        let mute: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x8D, 0x00, 0x00, 0x02, 0x00, 0x02, 0x39]
        #expect(DDCPacket.parse(mute, code: 0x8D) == .value(DDCValue(current: 2, max: 2)))

        var unsupported = volume
        unsupported[3] = 0x01
        unsupported[10] = unsupported.dropLast().reduce(UInt8(0x50), ^)
        #expect(DDCPacket.parse(unsupported, code: 0x62) == .unsupported)

        var corrupt = volume
        corrupt[10] ^= 0xFF
        #expect(DDCPacket.parse(corrupt, code: 0x62) == .invalid)
        #expect(DDCPacket.parse(volume, code: 0x10) == .invalid)
        #expect(DDCPacket.parse(Array(volume.prefix(8)), code: 0x62) == .invalid)
    }

    @Test func levelsMapToTheDisplaysOwnRange() {
        #expect(DisplayVolumeScale.percent(75, max: 100) == 75)
        #expect(DisplayVolumeScale.percent(15, max: 30) == 50)
        #expect(DisplayVolumeScale.percent(40, max: 30) == 100)
        #expect(DisplayVolumeScale.percent(5, max: 0) == 0)
        #expect(DisplayVolumeScale.raw(56, max: 30) == 17)
        #expect(DisplayVolumeScale.raw(100, max: 30) == 30)
        #expect(DisplayVolumeScale.raw(-5, max: 100) == 0)
        #expect(DisplayVolumeScale.raw(120, max: 100) == 100)
    }

    // MARK: 哪块显示器

    @Test func outputsMatchTheirDisplay() {
        let displays = [DisplayAudioLink.Candidate(edidUUID: "10AC-1", productName: "DELL U2723QE"),
                        DisplayAudioLink.Candidate(edidUUID: "06B35427-0000-0000-2821-0104B53C2278", productName: "XG27UCS")]
        // Apple 芯片上，显示器声音的 UID 就是它的 EDID UUID
        #expect(DisplayAudioLink.pick(displays, uid: "06b35427-0000-0000-2821-0104b53c2278", name: "XG27UCS") == 1)
        // UID 对不上时按名字
        #expect(DisplayAudioLink.pick(displays, uid: "AppleGFXHDAEngineOutputDP:0", name: "DELL U2723QE") == 0)
        // 两块一样的显示器、名字分不出来：不猜
        let twins = [DisplayAudioLink.Candidate(edidUUID: nil, productName: "LG TV"),
                     DisplayAudioLink.Candidate(edidUUID: nil, productName: "LG TV")]
        #expect(DisplayAudioLink.pick(twins, uid: "", name: "LG TV") == nil)
        // 声音经功放出去（名字是功放的）：显示器的音量管不着它
        #expect(DisplayAudioLink.pick(displays, uid: "", name: "DENON-AVR") == nil)

        let hdmi = AudioOutputDevice(id: 1, name: "LG TV", transport: kAudioDeviceTransportTypeHDMI, isDefault: true)
        let displayPort = AudioOutputDevice(id: 2, name: "XG27UCS", transport: 0x64707274, isDefault: true)
        let usb = AudioOutputDevice(id: 3, name: "DAC", transport: kAudioDeviceTransportTypeUSB, isDefault: true)
        #expect(DisplayAudioLink.isDisplayAudio(hdmi))
        #expect(DisplayAudioLink.isDisplayAudio(displayPort))
        #expect(!DisplayAudioLink.isDisplayAudio(usb))
    }

    // MARK: 本地怎么算

    @Test func theModelStepsLikeTheVolumeKeys() {
        var model = DisplayVolumeModel(volume: DDCValue(current: 75, max: 100), mute: DDCValue(current: 2, max: 2), previous: nil)
        #expect(model.volume == VolumeLevel(level: 75, muted: false))
        #expect(model.target == DisplayTarget(raw: 75, muted: false))

        model.apply(.toggleMute)
        #expect(model.target == DisplayTarget(raw: 75, muted: true))
        model.apply(.step(-6))   // 调小不取消静音
        #expect(model.volume == VolumeLevel(level: 69, muted: true))
        model.apply(.step(6))    // 调大取消
        #expect(model.volume == VolumeLevel(level: 75, muted: false))
        model.apply(.step(60))
        #expect(model.level == 100)
        model.apply(.toggleMute)
        model.apply(.set(30))    // 拖音量条也取消静音
        #expect(model.volume == VolumeLevel(level: 30, muted: false))

        // 显示器最大值 30：音量条上一样是 0–100
        var small = DisplayVolumeModel(volume: DDCValue(current: 15, max: 30), mute: nil, previous: nil)
        #expect(small.level == 50)
        small.apply(.step(6))
        #expect(small.target.raw == 17)
    }

    @Test func withoutMuteCommandMutingWritesZeroAndRemembers() {
        var model = DisplayVolumeModel(volume: DDCValue(current: 40, max: 100), mute: nil, previous: nil)
        model.apply(.toggleMute)
        #expect(model.target == DisplayTarget(raw: 0, muted: nil))
        #expect(model.volume == VolumeLevel(level: 40, muted: true))

        // 下一串按键开头读到的还是 0：还在静音，记着的 40 不丢
        let reread = DisplayVolumeModel(volume: DDCValue(current: 0, max: 100), mute: nil, previous: model)
        #expect(reread.volume == VolumeLevel(level: 40, muted: true))
        var unmuted = reread
        unmuted.apply(.toggleMute)
        #expect(unmuted.target == DisplayTarget(raw: 40, muted: nil))

        // 别处把音量调上来了：照读到的来
        let changed = DisplayVolumeModel(volume: DDCValue(current: 25, max: 100), mute: nil, previous: model)
        #expect(changed.volume == VolumeLevel(level: 25, muted: false))
    }

    // MARK: 合着写

    @Test func theWriterSendsOnlyTheLatestValueAndEndsOnIt() async {
        var written: [Int] = []
        var starts: [ContinuousClock.Instant] = []
        let writer = LatestValueWriter<Int>(interval: .milliseconds(50)) { _, value in
            starts.append(.now)
            written.append(value)
            try? await Task.sleep(for: .milliseconds(10))
        }
        writer.reset(to: 0)
        writer.submit(0)
        #expect(writer.isIdle)   // 显示器上已经是这个值

        writer.submit(1)
        try? await Task.sleep(for: .milliseconds(5))
        for value in 2...6 { writer.submit(value) }   // 写着第一个时连按了五下
        await writer.finish()
        #expect(written == [1, 6])
        #expect(writer.written == 6)
        #expect(starts[1] - starts[0] >= .milliseconds(50))

        // 一下子按了几下、还没开始写：只写最后一个
        for value in 7...9 { writer.submit(value) }
        await writer.finish()
        #expect(written == [1, 6, 9])
    }

    // MARK: 一串按键

    @Test func aBurstReadsTheDisplayOnceThenStepsLocally() async {
        let display = FakeDisplay(volume: 75)
        let controller = DisplayVolumeController(ddc: display, writeInterval: .milliseconds(20))
        controller.burstGap = .milliseconds(150)
        var levels: [VolumeLevel] = []
        controller.onLevel = { levels.append($0) }

        for _ in 0..<3 { controller.perform(.step(6)) }
        #expect(await eventually { levels.count == 1 })
        #expect(levels.last == VolumeLevel(level: 93, muted: false))   // 读到 75，再加三格
        controller.perform(.step(6))
        #expect(levels.last == VolumeLevel(level: 99, muted: false))   // 同一串里马上出，不再读
        await controller.finishWriting()
        #expect(await display.reads == [VCP.volume, VCP.mute])
        #expect(await display.volumeWrites().last == 99)
        #expect(await display.volumeWrites().count <= 2)

        // MonitorControl 在两串之间把音量调到了 20：下一串从 20 开始，不和它打架
        await display.setVolume(20)
        try? await Task.sleep(for: .milliseconds(200))
        controller.perform(.step(-6))
        #expect(await eventually { levels.count == 3 })
        #expect(levels.last == VolumeLevel(level: 14, muted: false))
        await controller.finishWriting()
        #expect(await display.volumeWrites().last == 14)
        #expect(await display.reads.count == 4)
    }

    @Test func muteUsesTheDisplaysMuteCommand() async {
        let display = FakeDisplay(volume: 50)
        let controller = DisplayVolumeController(ddc: display, writeInterval: .milliseconds(10))
        var levels: [VolumeLevel] = []
        controller.onLevel = { levels.append($0) }

        controller.perform(.toggleMute)
        #expect(await eventually { levels.count == 1 })
        #expect(levels.last == VolumeLevel(level: 50, muted: true))
        await controller.finishWriting()
        #expect(await display.muteWrites() == [VCP.muteOn])
        #expect(await display.volumeWrites().isEmpty)

        controller.perform(.step(6))   // 调大取消静音
        await controller.finishWriting()
        #expect(levels.last == VolumeLevel(level: 56, muted: false))
        #expect(await display.volumeWrites() == [56])
        #expect(await display.muteWrites() == [VCP.muteOn, VCP.muteOff])
    }

    @Test func aMuteCommandThatDoesNothingFallsBackToZero() async {
        let display = FakeDisplay(volume: 50)
        await display.setIgnoresMute(true)
        let controller = DisplayVolumeController(ddc: display, writeInterval: .milliseconds(10))
        var levels: [VolumeLevel] = []
        controller.onLevel = { levels.append($0) }

        controller.perform(.toggleMute)
        #expect(await eventually { levels.count == 1 })
        await controller.finishWriting()
        #expect(await display.volumeWrites() == [0])   // 读回来没静音：写 0
        #expect(levels.last == VolumeLevel(level: 50, muted: true))
        // 也许其实静了、只是读回来不对：马上发一次"不静音"，以后不再发 0x8D，显示器不会一直静着
        #expect(await display.muteWrites() == [VCP.muteOn, VCP.muteOff])

        controller.perform(.toggleMute)
        await controller.finishWriting()
        #expect(await display.volumeWrites() == [0, 50])
        #expect(levels.last == VolumeLevel(level: 50, muted: false))
        #expect(await display.muteWrites() == [VCP.muteOn, VCP.muteOff])
    }

    @Test func aDisplayWithoutMuteGetsZeroAndItsLevelBack() async {
        let display = FakeDisplay(volume: 30, mute: nil)
        let controller = DisplayVolumeController(ddc: display, writeInterval: .milliseconds(10))
        var levels: [VolumeLevel] = []
        controller.onLevel = { levels.append($0) }

        controller.perform(.toggleMute)
        #expect(await eventually { levels.count == 1 })
        await controller.finishWriting()
        #expect(await display.volumeWrites() == [0])
        controller.perform(.step(6))
        await controller.finishWriting()
        #expect(await display.volumeWrites() == [0, 36])
        #expect(await display.muteWrites().isEmpty)
    }

    @Test func aSilentDisplayHandsThePressesBack() async {
        let display = FakeDisplay()
        await display.setAnswers(false)
        let controller = DisplayVolumeController(ddc: display)
        var returned: [VolumeAction] = []
        controller.onUnavailable = { returned = $0 }
        controller.perform(.step(6))
        controller.perform(.toggleMute)
        #expect(await eventually { !returned.isEmpty })
        #expect(returned == [.step(6), .toggleMute])
        #expect(controller.model == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct FixedOutputVolumeTests {
    let suite = "MacTVTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let display = AudioOutputDevice(id: 9, name: "XG27UCS", transport: 0x64707274, isDefault: true, uid: "EDID-1")
    let tv = AudioOutputDevice(id: 10, name: "LG TV", transport: kAudioDeviceTransportTypeHDMI, isDefault: true, uid: "EDID-2")

    init() { defaults = TestDefaults.named(suite) }

    private func make(_ ddc: (any DisplayDDC)?, playback: PlaybackVolume? = nil) -> (FixedOutputVolume, PlaybackVolume, Box) {
        let playback = playback ?? PlaybackVolume(defaults: defaults)
        let volume = FixedOutputVolume(playback: playback, writeInterval: .milliseconds(10))
        volume.findDisplay = { _ in ddc }
        let box = Box()
        volume.onChange = { box.changes.append(($0, $1)) }
        return (volume, playback, box)
    }

    final class Box { var changes: [(VolumeLevel, Bool)] = [] }

    @Test func aDisplayThatAnswersGetsItsOwnVolume() async {
        defer { TestDefaults.remove(suite) }
        let ddc = FakeDisplay(volume: 75)
        let (volume, playback, box) = make(ddc)
        volume.update(display, systemControls: false)
        volume.perform(.step(6), showHUD: true)
        #expect(await eventually { box.changes.count == 1 })
        #expect(box.changes.last?.0 == VolumeLevel(level: 81, muted: false))
        #expect(box.changes.last?.1 == true)   // 按音量键来的：出音量条
        #expect(playback.output == nil)   // 显示器自己调了，Mac TV 的声音原样放
        #expect(playback.gain == 1)
        #expect(volume.volume == VolumeLevel(level: 81, muted: false))

        volume.perform(.refresh, showHUD: false)   // 打开音量面板：不出音量条
        #expect(box.changes.last?.1 == false)
    }

    @Test func aDisplayThatDoesntAnswerFallsBackToMacTVsOwnLevel() async {
        defer { TestDefaults.remove(suite) }
        let (volume, playback, box) = make(nil)
        volume.update(tv, systemControls: false)
        #expect(playback.gain == 1)   // 还没按过：原样放

        volume.perform(.step(-6), showHUD: true)
        #expect(await eventually { box.changes.count == 1 })
        #expect(box.changes.last?.0 == VolumeLevel(level: 94, muted: false))
        #expect(playback.output == "EDID-2")
        #expect(abs(playback.gain - PlaybackVolume.gain(for: 94)) < 0.0001)

        volume.perform(.step(-6), showHUD: true)   // 不再等显示器
        #expect(box.changes.last?.0 == VolumeLevel(level: 88, muted: false))
        volume.perform(.toggleMute, showHUD: true)
        #expect(playback.gain == 0)

        // 换到内建扬声器（系统能调）：Mac TV 的声音回到原样
        volume.update(AudioOutputDevice(id: 1, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn,
                                        isDefault: true, uid: "BuiltInSpeakerDevice"), systemControls: true)
        #expect(playback.gain == 1)

        // 下次开 Mac TV、还是这台电视：先照记着的 88 放（静音不记）
        let (again, playbackAgain, _) = make(nil, playback: PlaybackVolume(defaults: defaults))
        again.update(tv, systemControls: false)
        #expect(playbackAgain.output == "EDID-2")
        #expect(playbackAgain.volume == VolumeLevel(level: 88, muted: false))
    }

    @Test func aFixedVolumeOutputThatIsntADisplayUsesMacTVsLevelRightAway() {
        defer { TestDefaults.remove(suite) }
        let (volume, playback, box) = make(FakeDisplay())
        let dac = AudioOutputDevice(id: 5, name: "USB DAC", transport: kAudioDeviceTransportTypeUSB, isDefault: true, uid: "DAC")
        volume.update(dac, systemControls: false)
        volume.perform(.step(-12), showHUD: true)
        #expect(box.changes.last?.0 == VolumeLevel(level: 88, muted: false))
        #expect(playback.output == "DAC")
    }

    @Test func whenAnotherAppIsPlayingTheHUDSaysItCantBeSet() async {
        defer { TestDefaults.remove(suite) }
        let (volume, playback, box) = make(nil)
        volume.reachesPlayback = { false }
        volume.update(tv, systemControls: false)
        volume.perform(.step(6), showHUD: true)
        #expect(await eventually { box.changes.count == 1 })
        #expect(box.changes.last?.0 == VolumeLevel(level: nil, muted: false))
        #expect(playback.level == 100)   // 没动 Mac TV 自己的音量
    }

    @Test func aDisplayThatStopsAnsweringIsLookedUpAgain() async {
        defer { TestDefaults.remove(suite) }
        let first = FakeDisplay(volume: 40)
        let second = FakeDisplay(volume: 60)
        let (volume, _, box) = make(nil)
        var lookups = 0
        volume.findDisplay = { _ in lookups += 1; return lookups == 1 ? first : second }
        volume.update(display, systemControls: false)
        volume.perform(.step(6), showHUD: true)
        #expect(await eventually { box.changes.count == 1 })
        #expect(box.changes.last?.0.level == 46)

        // 显示器睡醒、重新插过：旧的 IOAVService 不回话了，换一个新的
        await first.setAnswers(false)
        volume.display?.burstGap = .zero
        await volume.display?.finishWriting()
        volume.perform(.step(6), showHUD: true)
        #expect(await eventually { box.changes.count == 2 })
        #expect(box.changes.last?.0.level == 66)
        #expect(lookups == 2)
    }

    @Test func eachOutputIsDecidedOnceAndStaysDecided() async {
        defer { TestDefaults.remove(suite) }
        let ddc = FakeDisplay(volume: 75)
        let (volume, playback, box) = make(nil)
        var lookups: [String] = []
        volume.findDisplay = { output in lookups.append(output.uid); return output.uid == "EDID-1" ? ddc : nil }

        // 换到显示器：还不知道（不是"不可用"），马上去问，不等第一次按键
        volume.update(display, systemControls: false)
        #expect(volume.deciding)
        volume.perform(.refresh, showHUD: false)
        #expect(await eventually { box.changes.count == 1 })
        #expect(!volume.deciding)
        #expect(box.changes.last?.0 == VolumeLevel(level: 75, muted: false))
        #expect(box.changes.last?.1 == false)   // 问的时候不出音量条

        // 换到不回话的电视：定下来是 Mac TV 自己的音量
        volume.update(tv, systemControls: false)
        #expect(volume.deciding)
        volume.perform(.refresh, showHUD: false)
        #expect(await eventually { box.changes.count == 2 })
        #expect(!volume.deciding)
        #expect(box.changes.last?.0 == VolumeLevel(level: 100, muted: false))
        #expect(playback.output == "EDID-2")

        // 来回换：一换过来就是定下来的样子，不再问
        volume.update(display, systemControls: false)
        #expect(!volume.deciding)
        #expect(volume.volume == VolumeLevel(level: 75, muted: false))
        #expect(playback.output == nil)
        volume.update(tv, systemControls: false)
        #expect(!volume.deciding)
        #expect(volume.volume == VolumeLevel(level: 100, muted: false))
        #expect(lookups == ["EDID-1", "EDID-2"])

        // 电视拔了再插上：重新问
        volume.keep(["EDID-1"])
        #expect(volume.deciding)
        volume.perform(.refresh, showHUD: false)
        #expect(await eventually { lookups.count == 3 && !volume.deciding })
    }

    @Test func pressesWhileDecidingWaitForTheAnswer() async {
        defer { TestDefaults.remove(suite) }
        let (volume, _, box) = make(FakeDisplay(volume: 40, delay: .milliseconds(20)))
        volume.update(display, systemControls: false)
        volume.perform(.refresh, showHUD: false)
        volume.perform(.step(6), showHUD: false)
        volume.perform(.step(6), showHUD: false)
        #expect(volume.deciding)
        #expect(await eventually { box.changes.last?.0 == VolumeLevel(level: 52, muted: false) })
        #expect(!volume.deciding)
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct PlaybackVolumeTests {
    @Test func playersFollowTheAppLevelOnlyOnFixedOutputs() {
        let suite = "MacTVTests.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }
        let volume = PlaybackVolume(defaults: defaults)
        let movie = AVPlayer()
        let music = AVPlayer()
        volume.set(movie, base: 1)
        volume.set(music, base: 0.5)   // 网易云的平衡音量
        #expect(movie.volume == 1 && music.volume == 0.5)

        volume.perform(.step(-50))   // 系统能调音量时不归它管
        #expect(volume.level == 100)

        volume.use("TV")
        volume.perform(.set(50))
        #expect(abs(movie.volume - 0.125) < 0.0001)
        #expect(abs(music.volume - 0.0625) < 0.0001)
        volume.set(music, base: 1)   // 平衡音量关了
        #expect(abs(music.volume - 0.125) < 0.0001)

        volume.perform(.toggleMute)
        #expect(movie.volume == 0)
        volume.perform(.step(6))   // 调大取消静音
        #expect(volume.volume == VolumeLevel(level: 56, muted: false))

        volume.use(nil)
        #expect(movie.volume == 1 && music.volume == 1)
        volume.useIfRemembered("TV")
        #expect(volume.level == 56)
        volume.forget("TV")
        #expect(volume.output == nil)
        volume.useIfRemembered("TV")
        #expect(volume.output == nil)

        #expect(PlaybackVolume.gain(for: 100) == 1)
        #expect(PlaybackVolume.gain(for: 0) == 0)
    }

    /// 按键音也是 Mac TV 自己的声音：只有 Mac TV 自己的音量管得着的输出上，音量面板调音量听得出大小
    @Test func interfaceSoundsFollowTheAppLevelToo() {
        let suite = "MacTVTests.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }
        let volume = PlaybackVolume(defaults: defaults)
        let tick = AVAudioPlayerNode()
        volume.attach(tick)
        #expect(tick.volume == 1)
        volume.use("TV")
        volume.perform(.set(50))
        #expect(abs(tick.volume - 0.125) < 0.0001)
        volume.perform(.toggleMute)
        #expect(tick.volume == 0)
        volume.use(nil)
        #expect(tick.volume == 1)
    }

    /// 脚本的行为在 Tests/WebPlayback/volume.test.cjs 里跑（node）
    @Test func theWebScriptAsksForTheCurrentLevel() {
        #expect(PlaybackVolume.script.contains("__MACTV_GAIN__"))
        #expect(PlaybackVolume.script.contains("messageHandlers.\(PlaybackVolume.handlerName)"))
    }
}

/// 在这台 Mac 上真的问显示器（只读）：MACTV_LIVE_DDC_TEST=1 才跑。声音输出不改。
/// 再加 MACTV_LIVE_DDC_WRITE=1：把刚读到的音量原样写回去（听不出变化），再读一次核对
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACTV_LIVE_DDC_TEST"] == "1"), .timeLimit(.minutes(1))) @MainActor
struct DisplayVolumeLiveTests {
    @Test func theConnectedDisplayAnswersDDC() async throws {
        let coordinator = AudioCoordinator()
        let outputs = coordinator.devices.filter(DisplayAudioLink.isDisplayAudio)
        try #require(!outputs.isEmpty, "No display audio output")
        for output in outputs {
            let ddc = try #require(await DisplayAudioLink.find(output), "No DDC for \(output.name)")
            let volume = try #require(await ddc.read(VCP.volume), "\(output.name) didn't answer VCP 0x62")
            let mute = await ddc.read(VCP.mute)
            print("\(output.name): volume \(volume.current) of \(volume.max), mute \(mute.map { "\($0.current) of \($0.max)" } ?? "unsupported")")
            #expect(volume.max > 0)
            if ProcessInfo.processInfo.environment["MACTV_LIVE_DDC_WRITE"] == "1" {
                #expect(await ddc.write(VCP.volume, value: volume.current))
                let after = await ddc.read(VCP.volume)
                print("\(output.name): wrote \(volume.current) back, reads \(after.map { "\($0.current)" } ?? "nothing")")
                #expect(after == volume)
            }
        }
    }
}

/// 网页脚本在真的 WebKit 里：MACTV_LIVE_WEBKIT_TEST=1 才跑（要 WebKit，构建机上可能没有）
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACTV_LIVE_WEBKIT_TEST"] == "1"), .timeLimit(.minutes(1))) @MainActor
struct WebVolumeLiveTests {
    @Test func webMediaPlaysAtMacTVsLevelInEveryFrame() async throws {
        _ = NSApplication.shared
        let suite = "MacTVTests.\(UUID().uuidString)"
        let defaults = TestDefaults.named(suite)
        defer { TestDefaults.remove(suite) }
        let volume = PlaybackVolume(defaults: defaults)
        volume.use("TV")
        volume.perform(.set(50))   // 0.125

        // 先记下 WebKit 自己的 volume，好看实际放多大
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: "window.__native = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');",
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        volume.install(in: web)
        web.loadHTMLString("<video id=v></video><iframe srcdoc='<video id=c></video>'></iframe>", baseURL: URL(string: "https://example.com/"))
        #expect(await eventually { (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!frames[0].__macTVVolume") as? Bool) == true })

        func number(_ script: String) async -> Double? { try? await web.evaluateJavaScript(script) as? Double }
        let real = "__native.get.call(document.getElementById('v'))"
        let childReal = "frames[0].__native.get.call(frames[0].document.getElementById('c'))"
        _ = try await web.evaluateJavaScript("document.getElementById('v').volume = 0.8; frames[0].document.getElementById('c').volume = 1; 0")
        #expect(await number("document.getElementById('v').volume") == 0.8)   // 网页看到的还是它设的
        #expect(await number(real).map { abs($0 - 0.1) < 0.001 } == true)
        #expect(await number(childReal).map { abs($0 - 0.125) < 0.001 } == true)

        volume.perform(.set(100))   // 推给主框架，再传给子框架
        #expect(await eventually { await number(real).map { abs($0 - 0.8) < 0.001 } == true })
        #expect(await eventually { await number(childReal).map { abs($0 - 1) < 0.001 } == true })
    }
}

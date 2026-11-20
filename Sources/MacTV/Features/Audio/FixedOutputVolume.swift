import Foundation

/// 系统调不了音量的输出（显示器、电视的 HDMI / DisplayPort 声音，固定音量的声卡…）上，音量键调什么：
/// 1. 显示器自己的音量，经 DDC（显示器回话时，见 DisplayVolumeController）；
/// 2. 不然是 Mac TV 自己放的声音（见 PlaybackVolume）；
/// 3. 正在放的是别的应用、Brave 时这两样都够不着，音量条上说调不了。
/// 系统能调的输出不经这里（AudioCoordinator 照旧用 CoreAudio）
@MainActor
final class FixedOutputVolume {
    /// 找这个输出所在显示器的 DDC。测试换成假的，不碰硬件
    var findDisplay: (AudioOutputDevice) async -> (any DisplayDDC)? = { await DisplayAudioLink.find($0) }
    /// Mac TV 自己放的声音是不是正在听的（别的应用在前面、在 Brave 里放时不是）
    var reachesPlayback: () -> Bool = { true }
    /// 新的音量；showHUD = 是按音量键来的，要出音量条
    var onChange: (VolumeLevel, _ showHUD: Bool) -> Void = { _, _ in }
    let playback: PlaybackVolume
    private let writeInterval: Duration

    /// 现在的输出（系统调不了它的音量时）
    private(set) var device: AudioOutputDevice?
    /// 它的显示器，回过 DDC 之后
    private(set) var display: DisplayVolumeController?
    private var finding = false
    private var waiting: [VolumeAction] = []
    /// 这次开着 Mac TV 时显示器不回 DDC 的输出：直接用 Mac TV 自己的音量，不再等显示器
    private var silent: Set<String> = []
    private var hudPending = false

    init(playback: PlaybackVolume = .shared, writeInterval: Duration = .milliseconds(60)) {
        self.playback = playback
        self.writeInterval = writeInterval
    }

    /// 输出变了、刷新了。systemControls = 系统自己能调它的音量（那就不归这里管，Mac TV 的声音原样放）
    func update(_ device: AudioOutputDevice?, systemControls: Bool) {
        let current = systemControls ? nil : device
        if current?.uid != self.device?.uid {
            if let old = self.device { silent.remove(old.uid) }   // 换回来时再问一次显示器
            display = nil
            waiting = []
        }
        self.device = current
        guard let current else { playback.use(nil); return }
        if display?.answered == true {
            playback.use(nil)
        } else if silent.contains(current.uid) || !DisplayAudioLink.isDisplayAudio(current) {
            playback.use(current.uid)
        } else {
            playback.useIfRemembered(current.uid)   // 还不知道显示器回不回话：上次用的是什么就先用什么
        }
    }

    /// 现在知道的音量（不碰硬件）
    var volume: VolumeLevel {
        if let model = display?.model { return model.volume }
        if playback.output != nil, playback.output == device?.uid { return playback.volume }
        return VolumeLevel(level: nil, muted: false)
    }

    func perform(_ action: VolumeAction, showHUD: Bool) {
        if showHUD { hudPending = true }
        guard let device else { emit(VolumeLevel(level: nil, muted: false)); return }
        if let display { display.perform(action); return }
        if finding { waiting.append(action); return }
        if DisplayAudioLink.isDisplayAudio(device), !silent.contains(device.uid) {
            waiting.append(action)
            find(device)
            return
        }
        own(action)
    }

    private func find(_ device: AudioOutputDevice) {
        finding = true
        Task { [weak self] in
            guard let self else { return }
            let ddc = await findDisplay(device)
            finding = false
            let actions = waiting
            waiting = []
            guard device.uid == self.device?.uid else {   // 找的时候输出换了：这时按的归新的输出
                for action in actions { perform(action, showHUD: false) }
                return
            }
            guard let ddc else { giveUp(device, actions); return }
            let controller = DisplayVolumeController(ddc: ddc, writeInterval: writeInterval)
            controller.onLevel = { [weak self, weak controller] level in
                guard let self, let controller, controller === display else { return }
                playback.forget(device.uid)
                playback.use(nil)
                emit(level)
            }
            controller.onUnavailable = { [weak self, weak controller] actions in
                guard let self, let controller, controller === display else { return }
                display = nil
                // 回过话的显示器不回了：多半是睡醒、重新插过，换一个新的 IOAVService 再试一次
                // （新的一次也不回话就算了，不会一直试下去）
                if controller.answered {
                    waiting = actions
                    find(device)
                } else {
                    giveUp(device, actions)
                }
            }
            display = controller
            for action in actions { controller.perform(action) }
        }
    }

    private func giveUp(_ device: AudioOutputDevice, _ actions: [VolumeAction]) {
        Log.audio.notice("The display doesn't answer DDC; Mac TV sets the volume of what it plays")
        silent.insert(device.uid)
        if actions.isEmpty { return }
        for action in actions { own(action, emitting: false) }
        emit(ownVolume)
    }

    /// Mac TV 自己放的声音
    private func own(_ action: VolumeAction, emitting: Bool = true) {
        guard let device else { return }
        playback.use(device.uid)
        if reachesPlayback() { playback.perform(action) }
        if emitting { emit(ownVolume) }
    }

    private var ownVolume: VolumeLevel {
        reachesPlayback() ? playback.volume : VolumeLevel(level: nil, muted: false)
    }

    private func emit(_ level: VolumeLevel) {
        let show = hudPending
        hudPending = false
        onChange(level, show)
    }
}

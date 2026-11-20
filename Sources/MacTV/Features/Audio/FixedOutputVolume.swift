import Foundation

/// 系统调不了音量的输出（显示器、电视的 HDMI / DisplayPort 声音，固定音量的声卡…）上，音量键调什么：
/// 1. 显示器自己的音量，经 DDC（显示器回话时，见 DisplayVolumeController）；
/// 2. 不然是 Mac TV 自己放的声音（见 PlaybackVolume）；
/// 3. 正在放的是别的应用、Brave 时这两样都够不着，音量条上说调不了。
/// 归哪一样调，每个输出这次开着 Mac TV 时只定一次：换到它、打开音量面板时就去问显示器（不等第一次按键），
/// 换走再换回来不重新问，输出没了（显示器拔了、睡了）才忘掉。问的这一小会儿是"还不知道"（deciding），不是"调不了"。
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
    /// 找到的显示器，按输出（CoreAudio 的 UID）记着
    private var displays: [String: DisplayVolumeController] = [:]
    /// 显示器不回 DDC 的输出：用 Mac TV 自己的音量
    private var silent: Set<String> = []
    /// 正在 IORegistry 里找显示器的输出
    private var finding: Set<String> = []
    /// 现在的输出还没定下来时按的
    private var waiting: [VolumeAction] = []
    private var hudPending = false

    init(playback: PlaybackVolume = .shared, writeInterval: Duration = .milliseconds(60)) {
        self.playback = playback
        self.writeInterval = writeInterval
    }

    /// 现在这个输出的显示器（找到了的）
    var display: DisplayVolumeController? { device.flatMap { displays[$0.uid] } }

    /// 还不知道现在这个输出归谁调：显示器的声音，显示器还没回过话、也还没定下来不回
    var deciding: Bool {
        guard let device, DisplayAudioLink.isDisplayAudio(device), !silent.contains(device.uid) else { return false }
        return display?.answered != true
    }

    /// 输出变了、刷新了。systemControls = 系统自己能调它的音量（那就不归这里管，Mac TV 的声音原样放）
    func update(_ device: AudioOutputDevice?, systemControls: Bool) {
        let current = systemControls ? nil : device
        if current?.uid != self.device?.uid { waiting = [] }   // 还没定下来时按的归原来那个输出，不带过来
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

    /// 还在的输出（CoreAudio 列出来的 UID）：没了的，定下来的不算了，再接上时重新问
    func keep(_ outputs: Set<String>) {
        silent.formIntersection(outputs)
        displays = displays.filter { outputs.contains($0.key) }
    }

    /// 现在知道的音量（不碰硬件）
    var volume: VolumeLevel {
        if let model = display?.model { return model.volume }
        if playback.output != nil, playback.output == device?.uid { return ownVolume }
        return VolumeLevel(level: nil, muted: false)
    }

    func perform(_ action: VolumeAction, showHUD: Bool) {
        if showHUD { hudPending = true }
        guard let device else { emit(VolumeLevel(level: nil, muted: false)); return }
        if let display { display.perform(action); return }
        if finding.contains(device.uid) { waiting.append(action); return }
        if DisplayAudioLink.isDisplayAudio(device), !silent.contains(device.uid) {
            waiting.append(action)
            find(device)
            return
        }
        own(action)
    }

    private func find(_ device: AudioOutputDevice) {
        finding.insert(device.uid)
        Task { [weak self] in
            guard let self else { return }
            let ddc = await findDisplay(device)
            finding.remove(device.uid)
            // 找的时候换了输出：找到的照样记着，按键已经归新的输出了
            let current = device.uid == self.device?.uid
            let actions = current ? waiting : []
            if current { waiting = [] }
            guard let ddc else { giveUp(device, actions); return }
            let controller = DisplayVolumeController(ddc: ddc, writeInterval: writeInterval)
            controller.onLevel = { [weak self, weak controller] level in
                guard let self, let controller, controller === displays[device.uid] else { return }
                playback.forget(device.uid)
                guard device.uid == self.device?.uid else { return }
                playback.use(nil)
                emit(level)
            }
            controller.onUnavailable = { [weak self, weak controller] actions in
                guard let self, let controller, controller === displays[device.uid] else { return }
                displays[device.uid] = nil
                guard device.uid == self.device?.uid else { return }   // 不在用它：下次换回来再找
                // 回过话的显示器不回了：多半是睡醒、重新插过，换一个新的 IOAVService 再试一次
                // （新的一次也不回话就算了，不会一直试下去）
                if controller.answered {
                    waiting = actions
                    find(device)
                } else {
                    giveUp(device, actions)
                }
            }
            displays[device.uid] = controller
            // 先读一次：显示器回了话才算定下来，不回就交给 Mac TV 自己的音量
            controller.perform(.refresh)
            for action in actions { controller.perform(action) }
        }
    }

    private func giveUp(_ device: AudioOutputDevice, _ actions: [VolumeAction]) {
        Log.audio.notice("The display doesn't answer DDC; Mac TV sets the volume of what it plays")
        silent.insert(device.uid)
        guard device.uid == self.device?.uid else { return }
        playback.use(device.uid)
        if reachesPlayback() { for action in actions { playback.perform(action) } }
        emit(ownVolume)
    }

    /// Mac TV 自己放的声音
    private func own(_ action: VolumeAction) {
        guard let device else { return }
        playback.use(device.uid)
        if reachesPlayback() { playback.perform(action) }
        emit(ownVolume)
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

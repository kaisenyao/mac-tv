import Foundation

/// The screen saver after a few idle minutes on the home screen, and the sleep timer.
@MainActor
final class IdleCoordinator: ObservableObject {
    weak var tv: TVController?

    /// Shown after a few idle minutes on the home screen; what each input does over it is handleScreensaver's.
    @Published private(set) var screensaver = false
    /// When the sleep timer goes off, while it's set.
    @Published private(set) var sleepAt: Date?
    /// Aerials and My Photos: the picture showing (an index into ScreenSaverSettings.playing), and whether its
    /// place or date shows over it (a tap, as on Apple TV).
    @Published private(set) var picture = 0
    @Published private(set) var info = false

    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var sleepTimer: Timer?

    init() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    /// Any input: the screen saver's wait starts again.
    func noteInput() { lastActivity = Date() }

    /// The pointer or the trackpad moved or clicked: it ends the screen saver too. True when that's all it did.
    @discardableResult
    func noteActivity() -> Bool {
        lastActivity = Date()
        guard screensaver else { return false }
        screensaver = false
        return true
    }

    private func checkIdle() {
        guard let tv, tv.mode == .launcher, !tv.playbackCoordinator.isAnyPlaybackActive, !tv.displaysSleeping,
              tv.activeSheet == nil, tv.movies == nil, !tv.bilibiliStore.player.blocksScreensaver, !screensaver,
              Date().timeIntervalSince(lastActivity) > TimeInterval(ScreenSaverSettings.delayMinutes * 60) else { return }
        showScreensaver()
    }

    func showScreensaver() {
        guard tv?.displaysSleeping != true else { return }
        ScreenSaverSettings.playing = ScreenSaverSettings.pictures(for: ScreenSaverSettings.wallpaper)
        picture = 0
        info = false
        lastActivity = Date()
        screensaver = true
    }

    func hideScreensaver() { screensaver = false }

    /// The next (1) or previous (-1) picture: someone swiped, or the film or slide came to its end.
    func stepPicture(_ by: Int) {
        let count = ScreenSaverSettings.playing.count
        guard count > 1 else { return }
        picture = ((picture + by) % count + count) % count
    }

    func toggleInfo() { info.toggle() }

    /// TV standby after `minutes` (everything pauses; what's in front stays); 0 cancels.
    func setSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        guard minutes > 0 else {
            sleepAt = nil
            return
        }
        sleepAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleepAt = nil
                self.tv?.enterStandby(reason: "the sleep timer")
            }
        }
    }
}

// MARK: The screen saver's own buttons

extension TVController {
    /// The screen saver takes every input (route layer 2), by type, only where Apple's equivalent has it
    /// (docs/custom/interaction-spec.md, 5.8):
    /// - Aerials and My Photos: Left / Right (a press, a swipe, the ring) go to the previous or next film or photo;
    ///   a tap on the clickpad or the phone's touch area shows its place or date (Aerials' place, a photo's date).
    /// - Drifting Color and Flip Clock: nothing but leaving.
    /// - Select leaves (Apple). Back, TV and the rest leave too (Mac TV decision); holding TV leaves for Control
    ///   Center. The press that leaves does nothing else. Volume and Mute work without leaving.
    func handleScreensaver(_ command: RemoteCommand, from source: Feedback.Source) {
        let browsable = [.aerials, .photos].contains(ScreenSaverSettings.wallpaper) && !ScreenSaverSettings.playing.isEmpty
        switch command {
        case .volume(let delta): audioCoordinator.pressVolume(by: delta)
        case .mute: audioCoordinator.pressMute()
        case .move(.left) where browsable: idleCoordinator.stepPicture(-1)
        case .move(.right) where browsable: idleCoordinator.stepPicture(1)
        case .wheel(let step) where browsable: idleCoordinator.stepPicture(step > 0 ? 1 : -1)
        case .touchTap where browsable, .click where browsable: idleCoordinator.toggleInfo()
        case .swipe(let dx, let dy, let phase, _):
            switch phase {
            case "began": saverSwipe = (0, 0)
            case "changed": saverSwipe.dx += dx; saverSwipe.dy += dy
            case "ended":
                let (x, y) = saverSwipe
                saverSwipe = (0, 0)
                if browsable, abs(x) > 60, abs(x) > abs(y) { idleCoordinator.stepPicture(x > 0 ? 1 : -1) } else if abs(x) + abs(y) > 60 { screensaverOff() }
            default: break   // the glide after a swipe
            }
        case .controlCenter:
            screensaverOff()
            holdTV()
        case .sleepTimer(let minutes): setSleepTimer(minutes: minutes)   // set from the phone: not a press
        case .pointer, .scroll, .pointerHold, .text, .deleteBackward, .setting, .shortcut:
            break   // the phone's pointer and typing, its settings: not presses on the screen saver
        default:
            screensaverOff()
        }
    }
}

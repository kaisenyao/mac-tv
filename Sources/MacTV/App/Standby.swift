import AppKit

// TV standby: the one way Mac TV goes dark, as Apple TV sleeps, without sleeping the Mac (the Mac mini runs other
// services, and the remotes have to reach it). Holding Power, Control Center's Sleep Now and Turn Off Display, the
// sleep timer and the phone's power button come here. Power, Back, TV and Select wake it, and that press does nothing
// else; in standby nothing else does anything (see TVController.handle).
//
// macOS turning the display off on its own timer isn't standby: nothing pauses (music keeps playing), and a press
// wakes the display and does what it does, as before (macDisplaySlept / macDisplayWoke).

extension TVController {
    /// TV standby: every player in Mac TV pauses (music and audio books too), the screen saver goes, Mac TV stops
    /// keeping the display awake, and the display turns off (`pmset displaysleepnow`, which needs no root). What's
    /// in front stays as it is, so waking comes back to it, paused. The Mac stays awake.
    func enterStandby(reason: String) {
        let already = standby
        pauseEverything()
        screensaverOff()
        displayCoordinator.releasePlaybackKeepAwake()
        guard !already else { return }
        Log.app.notice("TV standby: \(reason, privacy: .public)")
        standby = true
        displayCoordinator.noteDisplaySleep(true)
        SystemControl.displayOff()
    }

    /// Power, Back, TV or Select in standby: the display wakes on what was underneath, still paused.
    func wakeFromStandby() {
        Log.app.notice("Woke from TV standby")
        standby = false
        displayCoordinator.noteDisplaySleep(false)
        if bilibiliOpen { bilibiliStore.player.returnFromBackground() }
        playbackCoordinator.returnFromStandby()
        wakeDisplays()
    }

    /// macOS turned the display off on its own (its timer): not standby. The screen saver goes; what plays plays on.
    func macDisplaySlept() {
        displayCoordinator.noteDisplaySleep(true)
    }

    /// The display came back on. After macOS's own sleep nothing else changes; from standby (a key or the mouse
    /// woke it) it's the same as waking with a remote.
    func macDisplayWoke() {
        if standby { wakeFromStandby() } else { displayCoordinator.noteDisplaySleep(false) }
    }

    /// Everything in Mac TV that plays: 哔哩哔哩, 网易云音乐, 得到, the web page in front (the ones in the background
    /// are paused already), Movies and IINA.
    private func pauseEverything() {
        bilibiliStore.player.pauseForBackground()   // nothing starts by itself while the TV is off
        neteaseStore.pauseIfPlaying()
        dedaoStore.player.pause()
        playbackCoordinator.pauseAll()
    }
}

extension RemoteCommand {
    /// The buttons that wake Mac TV from TV standby: Power, Back, TV and Select, pressed or held (Apple lists TV,
    /// Back and Power; Select is a Mac TV decision, the button a hand finds first on the phone).
    var wakesFromStandby: Bool {
        switch self {
        case .power, .back, .goHome, .home, .controlCenter, .select, .longSelect: true
        default: false
        }
    }

    /// Turns the TV off: it isn't someone using the Mac (so it doesn't tell macOS so, which would wake the display).
    var entersStandby: Bool {
        switch self {
        case .power(hold: true), .sleepNow: true
        default: false
        }
    }
}

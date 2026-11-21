import AVFoundation
import Foundation

/// A player Jasmine can ask things of. Each of Mac TV's own (哔哩哔哩, 网易云音乐, 得到, Videos) answers with the
/// functions its remote already uses, and says why when it can't: a song has no subtitles, a live stream can't skip.
///
/// | | 哔哩哔哩 | 网易云音乐 | 得到 | Videos | A web page, YouTube, IINA, Brave |
/// |---|---|---|---|---|---|
/// | Play, pause | Yes | Yes | Yes | Yes | Yes |
/// | Next, previous | An episode of a series | A song | A lecture | The next episode only | No |
/// | Skip, seek, start over | Yes (not live) | Yes | Yes | Yes | Skip 10 s only |
/// | Subtitles | When the video has them | No | No | When the video has them | No |
/// | Speed | 0.5–2 (not live) | No | 0.75–2 | No | No |
@MainActor
protocol JasminePlayer: AnyObject {
    /// What's playing, for the model: the app, the title, paused or not.
    var jasmineState: [String: Any] { get }
    var jasminePaused: Bool { get }
    func jasmineTogglePause()
    /// Next, previous, skip, seek, subtitles or speed. Why not, when it can't.
    func jasmine(_ request: JasmineCommand.Playback) -> JasmineFailure?
}

extension TVController {
    enum JasminePlaying {
        case player(any JasminePlayer)
        /// A web page, IINA or Brave, by its name: Mac TV only sends it Play/Pause and a 10-second step.
        case keys(String)
    }

    /// What her playback commands go to: the video or page in front, or else the music or the book, which may be
    /// playing behind Home.
    var jasminePlaying: JasminePlaying? {
        if playbackCoordinator.iinaOpen { return .keys("IINA") }
        if externalBrowser != nil { return .keys("Brave") }
        switch mode {
        case .movie: return moviePlayer.map { .player($0) }
        case .player(let service): return .keys(service.name)
        case .launcher: break
        }
        if bilibiliOpen, bilibiliStore.player.current != nil { return .player(bilibiliStore.player) }
        if neteaseStore.current != nil { return .player(neteaseStore) }
        if dedaoStore.player.current != nil { return .player(dedaoStore) }
        return nil
    }

    func perform(_ request: JasmineCommand.Playback) -> JasmineFailure? {
        switch jasminePlaying {
        case nil:
            return .nothingPlaying
        case .player(let player):
            switch request {
            case .play: if player.jasminePaused { player.jasmineTogglePause() }
            case .pause: if !player.jasminePaused { player.jasmineTogglePause() }
            default: return player.jasmine(request)
            }
        case .keys(let name):
            // Paused or not isn't known: Play and Pause are the same key
            switch request {
            case .play, .pause: handle(.playPause, from: .siriRemote)
            case .skip(10): handle(.seek(forward: true), from: .siriRemote)
            case .skip(-10): handle(.seek(forward: false), from: .siriRemote)
            case .skip: return .unavailable("\(name) only skips 10 seconds at a time")
            case .next, .previous, .seek, .subtitles, .speed: return .unavailable("\(name) only takes play, pause and a 10-second skip")
            }
        }
        return nil
    }
}

/// 0.5, 0.75, 1, 1.25: the speeds a player has, for the model.
private func listed(_ values: [Double]) -> String {
    values.sorted().map { $0.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))) }
        .joined(separator: ", ")
}

extension BilibiliNativePlayer: JasminePlayer {
    var jasmineState: [String: Any] { ["app": "哔哩哔哩", "title": current?.title ?? "", "paused": paused] }
    var jasminePaused: Bool { paused }
    func jasmineTogglePause() { _ = handle(.playPause) }

    func jasmine(_ request: JasmineCommand.Playback) -> JasmineFailure? {
        switch request {
        case .play, .pause:
            break
        case .next, .previous:
            guard let index = episodeIndex else { return .unavailable("this video isn't part of a series") }
            let target = index + (request == .next ? 1 : -1)
            guard episodes.indices.contains(target) else {
                return .unavailable(request == .next ? "this is the last episode" : "this is the first episode")
            }
            playEpisode(target)
        case .skip(let seconds):
            if let failure = cantSeek { return failure }
            scrub(by: Double(seconds))
        case .seek(let position):
            if let failure = cantSeek { return failure }
            scrub(by: Double(position) - time)
        case .subtitles(let on):
            guard !isLive else { return .unavailable("a live stream has no subtitles") }
            guard !subtitleTracks.isEmpty else { return .unavailable("this video has no subtitles") }
            if !on {
                choose(in: .subtitles, 0)
            } else if subtitleTrack == nil, let track = Self.preferredTrack(subtitleTracks), let index = subtitleTracks.firstIndex(of: track) {
                choose(in: .subtitles, index + 1)
            }
        case .speed(let value):
            guard !isLive else { return .unavailable("a live stream has no playback speed") }
            guard let index = Self.speeds.firstIndex(of: value) else {
                return .unavailable("哔哩哔哩 plays at these speeds: \(listed(Self.speeds))")
            }
            choose(in: .speed, index)
        }
        return nil
    }

    private var cantSeek: JasmineFailure? {
        if isLive { return .unavailable("a live stream can't skip") }
        if player.currentItem?.status != .readyToPlay { return .unavailable("the video is still loading") }
        return nil
    }
}

extension NeteaseStore: JasminePlayer {
    var jasmineState: [String: Any] {
        ["app": "网易云音乐", "title": current?.name ?? "", "artist": current?.artist ?? "", "paused": paused]
    }
    var jasminePaused: Bool { paused }
    func jasmineTogglePause() { tapPlayPause() }

    func jasmine(_ request: JasmineCommand.Playback) -> JasmineFailure? {
        switch request {
        case .play, .pause:
            break
        case .next, .previous:
            guard !queue.isEmpty else { return .unavailable("there's no other song in the queue") }
            skip(request == .next ? 1 : -1)
        case .skip(let seconds):
            guard duration > 0 else { return .unavailable("the song is still loading") }
            nudge(Double(seconds))
        case .seek(let position):
            guard duration > 0 else { return .unavailable("the song is still loading") }
            seek(toTime: Double(position))
        case .subtitles:
            return .unavailable("网易云音乐 has no subtitles")
        case .speed:
            return .unavailable("网易云音乐 has no playback speed")
        }
        return nil
    }
}

extension DedaoStore: JasminePlayer {
    var jasmineState: [String: Any] {
        ["app": "得到", "title": player.current?.title ?? "", "reader": player.current?.reader ?? "", "paused": player.paused]
    }
    var jasminePaused: Bool { player.paused }
    func jasmineTogglePause() { player.togglePause() }

    func jasmine(_ request: JasmineCommand.Playback) -> JasmineFailure? {
        switch request {
        case .play, .pause:
            break
        case .next:
            guard stepLecture(1) else { return .unavailable("this is the last lecture") }
        case .previous:
            guard stepLecture(-1) else { return .unavailable("this is the first lecture") }
        case .skip(let seconds):
            guard player.duration > 0 else { return .unavailable("the lecture is still loading") }
            player.skip(Double(seconds))
        case .seek(let position):
            guard player.duration > 0 else { return .unavailable("the lecture is still loading") }
            player.seek(to: Double(position))
        case .subtitles:
            return .unavailable("得到 has no subtitles")
        case .speed(let value):
            guard let speed = DedaoPlayer.speeds.first(where: { Double($0) == value }) else {
                return .unavailable("得到 plays at these speeds: \(listed(DedaoPlayer.speeds.map(Double.init)))")
            }
            setSpeed(speed)
        }
        return nil
    }
}

extension MoviePlayer: JasminePlayer {
    var jasmineState: [String: Any] { ["app": "Videos", "title": movie.title, "paused": !playing] }
    var jasminePaused: Bool { !playing }
    func jasmineTogglePause() { togglePlayback() }

    func jasmine(_ request: JasmineCommand.Playback) -> JasmineFailure? {
        switch request {
        case .play, .pause:
            break
        case .next:
            guard onNext?() == true else { return .unavailable("there's no next episode") }
        case .previous:
            return .unavailable("Videos can't go back an episode")
        case .skip(let seconds):
            skip(Double(seconds))
        case .seek(let position):
            guard duration > 0 else { return .unavailable("the video is still loading") }
            seek(toFraction: Double(position) / duration)
        case .subtitles(let on):
            guard !subtitleOptions.isEmpty else { return .unavailable("this video has no subtitles") }
            if !on {
                selectSubtitle(nil)
            } else if selectedSubtitle == nil {
                selectSubtitle(subtitleOptions.firstIndex { MediaOption.prefers($0.language) } ?? 0)
            }
        case .speed:
            return .unavailable("Videos has no playback speed")
        }
        return nil
    }
}

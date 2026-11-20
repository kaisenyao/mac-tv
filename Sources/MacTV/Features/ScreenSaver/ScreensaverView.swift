import AVFoundation
import SwiftUI

/// Apple-style screensaver: Apple's own aerial films when the Mac has downloaded them
/// (System Settings › Wallpaper or Screen Saver), otherwise slow-drifting colour, under a large
/// lock-screen clock at the top centre.
struct Screensaver: View {
    /// Which film or photo is showing, and whether its place or date is (see handleScreensaver)
    @ObservedObject var idle: IdleCoordinator
    @Environment(\.canvasSize) private var canvas
    /// 24-Hour Time: the clock changes the moment it's switched.
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        ZStack(alignment: .top) {
            ScreenSaverBackdrop(wallpaper: ScreenSaverSettings.wallpaper, pictures: ScreenSaverSettings.playing,
                                index: idle.picture, next: { idle.stepPicture(1) })
            // 翻页时钟自己就是钟，上面不再叠一个
            if ScreenSaverSettings.showClock, ScreenSaverSettings.wallpaper != .flipClock {
                // Keeps the clock legible over bright skies.
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .center)

                TimelineView(.everyMinute) { context in
                    VStack(spacing: 0) {
                        Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.tv(.callout))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(TimeOfDay.text(context.date, twentyFour: preferences.twentyFourHourTime, meridiem: false))
                            .font(.system(size: 230, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.92))
                            .tracking(-4)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 6)
                    .padding(.top, 70)
                }
            }
            if idle.info, let text = info {
                Text(text)
                    .font(.tv(.callout, emphasized: true))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 12, y: 3)
                    .padding(.leading, 90).padding(.bottom, 80)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: idle.info)
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    /// The film's place (Aerials) or the photo's date, or its name when it has none.
    private var info: String? {
        let pictures = ScreenSaverSettings.playing
        guard pictures.indices.contains(idle.picture) else { return nil }
        let picture = pictures[idle.picture]
        switch ScreenSaverSettings.wallpaper {
        case .aerials: return Aerials.place(of: picture)
        case .photos: return ScreenImages.taken(picture)?.formatted(date: .long, time: .omitted) ?? picture.deletingPathExtension().lastPathComponent
        default: return nil
        }
    }
}

/// Plays aerial films, muted and filling the screen: the one at `index`, and when it ends, `next`.
struct AerialPlayer: NSViewRepresentable {
    let films: [URL]
    let index: Int
    let next: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        context.coordinator.player = player
        context.coordinator.play(films, index, next: next)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.play(films, index, next: next)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.player?.pause()
        if let ended = coordinator.ended { NotificationCenter.default.removeObserver(ended) }
        coordinator.ended = nil
    }

    @MainActor
    final class Coordinator {
        var player: AVPlayer?
        var ended: NSObjectProtocol?
        private var showing: URL?

        func play(_ films: [URL], _ index: Int, next: @escaping @MainActor () -> Void) {
            guard let player, films.indices.contains(index), films[index] != showing else { return }
            showing = films[index]
            let item = AVPlayerItem(url: films[index])
            if let ended { NotificationCenter.default.removeObserver(ended) }
            ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                           queue: .main) { _ in MainActor.assumeIsolated { next() } }
            player.replaceCurrentItem(with: item)
            player.play()
        }
    }
}

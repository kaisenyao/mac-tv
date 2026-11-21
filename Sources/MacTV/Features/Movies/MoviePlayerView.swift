import AppKit
import SwiftUI

// MARK: Player

/// A movie on the TV: the picture, subtitles, and Apple TV's controls in Liquid Glass: back at
/// the top, skip and play/pause in the middle, and the title, subtitle and audio buttons and the
/// progress bar at the bottom. The remote drives them (left and right skip, select plays or
/// pauses, down opens subtitles and audio) and so does the mouse.
struct MoviePlayerView: View {
    @ObservedObject var player: MoviePlayer

    var body: some View {
        ZStack {
            LayerHost(layer: player.engine.layer).ignoresSafeArea()
                .onTapGesture { player.togglePlayback() }

            TVCanvas {
                ZStack(alignment: .bottom) {
                    if let text = player.subtitleText {
                        Text(text)
                            .font(.tv(.title3))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 3)
                            .shadow(color: .black.opacity(0.6), radius: 10)
                            .padding(.horizontal, 200)
                            .padding(.bottom, player.controlsVisible ? 300 : 80)
                            .animation(Motion.appear, value: player.controlsVisible)
                            .allowsHitTesting(false)
                    }
                    if player.controlsVisible {
                        controls.transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .foregroundStyle(.white)
            }
            .ignoresSafeArea()
        }
        .background(Color.black)
        .onContinuousHover { phase in
            if case .active(let point) = phase { player.pointerMoved(to: point) }
        }
    }

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 240)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: 480)
            }
            .allowsHitTesting(false)

            PlayerButton(symbol: "chevron.backward", size: 72, action: { player.onClose?() })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 96)
                .padding(.top, 64)

            GlassGroup(spacing: 0) {
                HStack(spacing: 56) {
                    TransportButton(symbol: "gobackward.10", size: 100, pressed: player.pressed == "back") { player.skip(-10) }
                    TransportButton(symbol: player.playing ? "pause.fill" : "play.fill", size: 136,
                                     pressed: player.pressed == "playpause") { player.togglePlayback() }
                    TransportButton(symbol: "goforward.10", size: 100, pressed: player.pressed == "forward") { player.skip(10) }
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                if let menu = player.menu {
                    menuView(menu).frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(player.movie.displayTitle)
                            .font(.tv(.headline, emphasized: true))
                            .lineLimit(1)
                        if !details.isEmpty {
                            Text(details).font(.tv(.caption2)).opacity(0.7)
                        }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    Spacer(minLength: 0)
                    GlassGroup {
                        HStack(spacing: 18) {
                            if !player.subtitleOptions.isEmpty {
                                PlayerButton(symbol: player.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill",
                                             size: 68, lit: player.menuShowsSubtitles) { player.toggleMenu(subtitles: true) }
                            }
                            if player.audioOptions.count > 1 {
                                PlayerButton(symbol: "speaker.wave.2.bubble", size: 68,
                                             lit: player.menu != nil && !player.menuShowsSubtitles) { player.toggleMenu(subtitles: false) }
                            }
                        }
                    }
                }
                progress
                HStack {
                    Text(clockText(player.time))
                    Spacer()
                    Text("−" + clockText(max(0, player.duration - player.time)))
                }
                .font(.tvTimecode)
                .shadow(color: .black.opacity(0.5), radius: 6)
            }
            .padding(.horizontal, 110)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// The year and the language you're hearing.
    private var details: String {
        var parts: [String] = []
        if let year = player.movie.year { parts.append(String(year)) }
        if let audio = player.selectedAudio, player.audioOptions.indices.contains(audio) {
            let option = player.audioOptions[audio]
            if MediaOption.languageCode(option.language) != nil { parts.append(option.title) }
        }
        return parts.joined(separator: "  ·  ")
    }

    /// The progress bar; click anywhere on it to jump there.
    private var progress: some View {
        GeometryReader { geo in
            let fraction = player.duration > 0 ? min(1, player.time / player.duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 12)
                Capsule().fill(.white).frame(width: max(12, geo.size.width * fraction), height: 12)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in player.seek(toFraction: location.x / max(geo.size.width, 1)) }
        }
        .frame(height: 36)
        .shadow(color: .black.opacity(0.4), radius: 6)
    }

    private func menuView(_ menu: MoviePlayer.Menu) -> some View {
        let columns = player.menuColumns
        let titles = columns.count == 2 ? ["Audio", "Subtitles"] : ["Subtitles"]
        return HStack(alignment: .top, spacing: 40) {
            ForEach(Array(columns.enumerated()), id: \.offset) { column, options in
                VStack(alignment: .leading, spacing: 8) {
                    Text(titles[column]).font(.tv(.caption2, emphasized: true)).textCase(.uppercase).tracking(1).opacity(0.6)
                        .padding(.leading, 16)
                    ForEach(Array(options.enumerated()), id: \.offset) { row, title in
                        let focused = menu.column == column && menu.row == row
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark").opacity(player.selectedRow(in: column) == row ? 1 : 0)
                            Text(title).lineLimit(1)
                        }
                        .font(.tvMenuItem)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .frame(minWidth: 300, alignment: .leading)
                        .foregroundStyle(focused ? .black : .white)
                        .background(focused ? .white : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { player.choose(column: column, row: row) }
                    }
                }
            }
        }
        .padding(24)
        .tvGlass(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .animation(Motion.focus, value: menu)
    }

}

/// A small round glass control at the player's edges (back, subtitles, audio). `lit` shows it
/// white while its menu is open.
struct PlayerButton: View {
    let symbol: String
    let size: CGFloat
    var lit = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if lit { Circle().fill(.white) }
                Image(systemName: symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
            }
            .frame(width: size, height: size)
            .foregroundStyle(lit ? .black : .white)
            .tvGlass(in: Circle())
            .contentShape(Circle())
            .animation(Motion.press, value: lit)
        }
        .buttonStyle(PressStyle(pressed: false))
    }
}

/// The middle controls: skip and play/pause in glass circles. A press, from the remote
/// (`pressed`) or a click, dips the whole circle slightly and it settles back.
struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var pressed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .tvGlass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressed: pressed))
    }
}

/// A press: the control dips a little and settles back, with no bounce.
struct PressStyle: ButtonStyle {
    let pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(pressed || configuration.isPressed ? 0.94 : 1)
            .animation(Motion.press, value: pressed || configuration.isPressed)
    }
}

/// Shows a Core Animation layer (the video) filling the view.
struct LayerHost: NSViewRepresentable {
    let layer: CALayer

    final class Host: NSView {
        var hosted: CALayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor.black
        view.layer?.addSublayer(layer)
        view.hosted = layer
        return view
    }

    func updateNSView(_ nsView: Host, context: Context) {}
}

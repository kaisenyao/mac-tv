import AppKit
import SwiftUI

/// Apple TV's volume indicator: a glass capsule with the speaker and the level.
struct VolumeHUD: View {
    let volume: VolumeLevel

    var body: some View {
        HStack(spacing: 18) {
            SpeakerGlyph(level: volume.level, muted: volume.muted, unknown: "tv", box: CGSize(width: 40, height: 28),
                         weight: .semibold)
            if let level = volume.level {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * CGFloat(volume.muted ? 0 : level) / 100)
                    }
                }
                .frame(width: 260, height: 8)
            } else {
                // 显示器不回 DDC、放着的又是别的应用：Mac TV 够不着。用 Apple 控制中心的说法
                Text("Not Available").font(.tv(.caption2))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .frame(height: 72)
        .animation(.smooth(duration: 0.2), value: volume)
        .tvGlass(in: Capsule())
    }
}

/// The speaker that shows how loud, as iOS's: three waves, two, one, a slash when muted or at nothing. It's always
/// drawn at the one size the three waves fill the box at, and always centred in it: as the waves go (or come back) the
/// whole glyph glides to stay in the middle, and muted, the crossed-out speaker sits in the middle too. The change of
/// form is Apple's replace effect (the waves fade in and out; the speaker is the same). One look wherever the volume
/// shows: the volume indicator, Control Center, the Volume and Navigation Clicks sliders.
struct SpeakerGlyph: View {
    /// 0…100; nil when the output's level can't be read (then `unknown` shows).
    let level: Int?
    var muted = false
    var unknown = "speaker.fill"
    /// The box the three-wave speaker fills.
    let box: CGSize
    var weight: Font.Weight = .medium

    nonisolated static func symbol(level: Int?, muted: Bool, unknown: String = "speaker.fill") -> String {
        guard let level else { return unknown }
        if muted || level == 0 { return "speaker.slash.fill" }
        return level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        let symbol = Self.symbol(level: level, muted: muted, unknown: unknown)
        Image(systemName: symbol)
            .font(.system(size: Self.pointSize(fitting: box), weight: weight))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: box.width, height: box.height)
            .animation(.smooth(duration: 0.25), value: symbol)
    }

    private static var sizes: [String: CGFloat] = [:]

    /// The point size at which the three-wave speaker just fits `box` (measured once per box).
    private static func pointSize(fitting box: CGSize) -> CGFloat {
        let key = "\(box.width)x\(box.height)"
        if let size = sizes[key] { return size }
        let probe: CGFloat = 100
        let measured = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: probe, weight: .medium))?.size
        let size = measured.map { probe * min(box.width / $0.width, box.height / $0.height) } ?? box.height
        sizes[key] = size
        return size
    }
}

/// The volume's speaker, kept in step with the Mac's volume as it changes (Control Center's Audio tile and Mute button).
struct VolumeSpeaker: View {
    @ObservedObject var audio: AudioCoordinator
    let box: CGSize
    var weight: Font.Weight = .medium

    var body: some View {
        SpeakerGlyph(level: audio.currentVolume.level, muted: audio.currentVolume.muted, box: box, weight: weight)
    }
}

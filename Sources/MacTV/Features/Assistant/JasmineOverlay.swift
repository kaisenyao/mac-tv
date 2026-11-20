import SwiftUI

/// Jasmine on screen: her orb in the bottom-right corner, where tvOS shows Siri, and a glass capsule beside it with
/// what you're saying as it's heard, or her line. Over everything (RootView), never taking the pointer. Drawn only
/// while she shows: hidden, nothing of it runs.
struct JasmineOverlay: View {
    @ObservedObject var jasmine: Jasmine

    var body: some View {
        TVCanvas {
            GlassGroup {
                if jasmine.shown {
                    HStack(alignment: .center, spacing: 26) {
                        if let text = caption {
                            Text(text)
                                .font(.tv(.headline))
                                .foregroundStyle(.white.opacity(jasmine.line == nil && jasmine.phase == .listening ? 0.75 : 1))
                                .lineLimit(2)
                                .truncationMode(.head)
                                .frame(maxWidth: 1040, alignment: .trailing)
                                .padding(.horizontal, 36).padding(.vertical, 22)
                                .tvGlass(in: Capsule())
                                .tvGlassTransition()
                        }
                        JasmineOrb(phase: jasmine.phase, level: jasmine.level)
                            .frame(width: orbSize, height: orbSize)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                    .animation(Motion.appear, value: caption)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 96)
            .padding(.bottom, 72)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(Motion.appear, value: jasmine.shown)
    }

    private var orbSize: CGFloat { jasmine.mode == .dictation ? 88 : 120 }

    private var caption: String? {
        if let line = jasmine.line { return line }
        return jasmine.heard.isEmpty ? nil : jasmine.heard
    }
}

/// The orb: PianaSoul's blue (its ORB_COLORS.blue), a soft sky over a slow tide of light that swells with the voice.
/// About 30 frames a second while it shows; Reduce Motion keeps it still.
struct JasmineOrb: View {
    let phase: Jasmine.Phase
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sky = [Color(red: 0.20, green: 0.42, blue: 0.80), Color(red: 0.42, green: 0.66, blue: 0.94)]
    private static let tide = [Color(red: 0.78, green: 0.89, blue: 0.98), Color(red: 0.95, green: 0.98, blue: 1)]
    private static let under = Color(red: 0.56, green: 0.74, blue: 0.95)

    var body: some View {
        if reduceMotion {
            orb(time: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                orb(time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    /// Faster while she listens, as PianaSoul's: energy 0.4 hearing, 0.16 otherwise; the voice adds to it.
    private var energy: Double { (phase == .listening ? 0.4 : 0.16) + Double(level) * 0.6 }

    private func orb(time: Double) -> some View {
        let t = time * (1 + energy)
        let swell = 0.10 * sin(0.9 * t) + 0.04 * sin(1.7 * t + 1)
        let rise = 0.30 - swell - energy * 0.16
        return GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                LinearGradient(colors: Self.sky, startPoint: .top, endPoint: .bottom)
                // The tide: a bright face that rises with the voice and rolls slowly.
                Ellipse()
                    .fill(LinearGradient(colors: Self.tide.reversed(), startPoint: .top, endPoint: .bottom))
                    .frame(width: side * 2.2, height: side * 1.3)
                    .rotationEffect(.radians(0.18 * sin(0.6 * t)))
                    .offset(y: side * (0.62 + rise))
                    .blur(radius: side * 0.05)
                RadialGradient(colors: [.clear, Self.under.opacity(0.35)], center: .center,
                               startRadius: side * 0.2, endRadius: side * 0.6)
            }
            .frame(width: side, height: side)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Self.sky[1].opacity(0.45 + energy * 0.3), radius: 18 + energy * 14)
            .scaleEffect(1 + 0.012 * sin(1.3 * t) + CGFloat(level) * 0.11)
        }
    }
}

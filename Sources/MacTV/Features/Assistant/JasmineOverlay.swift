import SwiftUI

/// Jasmine on screen, laid out as tvOS 26's Siri:
/// - her orb in the top-right corner; while she listens or works, a glass capsule beside it with your words;
/// - a short answer (or why she can't), in a floating card there (tvPanelSurface, tvShadow(.float));
/// - a longer answer, in large type at the top left over the whole screen dimmed (SheetBackdrop): a few lines,
///   then MORE (Select shows the rest).
/// Over everything (RootView), never taking the pointer. Drawn only while she shows: hidden, nothing of it runs.
struct JasmineOverlay: View {
    @ObservedObject var jasmine: Jasmine

    var body: some View {
        ZStack {
            if let answer = longAnswer {
                SheetBackdrop()
                    .transition(.opacity)
                TVCanvas {
                    JasmineAnswer(text: answer, expanded: jasmine.expanded)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 120)
                        .padding(.top, 140)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
            TVCanvas {
                GlassGroup {
                    if jasmine.shown { corner.tvGlassTransition() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 96)
                .padding(.top, 52)
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .animation(Motion.appear, value: jasmine.shown)
        .animation(Motion.appear, value: longAnswer != nil)
        .animation(Motion.appear, value: cornerText)
    }

    /// The top-right corner: the orb, with your words or her short answer beside it.
    @ViewBuilder private var corner: some View {
        let orb = JasmineOrb(phase: jasmine.phase, level: jasmine.level).frame(width: orbSize, height: orbSize)
        if let text = cornerText {
            let content = HStack(alignment: .center, spacing: 22) {
                Text(text)
                    .font(.tv(.callout))
                    .foregroundStyle(.white.opacity(dimmed ? 0.7 : 1))
                    .lineLimit(cornerIsCard ? 3 : 1)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 680, alignment: .leading)
                orb
            }
            .padding(.leading, 34).padding(.trailing, 14).padding(.vertical, 14)
            if cornerIsCard {
                // Her short answer: a floating card (Layers: a panel's surface and shadow).
                content
                    .tvPanelSurface(in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                    .tvShadow(.float)
            } else {
                // Your words while she hears: a caption (Layers: a notice, a glass capsule).
                content.tvGlass(in: Capsule())
            }
        } else {
            orb.padding(14).tvGlass(in: Circle())
        }
    }

    private var orbSize: CGFloat { jasmine.mode == .dictation ? 56 : 72 }

    /// Her answer, when it's too long for the corner.
    private var longAnswer: String? {
        guard jasmine.phase == .speaking || jasmine.phase == .message, let line = jasmine.line,
              JasmineAnswer.isLong(line) else { return nil }
        return line
    }

    /// What the corner says: her short answer, or your words while she hears and works.
    private var cornerText: String? {
        if let line = jasmine.line { return longAnswer != nil ? nil : line }
        return jasmine.heard.isEmpty ? nil : jasmine.heard
    }

    private var cornerIsCard: Bool { jasmine.line != nil }
    /// Your words once you've let go, while she works on them.
    private var dimmed: Bool { jasmine.line == nil && jasmine.phase != .listening }
}

/// A longer answer: large type, a few lines, then MORE.
struct JasmineAnswer: View {
    let text: String
    let expanded: Bool

    static let lines = 4

    /// Too long for the corner's card: more than one sentence, or more than a short line.
    static func isLong(_ text: String) -> Bool {
        text.count > 36 || Sentences.split(text).count > 1
    }

    /// Long enough to be cut at `lines` lines (about 26 characters a line at this size).
    static func isCut(_ text: String) -> Bool { text.count > lines * 26 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(text)
                .font(.tv(.title2, emphasized: true))
                .foregroundStyle(.white)
                .lineLimit(expanded ? nil : Self.lines)
                .lineSpacing(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 1180, alignment: .leading)
            if !expanded, Self.isCut(text) {
                Text("MORE").font(.tv(.caption1, emphasized: true)).tracking(1.4).opacity(0.6)
            }
        }
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

    /// As PianaSoul's: energy 0.7 speaking, 0.4 hearing or thinking, 0.16 otherwise; the voice adds to it.
    private var energy: Double {
        let base = switch phase {
        case .speaking: 0.7
        case .listening, .thinking, .finishing: 0.4
        default: 0.16
        }
        return base + Double(level) * 0.6
    }

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
            .scaleEffect(1 + 0.012 * sin(1.3 * t) + CGFloat(level) * 0.11)
        }
    }
}

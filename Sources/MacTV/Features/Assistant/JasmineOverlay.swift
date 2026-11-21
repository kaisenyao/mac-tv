import SwiftUI

/// Jasmine on screen, laid out as tvOS 26's Siri:
/// - her orb in the top-right corner (PianaSoul's orb, a plain circle: JasmineOrb); while she listens or works, a
///   glass capsule beside it with your words;
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
                GlassGroup { corner }
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
    private var corner: some View {
        HStack(alignment: .center, spacing: 24) {
            if let text = cornerText {
                let content = Text(text)
                    .font(.tv(.callout))
                    .foregroundStyle(.white.opacity(dimmed ? 0.7 : 1))
                    .lineLimit(cornerIsCard ? 3 : 1)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 34).padding(.vertical, 22)
                if cornerIsCard {
                    // Her short answer: a floating card (Layers: a panel's surface and shadow).
                    content
                        .tvPanelSurface(in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                        .tvShadow(.float)
                        .tvGlassTransition()
                } else {
                    // Your words while she hears: a caption (Layers: a notice, a glass capsule).
                    content.tvGlass(in: Capsule()).tvGlassTransition()
                }
            }
            if jasmine.shown {
                JasmineOrb(phase: jasmine.phase, level: jasmine.level)
                    .frame(width: orbSize, height: orbSize)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    /// About 1.4× the size tvOS gives Siri's orb: PianaSoul's orb is a large one.
    private var orbSize: CGFloat { jasmine.mode == .dictation ? 78 : 100 }

    /// Her answer, when it's too long for the corner.
    private var longAnswer: String? {
        guard jasmine.phase == .speaking || jasmine.phase == .message, let line = jasmine.line,
              JasmineAnswer.isLong(line) else { return nil }
        return line
    }

    /// What the corner says: her short answer, or your words while she hears and works.
    private var cornerText: String? {
        guard jasmine.shown else { return nil }
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

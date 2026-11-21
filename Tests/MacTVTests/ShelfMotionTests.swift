import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import MacTV

/// The Top Shelf's page turn runs in Core Animation (ShelfMotion.swift). It has to move and look as the SwiftUI
/// animations it replaced did: the same spring, the same colours, the same dots.
@Suite(.timeLimit(.minutes(1))) @MainActor struct ShelfMotionTests {
    @Test func theSpringIsSwiftUIsSpring() {
        for (ours, theirs) in [(ShelfSpring.page, Spring(response: 0.55, dampingRatio: 0.9)),
                               (ShelfSpring.insert, Spring(response: 0.5, dampingRatio: 0.9))] {
            #expect(abs(ours.stiffness - theirs.stiffness) < 1e-6)
            #expect(abs(ours.damping - theirs.damping) < 1e-6)
            for t in stride(from: 0.0, through: 1.5, by: 0.05) {
                #expect(abs(ours.progress(t) - theirs.value(target: 1.0, time: t)) < 1e-6, "at \(t) s")
            }
            let animation = ours.animation("opacity")
            #expect(animation.mass == 1 && abs(animation.stiffness - theirs.stiffness) < 1e-6 && abs(animation.damping - theirs.damping) < 1e-6)
            // Settled: within a thousandth of the end, as SwiftUI considers it done
            #expect(abs(1 - ours.progress(ours.settlingDuration)) < 0.002)
            #expect(ours.settlingDuration > 0.5 && ours.settlingDuration < 3)
        }
    }

    /// The background layers draw what the SwiftUI gradients drew: same colours, same places
    @Test func theBackdropLooksLikeTheSwiftUIGradients() throws {
        let size = CGSize(width: 480, height: 270)
        let palette = ArtPalette(accent: "#FF6A00")
        let center = UnitPoint(x: 0.7, y: 0.4)
        let swiftUI = ZStack {
            LinearGradient(colors: [palette.glow.opacity(0.55), palette.base], startPoint: .topTrailing, endPoint: .bottomLeading)
            RadialGradient(colors: [palette.glow.opacity(0.55), .clear], center: center, startRadius: 0, endRadius: 160)
        }
        let backdrop = ShelfBackdrop(layers: [
            ShelfGradient(kind: .linear(start: .topTrailing, end: .bottomLeading), colors: [palette.glow.opacity(0.55), palette.base]),
            ShelfGradient(kind: .radial(center: center, radius: 160), colors: [palette.glow.opacity(0.55), .clear]),
        ])
        let video = (
            ZStack {
                palette.base
                LinearGradient(stops: [.init(color: palette.base.opacity(0.85), location: 0), .init(color: palette.glow.opacity(0.35), location: 0.38),
                                       .init(color: .clear, location: 0.6)], startPoint: .leading, endPoint: .trailing)
            },
            ShelfBackdrop(layers: [
                ShelfGradient(kind: .solid, colors: [palette.base]),
                ShelfGradient(kind: .linear(start: .leading, end: .trailing),
                              colors: [palette.base.opacity(0.85), palette.glow.opacity(0.35), .clear], locations: [0, 0.38, 0.6]),
            ]))
        for (expected, actual) in [(Self.pixels(swiftUI, size), Self.pixels(backdrop, size)),
                                   (Self.pixels(video.0, size), Self.pixels(video.1, size))] {
            let a = try #require(expected), b = try #require(actual)
            var total = 0.0, worst = 0.0
            for i in a.indices {
                let d = abs(Double(a[i]) - Double(b[i]))
                total += d
                worst = max(worst, d)
            }
            let mean = total / Double(a.count)
            #expect(mean < 2, "mean difference \(mean) / 255")
            #expect(worst < 12, "largest difference \(worst) / 255")
        }
    }

    /// The dots sit where SwiftUI's row put them: 8-point dots, the current one 30 points, 9 points around each
    @Test func theDotsAreWhereTheRowPutThem() throws {
        let view = ShelfDotsView()
        view.frame = CGRect(x: 0, y: 0, width: ShelfDots.totalWidth(count: 4), height: 8)
        view.show(count: 4, current: 2, animated: false)
        let dots = try #require(view.layer?.sublayers)
        #expect(dots.map(\.frame.width) == [8, 8, 30, 8])
        #expect(dots.map(\.frame.minX) == [4.5, 21.5, 38.5, 77.5])
        #expect(dots.map(\.opacity) == [0.32, 0.32, 0.95, 0.32])
        #expect(ShelfDots.totalWidth(count: 4) == 90)   // 30 + 3 × 8, and 9 around each of the 4
        // A turn moves them along the page spring, in Core Animation
        view.show(count: 4, current: 3, animated: true)
        #expect(dots[3].frame.width == 30 && dots[2].frame.width == 8)
        let spring = try #require(dots[3].animation(forKey: "bounds.size.width") as? CASpringAnimation)
        #expect(abs(spring.stiffness - ShelfSpring.page.stiffness) < 1e-9)
    }

    /// A turn: the page on show slides away in 0.16 s and stays hidden; the other layer takes the new page and slides in
    /// after 0.14 s. No view goes in or out of the hierarchy, and the two layers take turns.
    @Test func turnsSlideTwoLayersInCoreAnimation() throws {
        let saved = ShelfPageSchedule.later
        defer { ShelfPageSchedule.later = saved }
        var queued: [@MainActor () -> Void] = []
        ShelfPageSchedule.later = { _, work in queued.append(work) }
        let view = ShelfPageView(Text("1"))
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layoutSubtreeIfNeeded()
        let first = view.front
        // The second layer is built a second later, while nothing is happening
        #expect(view.back == nil && queued.count == 1)
        queued.removeFirst()()
        let spare = try #require(view.back)
        #expect(spare.box.layer?.opacity == 0 && view.subviews.count == 2)
        view.turn(to: Text("2"), offset: 160)
        let second = view.front
        #expect(second === spare && view.back === first && view.subviews.count == 2)
        // Its new content goes in a frame later (it's hidden for the first 0.14 s anyway)
        #expect(queued.count == 1)
        queued.removeFirst()()
        let move = try #require(second.box.layer?.animation(forKey: "in-transform.translation.x") as? CASpringAnimation)
        #expect(move.fromValue as? CGFloat == 160 && move.toValue as? CGFloat == 0 && move.isAdditive)
        #expect(move.fillMode == .backwards && move.beginTime > 0)
        #expect(abs(move.stiffness - ShelfSpring.insert.stiffness) < 1e-9)
        let away = try #require(first.box.layer?.animation(forKey: "out-transform.translation.x") as? CABasicAnimation)
        #expect(away.toValue as? CGFloat == -96 && away.duration == 0.16)
        #expect(first.box.layer?.opacity == 0 && second.box.layer?.opacity == 1)
        // Next turn: the first layer comes back with the third page; its content goes in a frame later
        view.turn(to: Text("3"), offset: -160)
        #expect(view.front === first && view.back === second && view.subviews.count == 2)
        #expect(queued.count == 1)
        queued.removeFirst()()
        // A change without animation (new content fetched): straight in, nothing moving
        view.replace(with: Text("4"))
        #expect(view.front.box.layer?.animationKeys() == nil && view.back?.box.layer?.opacity == 0)
    }

    /// A picture that fills the screen cross-fades: the page on show stays whole where it is until the next has faded in
    /// over it (0.14 s, then the spring), instead of sliding away first and leaving the screen dark between the two.
    @Test func aFullScreenPageStaysUntilTheNextCoversIt() throws {
        let saved = ShelfPageSchedule.later
        defer { ShelfPageSchedule.later = saved }
        var queued: [@MainActor () -> Void] = []
        ShelfPageSchedule.later = { _, work in queued.append(work) }
        let view = ShelfPageView(Text("1"))
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        view.layoutSubtreeIfNeeded()
        let first = view.front
        queued.removeFirst()()
        view.turn(to: Text("2"), offset: 60, crossfade: true)
        let hold = try #require(first.box.layer?.animation(forKey: "out-opacity") as? CABasicAnimation)
        #expect(hold.fromValue as? Float == 1 && hold.toValue as? Float == 1)
        #expect(abs(hold.duration - (0.14 + ShelfSpring.insert.settlingDuration)) < 1e-9)
        let stay = try #require(first.box.layer?.animation(forKey: "out-transform.translation.x") as? CABasicAnimation)
        #expect(stay.fromValue as? CGFloat == 0 && stay.toValue as? CGFloat == 0)
        // Afterwards it's hidden, and the new page is the one above it, fading in
        #expect(first.box.layer?.opacity == 0 && view.front.box.layer?.opacity == 1 && view.subviews.last === view.front.box)
        #expect(view.front.box.layer?.animation(forKey: "in-opacity") != nil)
    }

    /// Several pages' content goes in one frame after another, not all in the turn's frame
    @Test func staggeredWorkGoesOneFrameApart() {
        let saved = ShelfPageSchedule.later
        defer { ShelfPageSchedule.later = saved }
        var delays: [TimeInterval] = []
        var queued: [@MainActor () -> Void] = []
        ShelfPageSchedule.later = { delay, work in delays.append(delay); queued.append(work) }
        var ran: [Int] = []
        ShelfPageSchedule.next { ran.append(1) }
        ShelfPageSchedule.next { ran.append(2) }
        #expect(delays.count == 2 && delays[0] < delays[1] && delays[1] < 0.14)
        queued.forEach { $0() }
        #expect(ran == [1, 2])
    }

    private static func pixels<V: View>(_ view: V, _ size: CGSize) -> [UInt8]? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = 1
        if let cg = renderer.cgImage { return rgba(cg, size) }
        return nil
    }

    private static func pixels(_ backdrop: ShelfBackdrop, _ size: CGSize) -> [UInt8]? {
        // The layers themselves, drawn as Core Animation would (the representable's view, laid out at this size)
        let host = NSHostingView(rootView: backdrop.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let view = Self.find(ShelfBackdropView.self, in: host) else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let layer = view.layer,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.black)   // what ImageRenderer leaves under transparent parts
        context.clear(CGRect(origin: .zero, size: size))
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return rgba(image, size)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }

    private static func rgba(_ image: CGImage, _ size: CGSize) -> [UInt8]? {
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return data
    }
}

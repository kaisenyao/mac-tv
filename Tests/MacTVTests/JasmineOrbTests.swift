import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacTV

/// Jasmine's orb (PianaSoul's, orb.js) and her two sounds (PianaSoul's cue-active.mp3 and cue-end.mp3). The orb is
/// drawn offscreen only; the sounds are read, never played.
@Suite(.serialized) @MainActor struct JasmineOrbTests {
    // MARK: Motion (orb.js's draw)

    @Test func theVoiceIsEasedInAndOutNeverAJump() {
        var motion = OrbMotion()
        var clock = 0.0
        let first = motion.step(now: 10, input: 1, energy: 0.7, reduced: false, clock: &clock)
        #expect(first.level == 0 && clock == 0, "the first frame after she shows: dt 0, nothing moves")
        // She starts speaking: each 60th of a second takes 1 − e^(−9/60) of the way, as orb.js's blend
        let step = Float(1 - exp(-9.0 / 60))
        var level: Float = 0
        for frame in 1...60 {
            let next = motion.step(now: 10 + Double(frame) / 60, input: 1, energy: 0.7, reduced: false, clock: &clock)
            #expect(abs(next.level - (level + (1 - level) * step)) < 0.0001)
            #expect(next.level - level <= step + 0.0001, "never more than one frame's share")
            level = next.level
        }
        #expect(level > 0.99, "there in a second")
        // She stops: it settles as smoothly
        var previous = level
        for frame in 61...90 {
            let next = motion.step(now: 10 + Double(frame) / 60, input: 0, energy: 0.16, reduced: false, clock: &clock)
            #expect(next.level < previous && previous - next.level <= previous * step + 0.0001)
            previous = next.level
        }
        // A stall is taken as a tenth of a second, as orb.js's
        let before = motion.volume
        _ = motion.step(now: 100, input: 1, energy: 0.16, reduced: false, clock: &clock)
        #expect(abs(motion.volume - (before + (1 - before) * Float(1 - exp(-0.9)))) < 0.0001)
    }

    @Test func theClockRunsWithHerAndYourVoice() {
        var motion = OrbMotion()
        var clock = 5.0
        _ = motion.step(now: 0, input: 0, energy: 0.16, reduced: false, clock: &clock)
        _ = motion.step(now: 0.1, input: 0, energy: 0.16, reduced: false, clock: &clock)
        #expect(abs(clock - (5 + 0.1 * 1.16)) < 1e-6, "1 + energy, nothing heard")
        let frame = motion.step(now: 0.2, input: 0, energy: 0.7, reduced: false, clock: &clock)
        #expect(abs(clock - (5 + 0.1 * 1.16 + 0.1 * 1.7)) < 1e-6)
        #expect(abs(frame.scale - (1 + Float(sin(clock * 1.4)) * 0.012)) < 0.0001, "the breath")
        #expect(frame.time == Float(clock))
        // Shown again after a while: no jump
        motion.pause()
        let again = motion.step(now: 50, input: 0, energy: 0.7, reduced: false, clock: &clock)
        #expect(again.time == frame.time)
        #expect(OrbMotion.energy(.speaking) == 0.7 && OrbMotion.energy(.listening) == 0.4
                && OrbMotion.energy(.thinking) == 0.4 && OrbMotion.energy(.message) == 0.16)
    }

    @Test func reduceMotionKeepsItStill() {
        var motion = OrbMotion()
        var clock = 3.0
        _ = motion.step(now: 0, input: 1, energy: 0.7, reduced: true, clock: &clock)
        let frame = motion.step(now: 0.1, input: 1, energy: 0.7, reduced: true, clock: &clock)
        #expect(clock == 3 && frame == OrbMotion.Frame(time: 3, level: 0, scale: 1))
    }

    // MARK: The picture

    /// orb.js's shader compiled for Metal and drawn offscreen: her blue in a ball of glass, nothing around it. With
    /// MACTV_ORB_PREVIEW set to a folder, the three pictures go there as PNGs (idle, hearing, speaking), and the
    /// frames of five seconds of her moving.
    @MainActor @Test func theOrbIsDrawnAsPianaSoulsIs() throws {
        guard let pipeline = OrbPipeline.shared else { return }   // no Metal here: nothing to check
        let side = 226                                            // the orb at 100 points, 2× pixels, its room
        let frame = OrbMotion.Frame(time: 12, level: 0.3, scale: 1)
        let (image, _) = try #require(pipeline.image(side: side, frame: frame))
        let pixels = try #require(Self.pixels(image))
        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * side + x) * 4
            return (Int(pixels[i + 2]), Int(pixels[i + 1]), Int(pixels[i]), Int(pixels[i + 3]))
        }
        #expect(at(0, 0).a == 0 && at(side - 1, side / 2).a == 0, "nothing outside the ball: no ring")
        let top = at(side / 2, side / 2 - 70)                     // the sky
        #expect(top.a == 255 && top.b > top.r && top.b > 150, "her blue sky: \(top)")
        let low = at(side / 2, side / 2 + 70)                     // the tide's bright face
        #expect(low.r > 170 && low.g > 200 && low.b > 220, "the tide: \(low)")
        // Clear glass, no line round it: at the very edge the picture is whole, and no brighter than just inside it
        let edge = at(side / 2, side / 2 - 97), inside = at(side / 2, side / 2 - 88)
        #expect(edge.a == 255 && edge.b <= inside.b + 6, "no rim: \(edge) beside \(inside)")

        // The cost of a frame, and the previews
        var gpu: TimeInterval = 0
        let start = CACurrentMediaTime()
        for i in 0..<120 { gpu += pipeline.image(side: side, frame: .init(time: Float(i) / 60, level: 0.5, scale: 1))?.gpu ?? 0 }
        Log.app.notice("Orb frame: \(String(format: "%.3f", gpu / 120 * 1000), privacy: .public) ms GPU, \(String(format: "%.3f", (CACurrentMediaTime() - start) / 120 * 1000), privacy: .public) ms with readback")
        print("Orb frame at \(side) px: \(String(format: "%.3f", gpu / 120 * 1000)) ms GPU; \(String(format: "%.3f", (CACurrentMediaTime() - start) / 120 * 1000)) ms each with a wait and a readback")
        if let folder = ProcessInfo.processInfo.environment["MACTV_ORB_PREVIEW"] {
            try Self.previews(pipeline, into: URL(fileURLWithPath: folder))
        }
    }

    /// As it looks a few seconds into each: the motion run at 60 fps with a voice, then one frame.
    static func previews(_ pipeline: OrbPipeline, into folder: URL) throws {
        let looks: [(name: String, phase: Jasmine.Phase, voice: (Double) -> Float)] = [
            ("idle", .message, { _ in 0 }),
            ("hearing", .listening, { t in Float(0.35 + 0.25 * sin(t * 7)) }),
            ("speaking", .speaking, { t in Float(0.65 + 0.3 * sin(t * 11)) }),
        ]
        let side = 512
        var strip: [CGImage] = []
        for look in looks {
            var motion = OrbMotion()
            var clock = 20.0
            var frame = OrbMotion.Frame(time: 0, level: 0, scale: 1)
            for i in 0...240 {
                let t = Double(i) / 60
                frame = motion.step(now: t, input: look.voice(t), energy: OrbMotion.energy(look.phase), reduced: false, clock: &clock)
            }
            let image = try #require(pipeline.image(side: side, frame: frame)?.image)
            let page = try #require(onDarkPage([image], side: side))
            strip.append(image)
            try write(page, to: folder.appendingPathComponent("orb-preview-\(look.name).png"))
            try write(image, to: folder.appendingPathComponent("orb-alone-\(look.name).png"))   // to lay over a picture
        }
        try write(try #require(onDarkPage(strip, side: side)), to: folder.appendingPathComponent("orb-preview-all.png"))

        // The motion, frame by frame (30 a second, to be joined into a film): a second resting, two hearing, two speaking
        var motion = OrbMotion()
        var clock = 20.0
        for i in 0..<150 {
            let t = Double(i) / 30
            let look = t < 1 ? looks[0] : t < 3 ? looks[1] : looks[2]
            let frame = motion.step(now: t, input: look.voice(t), energy: OrbMotion.energy(look.phase), reduced: false, clock: &clock)
            let image = try #require(pipeline.image(side: 384, frame: frame)?.image)
            try write(try #require(onDarkPage([image], side: 384)),
                      to: folder.appendingPathComponent(String(format: "orb-motion-%03d.png", i)))
        }
    }

    /// Mac TV's dark wallpaper behind them, side by side.
    static func onDarkPage(_ images: [CGImage], side: Int) -> CGImage? {
        let margin = 48
        guard let context = CGContext(data: nil, width: images.count * (side + margin) + margin, height: side + 2 * margin,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0x12 / 255, green: 0x14 / 255, blue: 0x1A / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        for (i, image) in images.enumerated() {
            context.draw(image, in: CGRect(x: margin + i * (side + margin), y: margin, width: side, height: side))
        }
        return context.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func pixels(_ image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        return [UInt8](data)
    }

    /// Her symbol for a button: a ball in outline, the tide filling it under its wave, nothing outside the box it's given.
    @Test func herSymbolIsABallWithTheTideInIt() {
        let box = CGRect(x: 10, y: 20, width: 40, height: 40)
        let path = JasmineGlyph().path(in: box)
        #expect(box.insetBy(dx: -0.5, dy: -0.5).contains(path.boundingRect), "inside its box: \(path.boundingRect)")
        #expect(path.boundingRect.width > 39 && path.boundingRect.height > 39, "and filling it")
        #expect(path.contains(CGPoint(x: 30, y: 22)), "the ball's own line, at the top")
        #expect(path.contains(CGPoint(x: 30, y: 50)), "the tide, low in the ball")
        #expect(!path.contains(CGPoint(x: 30, y: 30)), "open sky above it")
        // The wave: the tide stands higher on the left than on the right
        #expect(path.contains(CGPoint(x: 21, y: 40.4)) && !path.contains(CGPoint(x: 39, y: 40.4)), "a little higher on the left")
        #expect(!path.contains(CGPoint(x: 21, y: 37)) && path.contains(CGPoint(x: 39, y: 45)), "and shallow: nowhere near a yin and yang")
    }

    // MARK: The sounds

    @Test func herSoundsArePianaSouls() throws {
        #expect(Chime.listen.file == "cue-active.mp3" && Chime.done.file == "cue-end.mp3")
        #expect(Chime.unavailable.file == nil, "PianaSoul has no \"not now\": still made here")
        for chime in [Chime.listen, .done] {
            let url = try #require(Chimes.url(chime.file!), "in the package's resource bundle")
            let sound = try #require(Chimes.read(url))
            #expect(sound.format == Chimes.format)
            let seconds = Double(sound.frameLength) / sound.format.sampleRate
            #expect(seconds > 1.4 && seconds < 1.7, "\(chime): \(seconds) s")
        }
        let note = try #require(Chimes.synthesize(.unavailable, format: Chimes.format))
        #expect(note.format == Chimes.format)
    }
}

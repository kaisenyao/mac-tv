import AppKit
import MetalKit
import SwiftUI

/// The orb: PianaSoul's (web/orb.js), the same picture on the same clock. A bright sky over a slow tide of light,
/// with a fine grain, in her blue (ORB_COLORS.blue) on a dark page, drawn by orb.js's fragment shader ported to Metal.
/// A plain circle, nothing around it. Drawn only while it shows (60 frames a second at most, none while the window
/// is hidden); Reduce Motion keeps one still frame.
struct JasmineOrb: View {
    let phase: Jasmine.Phase
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            // Room for the breath and the voice's swell (orb.js scales the orb up to 1.12×): drawn in a larger square,
            // laid out at its own size.
            OrbSurface(energy: OrbMotion.energy(phase), input: level, reduced: reduceMotion)
                .frame(width: side * OrbMotion.room, height: side * OrbMotion.room)
                .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// How the orb moves, as orb.js's draw(): plain logic, with time passed in.
struct OrbMotion {
    /// ORB_COLORS.blue: the sky above and below, the tide's face near and far, the light under it.
    static let blue: [SIMD3<Float>] = [[0.20, 0.42, 0.80], [0.42, 0.66, 0.94], [0.78, 0.89, 0.98], [0.95, 0.98, 1],
                                       [0.56, 0.74, 0.95]]
    /// The drawing's square over the orb's: its largest scale (breath 1.012, the voice 0.11) and an edge pixel.
    static let room: CGFloat = 1.13

    /// orb.js: 0.7 speaking, 0.4 thinking or hearing (here: while she listens and works out your words), 0.16 else.
    static func energy(_ phase: Jasmine.Phase) -> Float {
        switch phase {
        case .speaking: 0.7
        case .listening, .finishing, .thinking: 0.4
        case .message, .hidden: 0.16
        }
    }

    /// One clock for every orb, as PianaSoul's: it carries on where it was when she shows again.
    @MainActor static var clock: Double = 0

    /// The voice, eased: orb.js's `volume`.
    private(set) var volume: Float = 0
    private var last: TimeInterval?

    struct Frame: Equatable {
        /// The shader's time (orb.js passes its clock; the shader runs the picture at 1.6× it).
        var time: Float
        var level: Float
        var scale: Float
    }

    /// The next frame at `now` (seconds): the voice `input` (0–1) eased in (1 − e^(−9 dt)), the clock run at
    /// 1 + energy + 1.5 × the eased voice, the breath and the swell. dt is at most 0.1 s, and 0 for the first frame
    /// (it shows again: no jump). Reduce Motion: the clock stands, no voice, no scale.
    mutating func step(now: TimeInterval, input: Float, energy: Float, reduced: Bool, clock: inout Double) -> Frame {
        let dt = last.map { min(max(now - $0, 0), 0.1) } ?? 0
        last = now
        let blend = Float(1 - exp(-dt * 9))
        volume += (min(max(input.isFinite ? input : 0, 0), 1) - volume) * blend
        if !reduced { clock += dt * Double(1 + energy + volume * 1.5) }
        let breath = 1 + Float(sin(clock * 1.4)) * 0.012
        return Frame(time: Float(clock), level: reduced ? 0 : volume, scale: reduced ? 1 : breath + volume * 0.11)
    }

    /// Starts again from the voice it had (shown again): the next frame's dt is 0.
    mutating func pause() { last = nil }
}

// MARK: Drawing

/// orb.js's shaders in Metal Shading Language, compiled from source when first needed (no metal toolchain step).
/// The picture is line for line orb.js's `moonlight` and `main`; GLSL's smoothstep with its edges reversed and
/// pow(x, 2.) (x may be negative) are written out as WebGL computes them.
enum OrbShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
      float time, level, quiet, page;   // page: 0 dark, 1 light
      float scale, edge;                // the quad's share of the drawing; the circle's soft edge, in p
      float2 unused;
      float4 hue[5];                    // her colors (ORB_COLORS), .xyz
    };
    struct Varying { float4 position [[position]]; float2 p; };

    vertex Varying orb_vertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
      const float2 corners[4] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)};
      Varying out;
      out.p = corners[id];
      out.position = float4(corners[id] * u.scale, 0, 1);
      return out;
    }

    static float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
    static float hash(float2 v) { return fract(sin(dot(v, float2(127.1, 311.7))) * 43758.5453); }

    static float3 moonlight(float2 p, float t, float energy, constant Uniforms &u) {
      float swell = .10*sin(2.12*p.x+.19*t+.15*sin(t*.13))+.033*sin(4.15*p.x-.14*t)+.045*cos(1.22*p.x+.10*t)+.016*sin(5.8*p.x+.24*t);
      float face = -p.y-.045+swell+energy*(.06+.055*sin(3.2*p.x+.9*t)+.025*sin(7.3*p.x-1.4*t));
      float near = ss(-.105, .105, face);
      float3 sky = mix(u.hue[0].xyz, u.hue[1].xyz, ss(.94, -.35, p.y));
      sky += float3(.025, .035, .040)*sin(2.6*p.x+1.5*p.y+t*.10);
      float3 tide = mix(u.hue[2].xyz, u.hue[3].xyz, ss(.02, 1.75, face)*.82);
      tide += float3(.022, .028, .034)*(sin(p.x*2.9-p.y*1.2-t*.14)*sin(p.y*2.15+p.x*.65+t*.11)*.55+cos(p.x*1.35+p.y*3.6+t*.095)*.32);
      float3 color = mix(sky, tide, near);
      float under = face-.44+.075*sin(1.95*p.x-.09*t+.3);
      color = mix(color, u.hue[4].xyz, ss(-.13, .14, under)*.47*near);
      float glow = face/(.1525+.06*energy);
      color += float3(.07, .09, .10)*exp(-(glow*glow))*mix(near, 1.0, energy)*(.45+1.4*energy);
      return clamp(color*(1.-.035*ss(.6, 1., length(p))), 0., 1.);
    }

    fragment float4 orb_fragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
      float2 p = in.p;
      float r = length(p);
      float3 base = moonlight(p, u.time*1.6, u.level, u);
      float d = ss(.55, 1., r);
      float3 dark = base*(1.-.07*d*d);
      float l = ss(.5, 1., r);
      float3 light = mix(base, float3(1.), l*l*.22);
      float3 color = mix(dark, light, u.page)+(hash(floor(in.position.xy))-.5)*.024;
      float gray = dot(color, float3(.22, .65, .13));
      color = mix(color, float3(mix(gray*.82+.08, gray*.62+.26, u.page)), u.quiet);
      // A plain circle (orb.js's border-radius: 50%), its edge a pixel soft.
      float alpha = 1.0 - ss(1.0 - u.edge, 1.0, r);
      return float4(clamp(color, 0., 1.)*alpha, alpha);
    }
    """
}

/// The compiled shader and a queue, made once (on any thread: `prepare()` makes it in the background).
final class OrbPipeline: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let state: MTLRenderPipelineState
    static let format: MTLPixelFormat = .bgra8Unorm

    /// Nil without a Metal device, or when the shader doesn't compile (logged): the orb then isn't drawn.
    static let shared: OrbPipeline? = {
        do { return try OrbPipeline() } catch {
            Log.app.error("Jasmine's orb can't be drawn: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    /// Compiles the shader away from the main thread, so her first appearance doesn't wait for it.
    static func prepare() {
        Task.detached(priority: .utility) { _ = OrbPipeline.shared }
    }

    struct Unavailable: Error {}

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Unavailable() }
        let options = MTLCompileOptions()
        // WebGL's floats: no fast-math shortcuts in sin() with the clock running for hours.
        if #available(macOS 15, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
        let library = try device.makeLibrary(source: OrbShader.source, options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "orb_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "orb_fragment")
        descriptor.colorAttachments[0].pixelFormat = Self.format
        self.device = device
        self.queue = queue
        state = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The uniforms for a frame drawn `pixels` wide (the drawing's square, `room` × the orb).
    static func uniforms(_ frame: OrbMotion.Frame, pixels: Double, colors: [SIMD3<Float>] = OrbMotion.blue) -> [Float] {
        let scale = frame.scale / Float(OrbMotion.room)
        // One drawn pixel, in p (−1…1 across the orb).
        let edge = Float(2 / max(pixels * Double(scale), 1)) * 1.5
        var values: [Float] = [frame.time, frame.level, 0, 0, scale, edge, 0, 0]
        for color in colors { values += [color.x, color.y, color.z, 0] }
        return values
    }

    /// Draws one frame into `pass` (cleared to nothing around the circle).
    func encode(_ frame: OrbMotion.Frame, pixels: Double, pass: MTLRenderPassDescriptor, into buffer: MTLCommandBuffer) {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Self.uniforms(frame, pixels: pixels)
        let length = uniforms.count * MemoryLayout<Float>.stride
        encoder.setRenderPipelineState(state)
        encoder.setVertexBytes(&uniforms, length: length, index: 0)
        encoder.setFragmentBytes(&uniforms, length: length, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// One frame offscreen, `side` pixels square (the drawing's square), for a preview or a test. Also its GPU time.
    func image(side: Int, frame: OrbMotion.Frame) -> (image: CGImage, gpu: TimeInterval)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.format, width: side, height: side,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        encode(frame, pixels: Double(side), pass: pass, into: buffer)
        buffer.makeBlitCommandEncoder().map { $0.synchronize(resource: texture); $0.endEncoding() }
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        texture.getBytes(&bytes, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return (image, buffer.gpuEndTime - buffer.gpuStartTime)
    }
}

/// The orb's Metal view. It exists only while she shows; its frames stop when it leaves the window.
struct OrbSurface: NSViewRepresentable {
    let energy: Float
    let input: Float
    let reduced: Bool
    static let framesPerSecond = 60

    func makeCoordinator() -> Painter { Painter() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: OrbPipeline.shared?.device)
        view.colorPixelFormat = OrbPipeline.format
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)   // as a browser's canvas
        view.preferredFramesPerSecond = Self.framesPerSecond
        view.delegate = context.coordinator
        update(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) { update(view, context.coordinator) }

    private func update(_ view: MTKView, _ painter: Painter) {
        painter.energy = energy
        painter.input = input
        painter.reduced = reduced
        // Reduce Motion: one still frame, drawn when asked; otherwise the view's own steady frames.
        if view.isPaused != reduced {
            view.isPaused = reduced
            view.enableSetNeedsDisplay = reduced
        }
        if reduced { view.needsDisplay = true }
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Painter) {
        view.isPaused = true
        view.delegate = nil
    }

    @MainActor final class Painter: NSObject, MTKViewDelegate {
        var energy: Float = 0.16
        var input: Float = 0
        var reduced = false
        private var motion = OrbMotion()

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // Nothing drawn while the window can't be seen; the motion picks up without a jump.
            guard view.window?.occlusionState.contains(.visible) == true else { return motion.pause() }
            guard let pipeline = OrbPipeline.shared, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable, let buffer = pipeline.queue.makeCommandBuffer() else { return }
            let frame = motion.step(now: CACurrentMediaTime(), input: input, energy: energy, reduced: reduced,
                                    clock: &OrbMotion.clock)
            pipeline.encode(frame, pixels: view.drawableSize.width, pass: pass, into: buffer)
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

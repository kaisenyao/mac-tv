@preconcurrency import AVFoundation
import CoreAudio

/// A microphone the Mac has: a device with input.
struct AudioInput: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    /// AirPods and other Bluetooth headsets: they come and go, so they're never chosen on their own.
    var isWireless: Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeAirPlay,
         kAudioDeviceTransportTypeContinuityCaptureWireless].contains(transport)
    }
    /// A microphone plugged into the Mac: USB (a webcam's too), Thunderbolt, a display's.
    var isWired: Bool {
        [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire,
         kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI,
         kAudioDeviceTransportTypeContinuityCaptureWired].contains(transport)
    }
}

enum AudioInputs {
    /// The microphones connected now, in macOS's order.
    static func list() -> [AudioInput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = number(id, kAudioDevicePropertyTransportType) ?? 0
            guard transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual else { return nil }
            return AudioInput(id: id, uid: uid, name: name, transport: transport)
        }
    }

    /// The microphone to hear with: the one chosen in Settings while it's connected; otherwise a wired one (the
    /// microphone that stays plugged in), then the Mac's own. Never macOS's default as such, which moves to AirPods
    /// whenever they connect; a wireless one only when there's nothing else.
    static func choose(_ chosen: String?, from inputs: [AudioInput]) -> AudioInput? {
        if let chosen, let input = inputs.first(where: { $0.uid == chosen }) { return input }
        return inputs.first(where: \.isWired) ?? inputs.first(where: \.isBuiltIn)
            ?? inputs.first { !$0.isWireless } ?? inputs.first
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func number(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// Hears through a microphone: 24 kHz 16-bit mono PCM (what OpenAI's realtime transcription takes), in pieces of
/// about a tenth of a second, each with its loudness (0–1) for the orb. Runs only between `start` and `stop`.
@MainActor
protocol Hearing: AnyObject {
    var onAudio: ((Data, Float) -> Void)? { get set }
    /// The microphone stopped by itself: unplugged, or macOS took it away.
    var onLost: (() -> Void)? { get set }
    func start(_ input: AudioInput?) throws
    func stop()
}

/// Whether the person has let this app use the microphone.
enum MicrophoneAccess {
    enum Status { case allowed, notAsked, denied }

    static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// macOS's own question. Answers on the main actor.
    static func ask(_ answered: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            Task { @MainActor in answered(allowed) }
        }
    }
}

@MainActor
final class Microphone: Hearing {
    var onAudio: ((Data, Float) -> Void)?
    var onLost: (() -> Void)?

    private var engine: AVAudioEngine?
    private var changes: NSObjectProtocol?
    private var input: AudioInput?
    /// Restarts after macOS changed the audio setup while hearing: a few, then it's lost.
    private var restarts = 0

    enum Failure: Error { case noMicrophone, cannotConvert }

    /// 24 kHz 16-bit mono. Never changed, so it's read from the audio thread too.
    nonisolated static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!

    func start(_ input: AudioInput?) throws {
        stop()
        restarts = 0
        try run(input)
    }

    private func run(_ input: AudioInput?) throws {
        self.input = input
        let engine = AVAudioEngine()
        let node = engine.inputNode
        if let input, let unit = node.audioUnit {
            var id = input.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }
        guard let converter = PCMConverter(from: format) else { throw Failure.cannotConvert }
        node.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format,
                        block: Self.tap(converter) { [weak self] data, level in
                            Task { @MainActor in self?.onAudio?(data, level) }
                        })
        engine.prepare()
        do { try engine.start() } catch {
            node.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        changes = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    /// macOS changed the audio setup (a device came or went, a format changed). The microphone still there: it goes
    /// on hearing, through a new engine. Gone: it's lost.
    private func configurationChanged() {
        guard engine != nil else { return }
        let input = input
        let present = input.map { input in AudioInputs.list().contains { $0.uid == input.uid } } ?? !AudioInputs.list().isEmpty
        stopEngine()
        restarts += 1
        if present, restarts <= 3, (try? run(input)) != nil { return }
        onLost?()
    }

    func stop() {
        stopEngine()
        input = nil
    }

    private func stopEngine() {
        if let changes { NotificationCenter.default.removeObserver(changes) }
        changes = nil
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The tap runs on the audio thread, not the main actor.
    nonisolated private static func tap(_ converter: PCMConverter,
                                        deliver: @escaping @Sendable (Data, Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let (data, level) = converter.convert(buffer) { deliver(data, level) }
        }
    }
}

/// Turns the microphone's own format into 24 kHz 16-bit mono. Used only on the audio thread.
private final class PCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let ratio: Double

    init?(from format: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: format, to: Microphone.format) else { return nil }
        self.converter = converter
        ratio = Microphone.format.sampleRate / format.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> (Data, Float)? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Microphone.format, frameCapacity: capacity) else { return nil }
        let input = Once()
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if input.given { status.pointee = .noDataNow; return nil }
            input.given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return nil }
        let count = Int(out.frameLength)
        var sum: Float = 0
        for i in 0..<count {
            let value = Float(samples[i]) / 32_768
            sum += value * value
        }
        let rms = (sum / Float(count)).squareRoot()
        // As PianaSoul's orb reads a voice: quiet rooms near 0, speech near 1.
        let level = min(1, max(0, (rms - 0.008) * 8))
        return (Data(bytes: samples, count: count * 2), level)
    }
}

/// The one buffer a conversion is given, called back on the converter's own thread.
private final class Once: @unchecked Sendable {
    var given = false
}

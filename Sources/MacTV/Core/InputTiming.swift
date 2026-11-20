import AppKit

/// One timing table for every input (the Siri Remote, a game controller, the keyboard; the phone page times its
/// own presses with the same numbers in remote.js). Apple publishes no timings: these are Mac TV's.
enum InputTiming {
    /// Held this long, TV, Back, Select and Power are a hold: it acts then, and letting go does nothing more.
    static let hold: TimeInterval = 0.5
    /// A held direction starts repeating (or seeking) after this long.
    static let directionHold: TimeInterval = 0.35
    /// While a hold lasts, "still held" this often (the phone's watchdog lets go after 1.2 s without one).
    static let alive: TimeInterval = 0.3
    /// Two TV presses from the same device this close together open the App Switcher.
    static let doublePress: TimeInterval = 0.45
    /// A held direction repeats at the Mac's key repeat rate, kept between these.
    static var directionRepeat: TimeInterval { min(0.2, max(0.04, NSEvent.keyRepeatInterval)) }
}

/// Tap, hold, still held and let go, for buttons that are pressed and let go: plain logic, with time passed in.
/// The Siri Remote, a game controller and the keyboard all report through this, so a button is a tap or a hold
/// by the same rule everywhere (InputTiming), a button that's already down is ignored (key repeat), and
/// `reset()` lets go of everything at once (a device going away, Mac TV losing focus).
struct PressTiming {
    typealias Phase = PhonePresses.Phase

    private struct Held {
        var deadline: TimeInterval
        var holding = false
    }
    private var held: [PhonePresses.Key: Held] = [:]

    /// The next time `advance(to:)` has something to do, if any.
    var nextDeadline: TimeInterval? { held.values.map(\.deadline).min() }

    /// A button went down. False when it was already down (a key repeat): nothing changes.
    @discardableResult
    mutating func press(_ key: PhonePresses.Key, at time: TimeInterval) -> Bool {
        guard held[key] == nil else { return false }
        held[key] = Held(deadline: time + (key.isDirection ? InputTiming.directionHold : InputTiming.hold))
        return true
    }

    /// A button came up: a tap if it wasn't held long enough, otherwise the end of the hold. Nil if it wasn't down.
    mutating func release(_ key: PhonePresses.Key) -> Phase? {
        guard let state = held.removeValue(forKey: key) else { return nil }
        return state.holding ? .release : .tap
    }

    /// Holds and "still held" that are due. A late timer gives one of each, not a burst.
    mutating func advance(to time: TimeInterval) -> [(PhonePresses.Key, Phase)] {
        var due: [(PhonePresses.Key, Phase)] = []
        for key in PhonePresses.Key.allCases {
            guard var state = held[key], state.deadline <= time + 0.001 else { continue }
            due.append((key, state.holding ? .alive : .hold))
            state.holding = true
            state.deadline = time + InputTiming.alive
            held[key] = state
        }
        return due
    }

    /// Lets go of everything: holds end (release), taps not yet complete are dropped.
    mutating func reset() -> [(PhonePresses.Key, Phase)] {
        defer { held = [:] }
        return PhonePresses.Key.allCases.compactMap { held[$0]?.holding == true ? ($0, .release) : nil }
    }
}

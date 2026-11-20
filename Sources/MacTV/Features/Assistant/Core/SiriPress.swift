import Foundation

// The assistant's core (Features/Assistant/Core) uses nothing of Mac TV's own: a product that wants Jasmine brings
// its own buttons, keys and tools. Mac TV's side is in Features/Assistant.

/// The Siri button's moments, the same from every input. `down` comes at once, so the microphone can start before
/// the hold is decided and the first word isn't lost; then a tap, or a hold and its release; `cancel` when the
/// input went away mid-press (the remote disconnected).
enum SiriPhase: String, Sendable {
    case down, tap, hold, release, cancel
}

/// One Siri button's timing: plain logic, with time passed in.
struct SiriPress {
    let holdAfter: TimeInterval
    private var downAt: TimeInterval?
    private var holding = false

    init(holdAfter: TimeInterval) { self.holdAfter = holdAfter }

    var isDown: Bool { downAt != nil }

    /// When `advance(to:)` turns the press into a hold, while it may.
    var nextDeadline: TimeInterval? {
        guard let downAt, !holding else { return nil }
        return downAt + holdAfter
    }

    /// The button went down. Nothing while it's already down (a key repeat).
    mutating func press(at time: TimeInterval) -> [SiriPhase] {
        guard downAt == nil else { return [] }
        downAt = time
        holding = false
        return [.down]
    }

    /// The hold, once it's due.
    mutating func advance(to time: TimeInterval) -> [SiriPhase] {
        guard let deadline = nextDeadline, deadline <= time + 0.001 else { return [] }
        holding = true
        return [.hold]
    }

    /// The button came up: a tap, or the end of a hold. A timer that came late still gives the hold first.
    mutating func release(at time: TimeInterval) -> [SiriPhase] {
        guard downAt != nil else { return [] }
        let phases = advance(to: time)
        let held = holding
        downAt = nil
        holding = false
        return phases + [held ? .release : .tap]
    }

    /// The input went away while the button was down.
    mutating func reset() -> [SiriPhase] {
        guard downAt != nil else { return [] }
        downAt = nil
        holding = false
        return [.cancel]
    }
}

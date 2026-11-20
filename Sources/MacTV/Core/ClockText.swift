import Foundation

/// 播放时间、时长写成"3:07"，一小时以上"1:02:03"（哔哩哔哩、网易云、影片都用这一个）
func clockText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    let h = total / 3600, m = total % 3600 / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// The time of day as Mac TV's clocks show it (the status row, the screen saver), 12- or 24-hour as
/// Settings › General › 24-Hour Time says, whatever this Mac's own setting. Put together by hand: a
/// date formatter would turn "h" into "H" when the Mac is set to 24-hour time.
@MainActor
enum TimeOfDay {
    private static let symbols: (am: String, pm: String) = {
        let formatter = DateFormatter()
        return (formatter.amSymbol, formatter.pmSymbol)
    }()

    /// "23:32", or "11:32 PM" (`meridiem` false leaves out the AM / PM, as the lock-screen clock does).
    static func text(_ date: Date, twentyFour: Bool, meridiem: Bool = true, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        if twentyFour { return String(format: "%02d:%02d", hour, minute) }
        let time = String(format: "%d:%02d", hour % 12 == 0 ? 12 : hour % 12, minute)
        return meridiem ? "\(time) \(hour < 12 ? symbols.am : symbols.pm)" : time
    }
}

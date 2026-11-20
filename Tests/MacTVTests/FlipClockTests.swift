import Foundation
import Testing
@testable import MacTV

/// 屏保翻页时钟上写的字
@Suite(.timeLimit(.minutes(1)))
struct FlipClockTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: hour, minute: minute))!
    }

    @Test
    func twentyFourHourPadsTheHour() {
        let time = FlipClockTime(at(9, 5), twentyFour: true, calendar: calendar)
        #expect(time == FlipClockTime(hour: "09", minute: "05", meridiem: nil))
        #expect(FlipClockTime(at(0, 0), twentyFour: true, calendar: calendar).hour == "00")
    }

    @Test
    func twelveHourShowsMeridiemAndNoZero() {
        #expect(FlipClockTime(at(9, 5), twentyFour: false, calendar: calendar) == FlipClockTime(hour: "9", minute: "05", meridiem: "AM"))
        #expect(FlipClockTime(at(0, 30), twentyFour: false, calendar: calendar) == FlipClockTime(hour: "12", minute: "30", meridiem: "AM"))
        #expect(FlipClockTime(at(12, 0), twentyFour: false, calendar: calendar) == FlipClockTime(hour: "12", minute: "00", meridiem: "PM"))
        #expect(FlipClockTime(at(21, 47), twentyFour: false, calendar: calendar) == FlipClockTime(hour: "9", minute: "47", meridiem: "PM"))
    }

    /// Fliqlo's places: AM at the top-left of the hour plate, PM at the bottom-left.
    @Test
    func amSitsAtTheTopAndPMAtTheBottom() {
        #expect(FlipClockTime(at(7, 27), twentyFour: false, calendar: calendar).meridiemAtTop)
        #expect(FlipClockTime(at(0, 5), twentyFour: false, calendar: calendar).meridiemAtTop)
        #expect(!FlipClockTime(at(12, 0), twentyFour: false, calendar: calendar).meridiemAtTop)
        #expect(!FlipClockTime(at(19, 27), twentyFour: false, calendar: calendar).meridiemAtTop)
        #expect(!FlipClockTime(at(7, 27), twentyFour: true, calendar: calendar).meridiemAtTop)
    }
}

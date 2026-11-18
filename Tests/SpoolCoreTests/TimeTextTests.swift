import Foundation
import Testing
@testable import SpoolCore

private let berlin = TimeZone(identifier: "Europe/Berlin")!

private func berlinDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = berlin
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

@Test func timeFormatsPerLocale() {
    let d = berlinDate(2026, 11, 10, 15, 40)
    #expect(TimeText.time(d, locale: Locale(identifier: "uk_UA"), timeZone: berlin) == "15:40")
    #expect(TimeText.time(d, locale: Locale(identifier: "de_DE"), timeZone: berlin) == "15:40")
    let us = TimeText.time(d, locale: Locale(identifier: "en_US"), timeZone: berlin)
    #expect(us.contains("3:40"))
    #expect(us.contains("PM"))
}

@Test func dayAndTimeIncludesWeekday() {
    let monday = berlinDate(2026, 11, 9, 9, 0)
    #expect(TimeText.dayAndTime(monday, locale: Locale(identifier: "en_US"), timeZone: berlin).contains("Mon"))
    #expect(TimeText.dayAndTime(monday, locale: Locale(identifier: "uk_UA"), timeZone: berlin).contains("пн"))
}

@Test func countdownFormats() {
    let a = berlinDate(2026, 11, 10, 14, 23)
    #expect(TimeText.countdown(from: a, to: berlinDate(2026, 11, 10, 16, 10)) == "1:47")
    #expect(TimeText.countdown(from: a, to: berlinDate(2026, 11, 10, 14, 35)) == "0:12")
    #expect(TimeText.countdown(from: a, to: berlinDate(2026, 11, 10, 14, 0)) == "0:00")
}

@Test func countdownFromMinutes() {
    #expect(TimeText.countdown(minutes: 107) == "1:47")
    #expect(TimeText.countdown(minutes: 5) == "0:05")
    #expect(TimeText.countdown(minutes: 600) == "10:00")
    #expect(TimeText.countdown(minutes: 0) == "0:00")
    #expect(TimeText.countdown(minutes: -3) == "0:00")
}

@Test func dateAndTimeTellsTheWeekEndsApart() {
    // A weekly window from Thursday 09:00 to the next Thursday 09:00.
    let start = berlinDate(2026, 11, 5, 9, 0)
    let reset = berlinDate(2026, 11, 12, 9, 0)
    for id in ["en_US", "uk_UA"] {
        let locale = Locale(identifier: id)
        let a = TimeText.dateAndTime(start, locale: locale, timeZone: berlin)
        let b = TimeText.dateAndTime(reset, locale: locale, timeZone: berlin)
        #expect(a != b)
        #expect(a.contains("5") && b.contains("12"))
        #expect(a.contains("9:00") && b.contains("9:00"))
    }
    let us = TimeText.dateAndTime(reset, locale: Locale(identifier: "en_US"), timeZone: berlin)
    #expect(us.contains("Nov"))
    #expect(us.contains("AM"))
    #expect(TimeText.dateAndTime(reset, locale: Locale(identifier: "uk_UA"), timeZone: berlin).contains("09:00"))
}

import Foundation

/// The home page's "Coming up": real meetings that haven't finished, within the next week, grouped by day.
public enum UpcomingMeetings {
    public static let daysAhead = 7

    public struct Day: Equatable, Sendable {
        public let date: Date
        public let events: [CalendarEvent]
    }

    /// A meeting already under way counts as today's.
    public static func days(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> [Day] {
        let horizon = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
        let kept = events.filter { $0.isMeeting && $0.end > now && $0.start < horizon }.sorted { $0.start < $1.start }
        var days: [Day] = []
        for event in kept {
            let day = calendar.startOfDay(for: max(event.start, now))
            if let last = days.last, last.date == day {
                days[days.count - 1] = Day(date: day, events: last.events + [event])
            } else {
                days.append(Day(date: day, events: [event]))
            }
        }
        return days
    }

    /// "Today", "Tomorrow", else the weekday and date ("Monday 3 Nov").
    public static func label(for day: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        return formatter.string(from: day)
    }
}

/// Join was pressed in Lyra: until the meeting ends, the next meeting app to take the mic starts recording without
/// the Allow panel — the one case where recording starts on its own. Used once.
public struct PendingJoin: Equatable, Sendable {
    public let title: String
    public let until: Date

    public init(title: String, until: Date) {
        self.title = title
        self.until = until
    }

    /// The title to record under if the join still stands at `now`.
    public func claim(now: Date) -> String? { now < until ? title : nil }
}

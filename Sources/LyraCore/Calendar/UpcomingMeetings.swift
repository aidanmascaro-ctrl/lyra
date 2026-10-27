import Foundation

/// The home page's "Coming up": real meetings that haven't finished, within the next week, grouped by day.
public enum UpcomingMeetings {
    public static let daysAhead = 7

    public struct Day: Equatable, Sendable {
        public let date: Date
        public let events: [CalendarEvent]
    }

    /// Every account's events as one list. A meeting in two calendars (same title and start) shows once, keeping
    /// the copy with a call link.
    public static func merged(_ lists: [[CalendarEvent]]) -> [CalendarEvent] {
        var seen: [String: Int] = [:]
        var result: [CalendarEvent] = []
        for event in lists.joined() {
            let key = event.title.lowercased() + "|" + String(event.start.timeIntervalSince1970)
            if let index = seen[key] {
                if result[index].joinURL == nil, event.joinURL != nil { result[index] = event }
            } else {
                seen[key] = result.count
                result.append(event)
            }
        }
        return result
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

/// Join was pressed in Lyra on a meeting about to start or under way: for the next 15 minutes (never past the
/// meeting's end), the next meeting app to take the mic starts recording without the Allow panel — the one case
/// where recording starts on its own. Used once.
public struct PendingJoin: Equatable, Sendable {
    /// How long a Join stays armed, and how early before the start Join arms at all.
    public static let window: TimeInterval = 15 * 60

    public let title: String
    public let armedAt: Date
    public let until: Date

    /// Nil when the meeting is further off than the window, has ended, or has no call link.
    public init?(event: CalendarEvent, now: Date) {
        guard Self.canArm(event, now: now) else { return nil }
        title = event.title.isEmpty ? "Meeting" : event.title
        armedAt = now
        until = min(event.end, now.addingTimeInterval(Self.window))
    }

    public static func canArm(_ event: CalendarEvent, now: Date) -> Bool {
        event.joinURL != nil && now < event.end && event.start.timeIntervalSince(now) <= window
    }

    public func isOpen(at now: Date) -> Bool { armedAt <= now && now < until }

    /// The title to record under if the join still stands at `now`.
    public func claim(now: Date) -> String? { isOpen(at: now) ? title : nil }
}

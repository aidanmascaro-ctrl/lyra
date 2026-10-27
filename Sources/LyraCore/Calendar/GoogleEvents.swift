import Foundation

/// Reads the Google Calendar API's `events.list` answer into `CalendarEvent`s. Cancelled events are dropped.
public enum GoogleEvents {
    public static func parse(_ data: Data, timeZone: TimeZone = .current) throws -> [CalendarEvent] {
        let list = try JSONDecoder().decode(EventList.self, from: data)
        return list.items.compactMap { event(from: $0, timeZone: timeZone) }
    }

    private static func event(from item: Item, timeZone: TimeZone) -> CalendarEvent? {
        guard item.status != "cancelled",
              let start = date(item.start, timeZone: timeZone), let end = date(item.end, timeZone: timeZone) else { return nil }
        let attendees = item.attendees ?? []
        let entryURIs = (item.conferenceData?.entryPoints ?? []).filter { $0.entryPointType == "video" }.compactMap(\.uri)
        return CalendarEvent(
            id: item.id,
            title: item.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            start: start, end: end,
            isAllDay: item.start.dateTime == nil,
            otherAttendees: attendees.filter { $0.isSelf != true && $0.resource != true }.count,
            declined: attendees.contains { $0.isSelf == true && $0.responseStatus == "declined" },
            joinURL: JoinLink.find(conferenceURIs: entryURIs, hangoutLink: item.hangoutLink,
                                   location: item.location, description: item.description))
    }

    private static func date(_ time: EventTime, timeZone: TimeZone) -> Date? {
        if let stamp = time.dateTime {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: stamp) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: stamp)
        }
        guard let day = time.date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    private struct EventList: Decodable {
        let items: [Item]
        init(from decoder: Decoder) throws {
            items = try decoder.container(keyedBy: Keys.self).decodeIfPresent([Item].self, forKey: .items) ?? []
        }
        enum Keys: String, CodingKey { case items }
    }

    private struct Item: Decodable {
        let id: String
        let status: String?
        let summary: String?
        let location: String?
        let description: String?
        let hangoutLink: String?
        let start: EventTime
        let end: EventTime
        let attendees: [Attendee]?
        let conferenceData: Conference?
    }

    private struct EventTime: Decodable {
        let dateTime: String?
        let date: String?
    }

    private struct Attendee: Decodable {
        let isSelf: Bool?
        let resource: Bool?
        let responseStatus: String?
        enum CodingKeys: String, CodingKey { case isSelf = "self", resource, responseStatus }
    }

    private struct Conference: Decodable { let entryPoints: [EntryPoint]? }
    private struct EntryPoint: Decodable {
        let entryPointType: String?
        let uri: String?
    }
}

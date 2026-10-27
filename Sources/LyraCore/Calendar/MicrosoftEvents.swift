import Foundation

/// Reads Microsoft Graph's `calendarView` (Outlook / Microsoft 365, work or personal) into `CalendarEvent`s.
/// Times are asked for in UTC; cancelled events are dropped.
public enum MicrosoftEvents {
    static let pageSize = 100

    public static func request(from start: Date, to end: Date, token: String) -> URLRequest {
        let stamp = ISO8601DateFormatter()
        var parts = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendarView")!
        parts.queryItems = [
            .init(name: "startDateTime", value: stamp.string(from: start)),
            .init(name: "endDateTime", value: stamp.string(from: end)),
            .init(name: "$top", value: String(pageSize)),
            .init(name: "$orderby", value: "start/dateTime"),
            .init(name: "$select", value: "subject,start,end,isAllDay,isCancelled,attendees,organizer,isOrganizer,onlineMeeting,location,body,responseStatus"),
        ]
        return page(parts.url!, token: token)
    }

    /// A follow-on page (`@odata.nextLink`), with the same headers.
    public static func page(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(#"outlook.timezone="UTC", outlook.body-content-type="text""#, forHTTPHeaderField: "Prefer")
        return request
    }

    /// One page of events, and the next page's URL if there is one. `selfEmail` keeps Aidan out of the people count.
    public static func parse(_ data: Data, selfEmail: String) throws -> (events: [CalendarEvent], next: URL?) {
        let page = try JSONDecoder().decode(Page.self, from: data)
        let me = selfEmail.lowercased()
        return (page.value.compactMap { event(from: $0, me: me) }, page.nextLink.flatMap(URL.init(string:)))
    }

    private static func event(from item: Item, me: String) -> CalendarEvent? {
        guard item.isCancelled != true, let start = date(item.start), let end = date(item.end) else { return nil }
        let organizer = item.organizer?.emailAddress?.address?.lowercased()
        var people = Set((item.attendees ?? []).filter { $0.type != "resource" }.compactMap { $0.emailAddress?.address?.lowercased() })
        if item.isOrganizer == true { organizer.map { _ = people.remove($0) } } else if let organizer { people.insert(organizer) }
        people.remove(me)
        return CalendarEvent(
            id: item.id,
            title: item.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            start: start, end: end,
            isAllDay: item.isAllDay == true,
            otherAttendees: people.count,
            declined: item.responseStatus?.response == "declined",
            joinURL: JoinLink.find(conferenceURIs: [item.onlineMeeting?.joinUrl].compactMap { $0 }, hangoutLink: nil,
                                   location: item.location?.displayName, description: item.body?.content))
    }

    /// "2026-10-28T01:00:00.0000000" in the zone named beside it (UTC, as asked for).
    private static func date(_ time: Time) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = time.timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(time.dateTime.prefix(19)))
    }

    private struct Page: Decodable {
        let value: [Item]
        let nextLink: String?
        enum CodingKeys: String, CodingKey { case value, nextLink = "@odata.nextLink" }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decodeIfPresent([Item].self, forKey: .value) ?? []
            nextLink = try container.decodeIfPresent(String.self, forKey: .nextLink)
        }
    }

    private struct Item: Decodable {
        let id: String
        let subject: String?
        let start: Time
        let end: Time
        let isAllDay: Bool?
        let isCancelled: Bool?
        let isOrganizer: Bool?
        let attendees: [Attendee]?
        let organizer: Person?
        let onlineMeeting: OnlineMeeting?
        let location: Location?
        let body: Body?
        let responseStatus: Response?
    }

    private struct Time: Decodable {
        let dateTime: String
        let timeZone: String?
    }

    private struct Attendee: Decodable {
        let type: String?
        let emailAddress: Address?
    }

    private struct Person: Decodable { let emailAddress: Address? }
    private struct Address: Decodable { let address: String? }
    private struct OnlineMeeting: Decodable { let joinUrl: String? }
    private struct Location: Decodable { let displayName: String? }
    private struct Body: Decodable { let content: String? }
    private struct Response: Decodable { let response: String? }
}

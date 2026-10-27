import Foundation

/// One event from Aidan's calendar, reduced to what the home page and Join need.
public struct CalendarEvent: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// Invited people other than Aidan (meeting rooms not counted).
    public let otherAttendees: Int
    /// Aidan said no to it.
    public let declined: Bool
    /// The Zoom / Meet / Teams / Webex link, if there is one.
    public let joinURL: URL?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                otherAttendees: Int = 0, declined: Bool = false, joinURL: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.otherAttendees = otherAttendees
        self.declined = declined
        self.joinURL = joinURL
    }

    /// A real meeting rather than a personal reminder: timed, not declined, and someone else is invited or there is a call link.
    public var isMeeting: Bool { !isAllDay && !declined && (otherAttendees > 0 || joinURL != nil) }

    public func isUnderWay(at now: Date) -> Bool { start <= now && now < end }
}

/// A plain-English problem talking to Google, shown as one line on the home page.
public enum GoogleCalendarError: LocalizedError, Equatable {
    case notAClientFile
    case webClient
    case signInRefused(String)
    case signedOut
    case apiDisabled
    case badResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .notAClientFile: "That file isn't a Google sign-in file. Pick the JSON downloaded from Clients in Google Cloud Console."
        case .webClient: "That sign-in file is for a Web app. In Google Cloud Console create a Desktop app client and download its JSON."
        case .signInRefused(let reason): "Google sign-in didn't finish (\(reason))."
        case .signedOut: "Google signed Lyra out. Reconnect Google Calendar."
        case .apiDisabled: "The Google Calendar API is off for the Lyra project. Turn it on in Google Cloud Console."
        case .badResponse(let status): "Google Calendar answered with an error (\(status))."
        }
    }
}

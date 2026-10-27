import Foundation

/// One event from one of Aidan's calendars, reduced to what the home page and Join need.
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

    /// The same event under an id unique across accounts (two calendars can use the same event id).
    public func inAccount(_ accountID: String) -> CalendarEvent {
        CalendarEvent(id: accountID + "|" + id, title: title, start: start, end: end, isAllDay: isAllDay,
                      otherAttendees: otherAttendees, declined: declined, joinURL: joinURL)
    }
}

/// A plain-English problem with a calendar, shown as one line on the home page.
public enum CalendarError: LocalizedError, Equatable {
    case notAClientFile
    case webClient
    case notAnApplicationID
    case badClient
    case signInRefused(String)
    case needsAdmin
    case signedOut
    case apiDisabled
    case badResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .notAClientFile: "That file isn't a Google sign-in file. Pick the JSON downloaded from Clients in Google Cloud Console."
        case .webClient: "That sign-in file is for a Web app. In Google Cloud Console create a Desktop app client and download its JSON."
        case .notAnApplicationID: "That doesn't look like an Application (client) ID. Copy the ID that looks like 1a2b3c4d-… from App registrations."
        case .badClient: "The provider didn't accept Lyra's app details. Use “Change app details…” in the Coming up menu."
        case .signInRefused(let reason): "Sign-in didn't finish (\(reason))."
        case .needsAdmin: "This work account needs its IT admin to allow Lyra to read calendars."
        case .signedOut: "Lyra was signed out. Reconnect to see these meetings again."
        case .apiDisabled: "The Google Calendar API is off for the Lyra project. Turn it on in Google Cloud Console."
        case .badResponse(let status): "The calendar answered with an error (\(status))."
        }
    }
}

import Foundation

/// Finds the video-call link in a calendar event: Google's own conference fields first, then any known call link
/// written in the location or description (Zoom invites usually put it there).
public enum JoinLink {
    static let callHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]

    public static func find(conferenceURIs: [String], hangoutLink: String?, location: String?, description: String?) -> URL? {
        let direct = (conferenceURIs + [hangoutLink].compactMap { $0 }).compactMap(URL.init(string:))
        if let first = direct.first(where: isCall) { return first }
        for text in [location, description].compactMap({ $0 }) {
            if let link = links(in: text).first(where: isCall) { return link }
        }
        return nil
    }

    /// Every call service has a web client, so a browser can be where the call runs.
    static let browsers = ["com.google.Chrome", "com.apple.Safari", "com.apple.WebKit", "company.thebrowser",
                           "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser", "com.operasoftware", "com.vivaldi"]

    /// Bundle-ID prefixes of the apps a call link opens in: the service's own app, or a browser.
    public static func apps(for url: URL) -> [String] {
        let host = url.host?.lowercased() ?? ""
        let own: [String] = if host == "zoom.us" || host.hasSuffix(".zoom.us") { ["us.zoom"] }
            else if host.hasPrefix("teams.") { ["com.microsoft.teams"] }
            else if host.hasSuffix("webex.com") { ["Cisco-Systems.Spark", "com.webex", "com.cisco"] }
            else { [] }
        return own + browsers
    }

    public static func isCall(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        return callHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        // Descriptions arrive as HTML: tags would glue onto the link.
        let plain = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).compactMap(\.url)
    }
}

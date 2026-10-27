import CryptoKit
import Foundation

/// Where Aidan's calendars live. Each signs in the same way (installed-app OAuth: browser consent → code on a
/// loopback URL → tokens) and asks only to read calendars.
public enum CalendarProvider: String, Codable, CaseIterable, Sendable {
    case google, microsoft

    public var name: String { self == .google ? "Google" : "Microsoft" }

    var authEndpoint: URL {
        URL(string: self == .google ? "https://accounts.google.com/o/oauth2/v2/auth"
            : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
    }

    var tokenEndpoint: URL {
        URL(string: self == .google ? "https://oauth2.googleapis.com/token"
            : "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
    }

    /// `openid email`: the token answer then says which account it is, so two accounts can be told apart.
    public var scope: String {
        self == .google ? "openid email https://www.googleapis.com/auth/calendar.readonly"
            : "openid profile email offline_access https://graph.microsoft.com/Calendars.Read"
    }

    /// Google desktop clients take any 127.0.0.1 port; Microsoft matches the registered `http://localhost`, any port.
    public var redirectHost: String { self == .google ? "127.0.0.1" : "localhost" }

    var extraAuthParameters: [URLQueryItem] {
        switch self {
        // A refresh token, so Aidan signs in once rather than every hour.
        case .google: [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")]
        // Lets him pick the work or the personal account each time he adds one.
        case .microsoft: [.init(name: "response_mode", value: "query"), .init(name: "prompt", value: "select_account")]
        }
    }
}

/// The app Aidan registered with a provider. Google's desktop client comes with a (not really confidential) client
/// secret; Microsoft's public client has none and must not send one.
public struct OAuthClient: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Reads Google's downloaded `client_secret_….json`: `{"installed": {"client_id", "client_secret", …}}`.
    public static func google(clientJSON data: Data) throws -> OAuthClient {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CalendarError.notAClientFile }
        if root["web"] != nil { throw CalendarError.webClient }
        guard let installed = root["installed"] as? [String: Any],
              let id = installed["client_id"] as? String, let password = installed["client_secret"] as? String,
              !id.isEmpty, !password.isEmpty else { throw CalendarError.notAClientFile }
        return OAuthClient(clientID: id, clientSecret: password)
    }

    /// The "Application (client) ID" copied from Microsoft's App registrations page.
    public static func microsoft(applicationID text: String) throws -> OAuthClient {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { throw CalendarError.notAnApplicationID }
        return OAuthClient(clientID: id.lowercased())
    }

    /// Form fields naming this client to a token endpoint.
    var tokenFields: [(String, String)] {
        [("client_id", clientID)] + (clientSecret.map { [("client_secret", $0)] } ?? [])
    }
}

public struct OAuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// PKCE (RFC 7636): proves the code coming back to the loopback listener was asked for by this Lyra.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func make() -> PKCE { PKCE(verifier: randomToken()) }

    public static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuth {
    public static func authURL(_ provider: CalendarProvider, client: OAuthClient, redirect: URL, pkce: PKCE, state: String) -> URL {
        var parts = URLComponents(url: provider.authEndpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: provider.scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ] + provider.extraAuthParameters
        return parts.url!
    }

    /// The code from the browser's request to the loopback listener (`/?state=…&code=…`).
    public static func code(fromCallback target: String, state: String) throws -> String {
        let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw refusal(error, description: value("error_description") ?? "") }
        guard value("state") == state else { throw CalendarError.signInRefused("an unexpected answer came back") }
        guard let code = value("code"), !code.isEmpty else { throw CalendarError.signInRefused("no code came back") }
        return code
    }

    public static func codeRequest(_ provider: CalendarProvider, client: OAuthClient, code: String, pkce: PKCE, redirect: URL) -> URLRequest {
        tokenRequest(provider, client: client, [
            ("code", code), ("redirect_uri", redirect.absoluteString),
            ("grant_type", "authorization_code"), ("code_verifier", pkce.verifier),
        ])
    }

    public static func refreshRequest(_ provider: CalendarProvider, client: OAuthClient, refreshToken: String) -> URLRequest {
        tokenRequest(provider, client: client, [("refresh_token", refreshToken), ("grant_type", "refresh_token")])
    }

    /// The token endpoint's answer. Google's refresh answer has no new refresh token (the old one is kept);
    /// Microsoft sends a new one each time. `invalid_grant` means the sign-in was revoked or expired.
    public static func tokens(from data: Data, status: Int, now: Date, keepingRefresh previous: String? = nil) throws -> OAuthTokens {
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let error = body["error"] as? String { throw refusal(error, description: body["error_description"] as? String ?? "") }
        guard status == 200, let access = body["access_token"] as? String,
              let refresh = (body["refresh_token"] as? String) ?? previous else { throw CalendarError.badResponse(status) }
        let lifetime = (body["expires_in"] as? Double) ?? Double(body["expires_in"] as? String ?? "") ?? 3600
        return OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(lifetime))
    }

    /// Which account signed in, from the token answer's ID token. Read only to label the account; it came straight
    /// from the provider over HTTPS and is trusted for nothing else.
    public static func email(fromTokenAnswer data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = body["id_token"] as? String else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let json = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return (claims["email"] as? String) ?? (claims["preferred_username"] as? String)
    }

    private static func refusal(_ error: String, description: String) -> CalendarError {
        switch error {
        case "invalid_grant", "interaction_required": return .signedOut
        case "invalid_client", "unauthorized_client": return .badClient
        default:
            // Microsoft: AADSTS65001 / 90094 / 90095 — the organisation wants its admin to approve the app.
            if ["AADSTS65001", "AADSTS90094", "AADSTS90095", "admin approval"].contains(where: description.contains) { return .needsAdmin }
            return .signInRefused(error == "access_denied" ? "access was not allowed" : error)
        }
    }

    private static func tokenRequest(_ provider: CalendarProvider, client: OAuthClient, _ fields: [(String, String)]) -> URLRequest {
        let scope = provider == .microsoft ? [("scope", provider.scope)] : []
        var request = URLRequest(url: provider.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((client.tokenFields + fields + scope).map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }
}

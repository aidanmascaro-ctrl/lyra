import CryptoKit
import Foundation

/// The Desktop-app OAuth client Aidan made in Google Cloud Console (from its downloaded JSON).
public struct GoogleClient: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Reads Google's `client_secret_….json`: `{"installed": {"client_id", "client_secret", …}}`.
    public static func parse(clientJSON data: Data) throws -> GoogleClient {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GoogleCalendarError.notAClientFile }
        if root["web"] != nil { throw GoogleCalendarError.webClient }
        guard let installed = root["installed"] as? [String: Any],
              let id = installed["client_id"] as? String, let secret = installed["client_secret"] as? String,
              !id.isEmpty, !secret.isEmpty else { throw GoogleCalendarError.notAClientFile }
        return GoogleClient(clientID: id, clientSecret: secret)
    }
}

public struct GoogleTokens: Codable, Equatable, Sendable {
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

/// Google's installed-app sign-in: browser consent → code on a loopback URL → tokens. Read-only calendar access.
public enum GoogleAuth {
    public static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    public static func authURL(client: GoogleClient, redirect: URL, pkce: PKCE, state: String) -> URL {
        var parts = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // A refresh token, so Aidan signs in once rather than every hour.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return parts.url!
    }

    /// The code from the browser's request to the loopback listener (`/?state=…&code=…`).
    public static func code(fromCallback target: String, state: String) throws -> String {
        let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw GoogleCalendarError.signInRefused(error == "access_denied" ? "access was not allowed" : error) }
        guard value("state") == state else { throw GoogleCalendarError.signInRefused("an unexpected answer came back") }
        guard let code = value("code"), !code.isEmpty else { throw GoogleCalendarError.signInRefused("no code came back") }
        return code
    }

    public static func codeRequest(client: GoogleClient, code: String, pkce: PKCE, redirect: URL) -> URLRequest {
        tokenRequest([
            ("code", code), ("client_id", client.clientID), ("client_secret", client.clientSecret),
            ("redirect_uri", redirect.absoluteString), ("grant_type", "authorization_code"), ("code_verifier", pkce.verifier),
        ])
    }

    public static func refreshRequest(client: GoogleClient, refreshToken: String) -> URLRequest {
        tokenRequest([
            ("client_id", client.clientID), ("client_secret", client.clientSecret),
            ("refresh_token", refreshToken), ("grant_type", "refresh_token"),
        ])
    }

    /// The token endpoint's answer. A refresh answer has no new refresh token: the old one is kept.
    /// `invalid_grant` means the sign-in was revoked or expired.
    public static func tokens(from data: Data, status: Int, now: Date, keepingRefresh previous: String? = nil) throws -> GoogleTokens {
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let error = body["error"] as? String {
            throw error == "invalid_grant" ? GoogleCalendarError.signedOut : GoogleCalendarError.signInRefused(error)
        }
        guard status == 200, let access = body["access_token"] as? String,
              let refresh = (body["refresh_token"] as? String) ?? previous else { throw GoogleCalendarError.badResponse(status) }
        let lifetime = (body["expires_in"] as? Double) ?? 3600
        return GoogleTokens(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(lifetime))
    }

    private static func tokenRequest(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }
}

/// Aidan's Google client and tokens, in an owner-only file in Application Support (not the Keychain: the app is
/// ad-hoc signed, and the Keychain would ask again after every rebuild).
public struct GoogleAccountStore: Sendable {
    public struct Account: Codable, Equatable, Sendable {
        public var client: GoogleClient
        public var tokens: GoogleTokens?

        public init(client: GoogleClient, tokens: GoogleTokens? = nil) {
            self.client = client
            self.tokens = tokens
        }
    }

    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lyra/google.json")
    }

    /// Nil when Lyra was never connected.
    public func load() throws -> Account? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(Account.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ account: Account) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(account).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

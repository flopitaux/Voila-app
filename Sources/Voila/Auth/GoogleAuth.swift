import AppKit
import CryptoKit
import Foundation
import Observation

enum AuthError: LocalizedError {
    case missingClientID
    case stateMismatch
    case denied(String)
    case noRefreshToken
    case notSignedIn
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Enter your Google OAuth Client ID and secret first."
        case .stateMismatch: "The sign-in response didn't match. Please try again."
        case .denied(let reason): "Google sign-in was not completed (\(reason))."
        case .noRefreshToken: "Google didn't return a refresh token. Remove Voilà from your Google account's third-party access and try again."
        case .notSignedIn: "You're signed out. Connect your Google account again."
        case .server(let message): message
        }
    }
}

/// OAuth 2.0 for installed apps: browser + loopback redirect + PKCE.
@MainActor
@Observable
final class GoogleAuth {
    static let scope = "https://www.googleapis.com/auth/tasks"

    private(set) var clientID: String
    private(set) var clientSecret: String
    private(set) var isSignedIn: Bool
    private(set) var isSigningIn = false

    private var refreshToken: String?
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private var server: LoopbackServer?

    var hasCredentials: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    /// True when the OAuth client ships inside the app bundle, so users never have to enter it.
    let isPreconfigured: Bool

    init() {
        if let bundled = Self.bundledClient {
            clientID = bundled.id
            clientSecret = bundled.secret
            isPreconfigured = true
        } else {
            clientID = UserDefaults.standard.string(forKey: "googleClientID") ?? ""
            clientSecret = Keychain.get("clientSecret") ?? ""
            isPreconfigured = false
        }
        let storedRefresh = Keychain.get("refreshToken")
        refreshToken = storedRefresh
        isSignedIn = storedRefresh != nil
    }

    func saveCredentials(clientID: String, clientSecret: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.clientID, forKey: "googleClientID")
        Keychain.set(self.clientSecret, for: "clientSecret")
    }

    /// Reads `GoogleOAuthClient.json` from the app's Resources: either the file downloaded from
    /// Google Cloud Console (`{"installed": {"client_id", "client_secret"}}`) or a flat object.
    private static var bundledClient: (id: String, secret: String)? {
        guard let url = Bundle.main.url(forResource: "GoogleOAuthClient", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fields = (json["installed"] as? [String: Any]) ?? json
        guard let id = fields["client_id"] as? String, !id.isEmpty,
              let secret = fields["client_secret"] as? String, !secret.isEmpty else { return nil }
        return (id, secret)
    }

    func signIn() async throws {
        guard hasCredentials else { throw AuthError.missingClientID }
        isSigningIn = true
        defer { isSigningIn = false }

        let server = try LoopbackServer()
        self.server = server
        defer { server.stop(); self.server = nil }

        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        let verifier = Self.randomURLSafe(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(byteCount: 16)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)

        let params = try await server.waitForCallback()
        if let error = params["error"] { throw AuthError.denied(error) }
        guard params["state"] == state, let code = params["code"] else { throw AuthError.stateMismatch }

        let token = try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = token.refresh_token else { throw AuthError.noRefreshToken }
        refreshToken = refresh
        Keychain.set(refresh, for: "refreshToken")
        accessToken = token.access_token
        expiry = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600))
        isSignedIn = true
    }

    func cancelSignIn() {
        server?.stop()
    }

    func signOut() {
        if let token = refreshToken ?? accessToken {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(token.formEncoded)".utf8)
            Task.detached { _ = try? await URLSession.shared.data(for: request) }
        }
        refreshToken = nil
        accessToken = nil
        expiry = .distantPast
        Keychain.set(nil, for: "refreshToken")
        isSignedIn = false
    }

    /// Returns a valid access token, refreshing it when needed (concurrent callers share one refresh).
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, expiry.timeIntervalSinceNow > 60 { return accessToken }
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken else { throw AuthError.notSignedIn }

        let task = Task { () throws -> String in
            let token = try await tokenRequest([
                "client_id": clientID,
                "client_secret": clientSecret,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ])
            accessToken = token.access_token
            expiry = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600))
            return token.access_token
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch AuthError.server(let message)
                    where ["invalid_grant", "unauthorized_client", "invalid_client"].contains(where: message.contains) {
            // Token revoked, or the app now ships a different OAuth client: ask the user to reconnect.
            signOut()
            throw AuthError.notSignedIn
        }
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
    }

    private struct TokenError: Decodable {
        let error: String
        let error_description: String?
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if let err = try? JSONDecoder().decode(TokenError.self, from: data) {
                throw AuthError.server("\(err.error): \(err.error_description ?? "")")
            }
            throw AuthError.server("Token request failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

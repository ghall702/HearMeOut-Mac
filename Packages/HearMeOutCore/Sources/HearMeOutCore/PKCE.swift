import Foundation
import CryptoKit
import Security

/// RFC 7636 Proof Key for Code Exchange, used by the native Google sign-in flow.
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
        self.state = state
    }

    public static func generate() -> PKCE {
        PKCE(verifier: randomURLSafe(bytes: 48), state: randomURLSafe(bytes: 24))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        let ok = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "secure random failed")
        return base64URL(data)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Builds and parses the native sign-in URLs (backend addition: /native/connect + /api/public/v1/native/token).
public enum NativeAuthURLs {
    public static let callbackScheme = "hearmeout"
    public static let redirectURI = "hearmeout://auth/callback"

    public static func connectURL(origin: URL = HMOClient.defaultOrigin, pkce: PKCE, deviceName: String, selectAccount: Bool = true) -> URL {
        var c = URLComponents(url: origin.appendingPathComponent("native/connect"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client", value: "mac"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "device_name", value: String(deviceName.prefix(60))),
            URLQueryItem(name: "prompt", value: selectAccount ? "select_account" : nil),
        ].filter { $0.value != nil }
        return c.url!
    }

    public enum CallbackResult: Equatable, Sendable {
        case code(String)
        case denied
        case error(String)
    }

    /// Validates the callback (scheme, path and state) and extracts the code. Accepts query or fragment.
    public static func parseCallback(_ url: URL, expectedState: String) -> CallbackResult {
        guard url.scheme == callbackScheme, url.host == "auth" else { return .error("Unexpected callback address.") }
        var items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let fragment = url.fragment, var fc = URLComponents(string: "x:/") {
            fc.percentEncodedQuery = fragment
            items += fc.queryItems ?? []
        }
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard value("state") == expectedState else { return .error("The sign-in response didn't match this request. Please try again.") }
        if let e = value("error") { return e == "access_denied" ? .denied : .error(e) }
        guard let code = value("code"), !code.isEmpty else { return .error("The sign-in response was incomplete.") }
        return .code(code)
    }
}

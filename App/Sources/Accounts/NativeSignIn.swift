import AppKit
import AuthenticationServices
import CryptoKit
import HearMeOutCore

/// Signs in with Google through the existing Hear Me Out web sign-in, using the system browser
/// session (ASWebAuthenticationSession) with PKCE. The app never sees a Google password or token:
/// it receives a single-use code bound to its PKCE verifier and exchanges it for a per-Mac `hmo_` key.
@MainActor
final class NativeSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        case cancelled
        case notAvailable
        case server(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .notAvailable:
                return "Google sign-in for the Mac app isn't switched on for Hear Me Out yet. You can connect with an API key instead (Hear Me Out → Settings → API keys)."
            case .server(let m): return m
            }
        }
    }

    private var session: ASWebAuthenticationSession?
    let origin: URL

    init(origin: URL = HMOClient.defaultOrigin) {
        self.origin = origin
    }

    /// Checks that the server has the native sign-in endpoints (backend addition, see backend/README.md).
    static func isAvailable(origin: URL = HMOClient.defaultOrigin) async -> Bool {
        var req = URLRequest(url: origin.appendingPathComponent("api/public/v1/native/config"))
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["enabled"] as? Bool == true
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }

    /// Runs the flow and returns the new key plus the Google profile the server reports.
    func signIn() async throws -> TokenExchangeResponse {
        guard await Self.isAvailable(origin: origin) else { throw Failure.notAvailable }
        let pkce = PKCE.generate()
        let url = NativeAuthURLs.connectURL(origin: origin, pkce: pkce, deviceName: AppInfo.deviceName)
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: NativeAuthURLs.callbackScheme) { url, error in
                if let url { cont.resume(returning: url); return }
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: Failure.cancelled); return }
                cont.resume(throwing: Failure.server(error?.localizedDescription ?? "Sign-in didn't complete."))
            }
            s.presentationContextProvider = self
            // Share cookies with the browser so you don't re-enter Google details for every account.
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            if !s.start() { cont.resume(throwing: Failure.server("Couldn't open the sign-in window.")) }
        }
        session = nil
        switch NativeAuthURLs.parseCallback(callback, expectedState: pkce.state) {
        case .denied: throw Failure.cancelled
        case .error(let m): throw Failure.server(m)
        case .code(let code):
            do {
                return try await HMOClient.exchangeNativeCode(code: code, verifier: pkce.verifier, deviceName: AppInfo.deviceName, origin: origin)
            } catch HMOError.http(403, _) {
                throw Failure.server("That Google account isn't authorised for Hear Me Out.")
            } catch HMOError.unauthorised {
                throw Failure.server("The sign-in code expired or was already used. Please try again.")
            }
        }
    }
}

/// Downloads and caches Google profile pictures on disk; falls back to initials when unavailable.
@MainActor
final class AvatarCache: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func image(for account: Account) -> NSImage? {
        if let i = images[account.id] { return i }
        let file = fileURL(account.id)
        if let i = NSImage(contentsOf: file) {
            images[account.id] = i
            return i
        }
        fetch(account)
        return nil
    }

    func fileURL(_ id: String) -> URL {
        let safe = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return AppPaths.avatars.appendingPathComponent("\(safe).img")
    }

    func refresh(_ account: Account) {
        images[account.id] = nil
        try? FileManager.default.removeItem(at: fileURL(account.id))
        fetch(account)
    }

    func remove(_ accountId: String) {
        images[accountId] = nil
        try? FileManager.default.removeItem(at: fileURL(accountId))
    }

    private func fetch(_ account: Account) {
        guard let s = account.avatarURL, let url = URL(string: s), url.scheme == "https", !inFlight.contains(account.id) else { return }
        inFlight.insert(account.id)
        let id = account.id
        let dest = fileURL(id)
        Task { @MainActor in
            defer { inFlight.remove(id) }
            guard let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 2_000_000, let img = NSImage(data: data) else { return }
            try? data.write(to: dest, options: .atomic)
            AppPaths.protect(dest)
            images[id] = img
        }
    }
}

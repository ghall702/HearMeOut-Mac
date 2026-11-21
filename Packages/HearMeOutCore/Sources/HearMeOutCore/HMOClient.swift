import Foundation

/// Errors from the Hear Me Out API, classified so the queue can decide whether to retry.
public enum HMOError: Error, Equatable, LocalizedError, Sendable {
    /// 401: the key was revoked or the session expired. The account must reconnect.
    case unauthorised
    /// The request never reached the server (offline, DNS, TLS, timeout).
    case network(String)
    /// 404 (or 405) — the endpoint or recording does not exist.
    case notFound(String)
    /// 409, e.g. `already_finalised`.
    case conflict(String)
    /// 429 / quota.
    case rateLimited(String)
    /// Any other HTTP failure.
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorised: return "Hear Me Out didn't accept this account's connection. Please reconnect it."
        case .network: return "Couldn't reach Hear Me Out. Your recording is safe and will be retried."
        case .notFound(let c): return c.isEmpty ? "That recording couldn't be found." : "Not found (\(c))."
        case .conflict(let c): return "The server reported a conflict (\(c))."
        case .rateLimited: return "Hear Me Out is busy. This will be retried shortly."
        case .http(let s, let c):
            if s >= 500 { return "Hear Me Out is having trouble right now (\(s)). This will be retried." }
            return c.isEmpty ? "Request failed (\(s))." : c
        case .badResponse(let m): return "Unexpected response from Hear Me Out (\(m))."
        }
    }

    /// Transient failures are retried automatically with backoff.
    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited: return true
        case .http(let s, _): return s >= 500 || s == 408
        default: return false
        }
    }
}

/// Abstracts URLSession so the client can be tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HMOError.badResponse("not HTTP") }
        return (data, http)
    }
}

/// Client for `https://hearmeout.george-hall.uk/api/public/v1`. One instance per account; it only
/// ever carries that account's key, which is what keeps accounts isolated.
public struct HMOClient: Sendable {
    public static let defaultOrigin = URL(string: "https://hearmeout.george-hall.uk")!

    public let origin: URL
    public let apiKey: String
    public let transport: HTTPTransport

    public init(apiKey: String, origin: URL = HMOClient.defaultOrigin, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.origin = origin
        self.transport = transport
    }

    public var apiBase: URL { origin.appendingPathComponent("api/public/v1") }

    // MARK: Endpoints

    /// POST /uploads — creates a pending recording and returns a direct-to-media-server ticket.
    public func createUpload(_ body: CreateUploadRequest) async throws -> UploadTicket {
        let raw: RawUploadTicket = try await call("POST", "uploads", body: body)
        return try raw.normalised()
    }

    /// POST /recordings/:id/upload-url — a fresh ticket for the same recording (no duplicate).
    public func reissueUpload(recordingId: String) async throws -> UploadTicket {
        let raw: RawUploadTicket = try await call("POST", "recordings/\(Self.escape(recordingId))/upload-url", body: [String: String]())
        return try raw.normalised()
    }

    /// POST /recordings/:id/finalize. Cloud transcription runs inside this request, so it can be slow.
    public func finalize(recordingId: String, _ body: FinalizeRequest, timeout: TimeInterval = 180) async throws -> FinalizeResponse {
        try await call("POST", "recordings/\(Self.escape(recordingId))/finalize", body: body, timeout: timeout)
    }

    /// GET /recordings — newest `recorded_at` first, at most 200.
    public func listRecordings() async throws -> [RemoteRecording] {
        let list: RecordingList = try await call("GET", "recordings", body: Optional<String>.none)
        return list.items
    }

    /// GET /recordings/:id — full row including the transcript.
    public func recording(id: String) async throws -> RemoteRecording {
        try await call("GET", "recordings/\(Self.escape(id))", body: Optional<String>.none)
    }

    /// GET /me — profile for this key (Mac backend addition; 404 on servers without it).
    public func me() async throws -> MeResponse {
        try await call("GET", "me", body: Optional<String>.none)
    }

    /// GET /recordings/:id/playback — short-lived signed audio URL for the owner (Mac backend addition).
    public func playbackURL(recordingId: String) async throws -> URL {
        let r: PlaybackResponse = try await call("GET", "recordings/\(Self.escape(recordingId))/playback", body: Optional<String>.none)
        guard let u = URL(string: r.url) else { throw HMOError.badResponse("playback url") }
        return u
    }

    /// POST /extension/signout — revokes the key in the Authorization header (works for any `hmo_` key).
    public func revokeKey() async throws {
        let _: [String: Bool] = try await call("POST", "extension/signout", body: [String: String]())
    }

    // MARK: Unauthenticated (sign-in)

    /// POST /native/token — exchanges a PKCE-protected authorisation code for a per-Mac API key.
    public static func exchangeNativeCode(code: String, verifier: String, deviceName: String,
                                          origin: URL = defaultOrigin, transport: HTTPTransport = URLSessionTransport()) async throws -> TokenExchangeResponse {
        let client = HMOClient(apiKey: "", origin: origin, transport: transport)
        let body = ["grant_type": "authorization_code", "code": code, "code_verifier": verifier, "device_name": deviceName]
        return try await client.call("POST", "native/token", body: body, authorised: false)
    }

    // MARK: Plumbing

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    func makeRequest<B: Encodable>(_ method: String, _ path: String, body: B?, timeout: TimeInterval, authorised: Bool) throws -> URLRequest {
        var req = URLRequest(url: apiBase.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorised { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body, method != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?, timeout: TimeInterval = 30, authorised: Bool = true) async throws -> T {
        let req = try makeRequest(method, path, body: body, timeout: timeout, authorised: authorised)
        let data: Data
        let resp: HTTPURLResponse
        do {
            (data, resp) = try await transport.send(req)
        } catch let e as HMOError {
            throw e
        } catch {
            throw HMOError.network(error.localizedDescription)
        }
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
        switch resp.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(T.self, from: data) } catch { throw HMOError.badResponse(String(describing: T.self)) }
        case 401: throw HMOError.unauthorised
        case 404, 405: throw HMOError.notFound(code)
        case 409: throw HMOError.conflict(code)
        case 429: throw HMOError.rateLimited(code)
        default: throw HMOError.http(resp.statusCode, code)
        }
    }
}

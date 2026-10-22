import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum Dreadcast {
    public static let version = "1.0.0"
    public static let repositoryURL = "https://github.com/enderwiggens/dreadcast-cli"
    /// NWS asks every client to identify itself with a way to reach its maintainers.
    public static let userAgent = "dreadcast-cli/\(version) (+\(repositoryURL))"
    /// The Dreadcast API used when none is configured: radar comes from it by default
    /// wherever it covers a place. `dread config set api-url off` turns it off.
    public static let apiBaseURL: URL? = URL(string: "https://api.dreadcast.app")
}

public enum DreadcastError: LocalizedError, Equatable, Sendable {
    case httpStatus(Int, host: String)
    /// The host answered 429, or did recently and asked to wait until `until`.
    case rateLimited(host: String, until: Date)
    case invalidResponse(String)
    case oversized(String)
    case unavailable(String)
    case notFound(String)
    case unsupportedRegion(String)
    case missingCredentials(String)
    case unsupportedPlatform(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let host): return "\(host) returned HTTP \(status)."
        case .rateLimited(let host, let until):
            let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
            return "\(host) asked for fewer requests; dreadcast will try again in \(minutes) min."
        case .invalidResponse(let source): return "\(source) returned a response dreadcast couldn’t read."
        case .oversized(let source): return "\(source) returned more data than expected."
        case .unavailable(let message): return message
        case .notFound(let message): return message
        case .unsupportedRegion(let message): return message
        case .missingCredentials(let message): return message
        case .unsupportedPlatform(let message): return message
        }
    }
}

/// The Dreadcast API's install token (dreadcast-server `docs/API.md#install-tokens`):
/// which requests carry it, and what happens when the API turns it down.
public protocol APICredential: Sendable {
    /// The token for a request to `url`, or nil to send none. Only the API's own host
    /// gets one, never a tile CDN or another provider.
    func token(for url: URL) async -> String?
    /// The API answered 401 to `token`: forget it.
    func refused(_ token: String) async
}

/// Remembers a host's `Retry-After` between runs, so a shell prompt, a tmux status line
/// and the app all wait it out instead of each asking again.
public protocol RequestThrottle: Sendable {
    func blockedUntil(host: String) -> Date?
    func block(host: String, until: Date)
}

/// A small URLSession wrapper with an identifying User-Agent, timeouts and size limits.
public struct HTTPClient: Sendable {
    public let session: URLSession
    public let userAgent: String
    /// When set, requests it names carry `Authorization: Bearer <token>`.
    public var credential: (any APICredential)?
    /// When set, a host that answered 429 isn't asked again until its `Retry-After` passes.
    public var throttle: (any RequestThrottle)?

    /// The longest wait a `Retry-After` can ask for, so a bad header can't stop a host for good.
    public static let longestRetryAfter: TimeInterval = 3600
    /// The wait after a 429 without `Retry-After`.
    public static let defaultRetryAfter: TimeInterval = 60

    public init(session: URLSession? = nil, userAgent: String = Dreadcast.userAgent) {
        if let session {
            self.session = session
        } else {
            // dreadcast keeps its own cache; avoid URLCache writing alongside it.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 45
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
        self.userAgent = userAgent
    }

    public func data(
        _ url: URL,
        method: String = "GET",
        accept: String? = nil,
        timeout: TimeInterval = 15,
        maximumBytes: Int = 8 * 1024 * 1024,
        source: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let label = source ?? url.host ?? "The service"
        let host = url.host?.lowercased() ?? label
        // The Dreadcast API limits its tile endpoints apart from the rest, so a wait for
        // satellite tiles doesn't hold up the weather.
        let scope = url.path.hasPrefix("/v2/") && url.path.hasSuffix(".png") ? host + url.path : host
        if let throttle, let until = throttle.blockedUntil(host: scope), until > Date() {
            throw DreadcastError.rateLimited(host: host, until: until)
        }
        let token = await credential?.token(for: url)
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        #if canImport(FoundationNetworking)
        // On Linux, cancelling a URLSession task can race its own completion and crash
        // ("a task that in not in the registry"), and Swift cancels a request whenever a
        // sibling fails. There each request runs to its end, bounded by its timeout.
        let session = self.session
        let (data, status, retryAfter) = try await Task { () async throws -> (Data, Int?, String?) in
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return (data, http?.statusCode, http?.value(forHTTPHeaderField: "Retry-After"))
        }.value
        #else
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
        #endif
        guard let status else { throw DreadcastError.invalidResponse(label) }
        if status == 401, let token, let credential {
            // A token the API no longer knows: drop it and ask again without one, which the
            // API always serves.
            await credential.refused(token)
            var anonymous = self
            anonymous.credential = nil
            return try await anonymous.data(url, method: method, accept: accept, timeout: timeout,
                                            maximumBytes: maximumBytes, source: source)
        }
        if status == 429 {
            let wait = Self.retryAfter(retryAfter, now: Date()) ?? Self.defaultRetryAfter
            let until = Date().addingTimeInterval(min(Self.longestRetryAfter, max(1, wait)))
            throttle?.block(host: scope, until: until)
            throw DreadcastError.rateLimited(host: host, until: until)
        }
        guard (200...299).contains(status) else {
            throw DreadcastError.httpStatus(status, host: url.host ?? label)
        }
        guard data.count <= maximumBytes else { throw DreadcastError.oversized(label) }
        return data
    }

    /// A `Retry-After` value in seconds: delay-seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value), seconds >= 0 { return TimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    public func json<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        accept: String? = "application/json",
        timeout: TimeInterval = 15,
        maximumBytes: Int = 8 * 1024 * 1024,
        source: String? = nil
    ) async throws -> T {
        let data = try await self.data(url, accept: accept, timeout: timeout, maximumBytes: maximumBytes, source: source)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DreadcastError.invalidResponse(source ?? url.host ?? "The service")
        }
    }
}

enum ISODate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

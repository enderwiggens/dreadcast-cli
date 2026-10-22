import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DreadcastKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The install token the CLI sends to the Dreadcast API (dreadcast-server
/// `docs/API.md#install-tokens`), so the API counts its limits per install rather than
/// per network. It is asked for the first time a command uses the API, with no sign-up,
/// and only ever adds allowance: without one, requests are served as before.
///
/// Tokens live in `install-token.json` in the config directory, owner-only, one per API
/// address, so a development server's never reaches production. They are never written
/// to config.json, the cache, logs or output, and only the API's own host receives one.
public actor InstallToken: APICredential {
    let api: URL
    let paths: Paths
    let file: URL
    let cache: DiskCache
    /// Asks for tokens, so it carries no credential of its own, and no throttle: a network
    /// out of tokens for the day must not hold up the rest of the API.
    let http: HTTPClient
    private var token: String?
    private var minting: Task<String?, Never>?

    /// The token format the API hands out; anything else is never sent.
    static let pattern = #"^dct_[A-Za-z0-9_-]{43}$"#
    /// How long to wait before asking again after the API turned a request down (an older
    /// server, or a network's tokens for the day), and after a network failure.
    static let refusedRetry: TimeInterval = 24 * 3600
    static let failedRetry: TimeInterval = 600
    static let retryKey = "install-token-retry"

    public init(api: URL, paths: Paths, cache: DiskCache, http: HTTPClient) {
        self.api = api
        self.paths = paths
        file = Self.file(paths)
        self.cache = cache
        var http = http
        http.credential = nil
        http.throttle = nil
        self.http = http
    }

    static func file(_ paths: Paths) -> URL { paths.configDirectory.appendingPathComponent("install-token.json") }

    /// The key a token is saved under: the API's scheme, host and port.
    static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? "")" + (url.port.map { ":\($0)" } ?? "")
    }

    static func valid(_ token: String?) -> String? {
        guard let token, token.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return token
    }

    // MARK: APICredential

    public func token(for url: URL) async -> String? {
        guard Self.origin(url) == Self.origin(api) else { return nil }
        if let token { return token }
        if let saved = Self.saved(file)[Self.origin(api)].flatMap(Self.valid) {
            token = saved
            return saved
        }
        if let minting { return await minting.value }
        let task = Task { await self.mint() }
        minting = task
        let minted = await task.value
        minting = nil
        return minted
    }

    public func refused(_ refusedToken: String) async {
        guard token == refusedToken || Self.saved(file)[Self.origin(api)] == refusedToken else { return }
        token = nil
        Self.update(file) { $0[Self.origin(api)] = nil }
    }

    // MARK: Asking for one

    struct Minted: Decodable { let token: String }

    /// A new token from POST /v1/installs, saved before it is used. Another dreadcast
    /// process asking at the same moment holds the lock, and this request goes without.
    func mint() async -> String? {
        // The app runs for hours: `install-token off` in another shell must stop it asking.
        guard ConfigStore.load(from: paths).installToken else { return nil }
        if let until = cache.read(Date.self, key: Self.retryKey)?.value, until > Date() { return nil }
        let lock = cache.directory.appendingPathComponent("install-token.lock").path
        let fd = open(lock, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        // It may have just been saved by the process that held the lock.
        if let saved = Self.saved(file)[Self.origin(api)].flatMap(Self.valid) {
            token = saved
            return saved
        }
        do {
            let data = try await http.data(api.appendingPathComponent("v1/installs"), method: "POST", accept: "application/json",
                                           timeout: 10, maximumBytes: 16 * 1024, source: "The Dreadcast API")
            guard let minted = Self.valid(try? JSONDecoder().decode(Minted.self, from: data).token) else {
                cache.write(Date().addingTimeInterval(Self.refusedRetry), key: Self.retryKey)
                return nil
            }
            guard Self.update(file, { $0[Self.origin(api)] = minted }) else { return nil }
            cache.remove(key: Self.retryKey)
            token = minted
            return minted
        } catch DreadcastError.httpStatus, DreadcastError.rateLimited {
            cache.write(Date().addingTimeInterval(Self.refusedRetry), key: Self.retryKey)
            return nil
        } catch {
            cache.write(Date().addingTimeInterval(Self.failedRetry), key: Self.retryKey)
            return nil
        }
    }

    /// Asks the API to delete this install, then forgets its token. The token is forgotten
    /// even when the API can't be reached.
    public func remove() async {
        let origin = Self.origin(api)
        if let saved = Self.saved(file)[origin].flatMap(Self.valid) {
            var request = URLRequest(url: api.appendingPathComponent("v1/installs/current"),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "DELETE"
            request.setValue(http.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer " + saved, forHTTPHeaderField: "Authorization")
            _ = try? await http.session.data(for: request)
        }
        token = nil
        Self.update(file) { $0[origin] = nil }
        cache.remove(key: Self.retryKey)
    }

    // MARK: The file

    static func saved(_ file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    /// Rewrites the file owner-only, through a temporary file, or deletes it once empty.
    @discardableResult
    static func update(_ file: URL, _ change: (inout [String: String]) -> Void) -> Bool {
        var values = saved(file)
        change(&values)
        guard !values.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return true
        }
        let directory = file.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil,
              let data = try? JSONEncoder().encode(values) else { return false }
        let temporary = directory.appendingPathComponent(".install-token-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return false
        }
        guard rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }
}

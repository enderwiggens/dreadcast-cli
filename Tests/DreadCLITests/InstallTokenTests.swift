import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import DreadcastKit
@testable import DreadCLI

/// The install token runs in the command suite, which owns the stub's shared routes.
extension CommandTests {
    static let installs = "api.dreadcast.app/v1/installs"
    static let issued = "dct_" + String(repeating: "A", count: 43)
    static let other = "dct_" + String(repeating: "B", count: 43)
    static let minted = #"{"token":"\#(issued)","install":{"client":"cli","created_at":"2026-10-05T18:30:00Z"},"limits":{"requests_per_minute":120}}"#

    /// A home whose CLI sends install tokens, as an installed one does.
    static func tokenHome() async throws -> [String: String] {
        var env = try await home()
        env["DREADCAST_CREDENTIAL_STORE"] = nil
        return env
    }

    static func tokenFile(_ env: [String: String]) -> URL {
        InstallToken.file(Paths.resolve(environment: env))
    }

    static func authorization(_ request: URLRequest) -> String? { request.value(forHTTPHeaderField: "Authorization") }

    @Test func anInstallTokenIsAskedForOnceAndSentOnlyToTheAPI() async throws {
        let env = try await Self.tokenHome()
        var routes = Self.online
        routes[Self.installs] = (201, Self.minted)

        let first = try await Self.run(["now", "--plain"], environment: env, routes: routes)
        #expect(first.code == .ok)
        let mints = StubProvider.seen.filter { $0.url?.path == "/v1/installs" }
        #expect(mints.count == 1)
        #expect(mints.first?.httpMethod == "POST")
        #expect(mints.first.map(Self.authorization) == .some(nil))
        let weather = StubProvider.seen.filter { $0.url?.host == "api.dreadcast.app" && $0.url?.path != "/v1/installs" }
        #expect(!weather.isEmpty)
        #expect(weather.allSatisfy { Self.authorization($0) == "Bearer " + Self.issued })
        #expect(StubProvider.seen.filter { $0.url?.host == "api.weather.gov" }.allSatisfy { Self.authorization($0) == nil })

        let file = Self.tokenFile(env)
        #expect(InstallToken.saved(file) == ["https://api.dreadcast.app": Self.issued])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let config = try String(contentsOf: Paths.resolve(environment: env).configFile, encoding: .utf8)
        #expect(!config.contains("dct_"))

        // A later run, once the weather is due again, reuses it.
        _ = try await Self.run(["now", "--plain"], environment: env, routes: routes, at: "2026-10-05T21:30:00Z")
        #expect(!StubProvider.seen.contains { $0.url?.path == "/v1/installs" })
        #expect(StubProvider.seen.contains { Self.authorization($0) == "Bearer " + Self.issued })

        let shown = try await Self.run(["config", "--plain"], environment: env, routes: [:])
        #expect(shown.out.contains("API token  on"))
        #expect(!shown.out.contains("dct_"))
        #expect(!(try await Self.run(["config", "--json"], environment: env, routes: [:])).out.contains("dct_"))
    }

    @Test func aRefusedTokenIsForgottenAndTheRequestGoesWithout() async throws {
        let env = try await Self.tokenHome()
        InstallToken.update(Self.tokenFile(env)) { $0["https://api.dreadcast.app"] = Self.other }
        var routes = Self.online
        routes[Self.installs] = (201, Self.minted)
        StubProvider.refusedToken = Self.other
        defer { StubProvider.refusedToken = nil }

        let result = try await Self.run(["now", "--plain"], environment: env, routes: routes)

        #expect(result.code == .ok)
        #expect(result.out.contains("71°F"))
        #expect(StubProvider.seen.contains { Self.authorization($0) == "Bearer " + Self.other })
        #expect(InstallToken.saved(Self.tokenFile(env))["https://api.dreadcast.app"] != Self.other)
    }

    @Test func aServerWithoutInstallTokensIsAskedAgainTomorrow() async throws {
        let env = try await Self.tokenHome()
        var routes = Self.online
        routes[Self.installs] = (404, #"{"error":{"code":"not_found","message":"x"}}"#)

        let first = try await Self.run(["now", "--plain"], environment: env, routes: routes)
        #expect(first.code == .ok)
        #expect(StubProvider.seen.filter { $0.url?.path == "/v1/installs" }.count == 1)
        #expect(StubProvider.seen.allSatisfy { Self.authorization($0) == nil })

        _ = try await Self.run(["now", "--plain"], environment: env, routes: routes)
        #expect(!StubProvider.seen.contains { $0.url?.path == "/v1/installs" })
        #expect(!FileManager.default.fileExists(atPath: Self.tokenFile(env).path))
    }

    @Test func turningTheInstallTokenOffDeletesIt() async throws {
        let env = try await Self.tokenHome()
        InstallToken.update(Self.tokenFile(env)) { $0["https://api.dreadcast.app"] = Self.issued }
        var routes = Self.online
        routes[Self.installs] = (201, Self.minted)
        routes["api.dreadcast.app/v1/installs/current"] = (204, "")

        let off = try await Self.run(["config", "set", "install-token", "off"], environment: env, routes: routes)
        #expect(off.code == .ok)
        let deletes = StubProvider.seen.filter { $0.httpMethod == "DELETE" }
        #expect(deletes.map { $0.url?.path } == ["/v1/installs/current"])
        #expect(deletes.first.map(Self.authorization) == "Bearer " + Self.issued)
        #expect(!FileManager.default.fileExists(atPath: Self.tokenFile(env).path))

        let now = try await Self.run(["now", "--plain"], environment: env, routes: routes)
        #expect(now.code == .ok)
        #expect(StubProvider.seen.allSatisfy { Self.authorization($0) == nil && $0.url?.path != "/v1/installs" })
        #expect(try await Self.run(["config", "--plain"], environment: env, routes: [:]).out.contains("API token  off"))
    }

    @Test func tokensBelongToTheirAPI() async throws {
        #expect(InstallToken.origin(URL(string: "http://localhost:3000")!) == "http://localhost:3000")
        #expect(InstallToken.origin(URL(string: "https://API.dreadcast.app/v1/x")!) == "https://api.dreadcast.app")
        #expect(InstallToken.valid(Self.issued) == Self.issued)
        #expect(InstallToken.valid("dct_short") == nil)
        #expect(InstallToken.valid(Self.issued + "\r\nX-Evil: 1") == nil)
        let token = InstallToken(api: URL(string: "https://api.dreadcast.app")!, paths: Paths.resolve(environment: try await Self.home()),
                                 cache: DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                                 http: HTTPClient())
        #expect(await token.token(for: URL(string: "https://dreadcast-radar.nyc3.cdn.digitaloceanspaces.com/mrms/x.png")!) == nil)
        #expect(await token.token(for: URL(string: "https://api.weather.gov/alerts")!) == nil)
    }
}

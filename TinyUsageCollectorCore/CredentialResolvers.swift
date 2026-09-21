import CryptoKit
import Foundation
import TinyUsageDomain

public struct LocalCredentialResolver: CredentialResolver {
    public typealias KeychainLookup = @Sendable (String) async -> String?
    private let environment: [String: String]
    private let homeDirectory: URL
    private let keychainLookup: KeychainLookup

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, keychainLookup: @escaping KeychainLookup = { _ in nil }) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.keychainLookup = keychainLookup
    }

    public func candidates(for source: UsageSourceDescriptor) async -> [CredentialCandidate] {
        switch source.family {
        case .claude: await claudeCandidates()
        case .codex: await codexCandidates()
        }
    }

    private func claudeCandidates() async -> [CredentialCandidate] {
        var result: [CredentialCandidate] = []
        if let value = await keychainLookup("Claude Code-credentials") { result.append(contentsOf: storedCandidates(value, origin: .keychain, tokenKeys: ["accessToken", "access_token", "token"])) }
        let claudeCredential = homeDirectory.appending(path: ".claude/.credentials.json")
        result.append(contentsOf: fileCandidates(claudeCredential, origin: .claudeCode, tokenKeys: ["accessToken", "access_token", "token"]))
        let desktop = homeDirectory.appending(path: "Library/Application Support/Claude/credentials.json")
        result.append(contentsOf: fileCandidates(desktop, origin: .claudeDesktop, tokenKeys: ["accessToken", "access_token", "token"]))
        if let value = environment["CLAUDE_CODE_OAUTH_TOKEN"] ?? environment["ANTHROPIC_AUTH_TOKEN"], let candidate = candidate(value, origin: .environment) { result.append(candidate) }
        return result.sorted { score($0, family: .claude) > score($1, family: .claude) }
    }

    private func codexCandidates() async -> [CredentialCandidate] {
        var result: [CredentialCandidate] = []
        if let value = await keychainLookup("Codex-auth") { result.append(contentsOf: storedCandidates(value, origin: .keychain, tokenKeys: ["access_token", "accessToken", "token"])) }
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? homeDirectory.appending(path: ".codex")
        result.append(contentsOf: fileCandidates(codexHome.appending(path: "auth.json"), origin: .codexHome, tokenKeys: ["access_token", "accessToken", "token"]))
        return result.sorted { score($0, family: .codex) > score($1, family: .codex) }
    }

    private func score(_ candidate: CredentialCandidate, family: ProviderFamily) -> Int {
        var value = candidate.origin == .keychain ? 40 : candidate.origin == .environment ? 5 : 20
        if family == .claude && candidate.scopes.contains(where: { $0.contains("user:profile") || $0.contains("usage") }) { value += 100 }
        if family == .claude && !candidate.scopes.isEmpty && !candidate.scopes.contains(where: { $0.contains("user:profile") || $0.contains("usage") }) { value -= 100 }
        if candidate.expiresAt.map({ $0 > .now }) ?? true { value += 10 }
        return value
    }

    private func fileCandidates(_ url: URL, origin: CredentialCandidate.Origin, tokenKeys: [String]) -> [CredentialCandidate] {
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var seen = Set<String>()
        return candidatesFromJSON(object, origin: origin, tokenKeys: tokenKeys).filter { seen.insert($0.generation).inserted }
    }

    private func storedCandidates(_ value: String, origin: CredentialCandidate.Origin, tokenKeys: [String]) -> [CredentialCandidate] {
        if let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            return candidatesFromJSON(object, origin: origin, tokenKeys: tokenKeys)
        }
        return candidate(value, origin: origin).map { [$0] } ?? []
    }

    private func candidatesFromJSON(_ object: Any, origin: CredentialCandidate.Origin, tokenKeys: [String]) -> [CredentialCandidate] {
        var results: [CredentialCandidate] = []
        if let dictionary = object as? [String: Any] {
            for key in tokenKeys {
                if let token = dictionary[key] as? String, let result = candidate(token, origin: origin, metadata: dictionary) { results.append(result) }
            }
            for value in dictionary.values {
                results.append(contentsOf: candidatesFromJSON(value, origin: origin, tokenKeys: tokenKeys))
            }
        } else if let array = object as? [Any] {
            for value in array { results.append(contentsOf: candidatesFromJSON(value, origin: origin, tokenKeys: tokenKeys)) }
        }
        return results
    }

    private func candidate(_ token: String, origin: CredentialCandidate.Origin, metadata: [String: Any] = [:]) -> CredentialCandidate? {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let scopes: Set<String>
        if let value = metadata["scope"] as? String { scopes = Set(value.split(separator: " ").map(String.init)) }
        else if let values = metadata["scopes"] as? [String] { scopes = Set(values) }
        else { scopes = [] }
        let expiry = Self.expiry(from: metadata["expires_at"] ?? metadata["expiresAt"] ?? metadata["expires"])
        let digest = SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let accountID = Self.accountID(from: metadata) ?? Self.accountID(fromJWT: token)
        return CredentialCandidate(secret: token, origin: origin, generation: digest, scopes: scopes, expiresAt: expiry, accountID: accountID)
    }

    private static func expiry(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        if let string = value as? String {
            if let raw = Double(string) { return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw) }
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    private static func accountID(from metadata: [String: Any]) -> String? {
        for key in ["account_id", "accountId", "workspace_id", "workspaceId", "organization_id", "organizationId"] {
            if let value = metadata[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func accountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return accountID(from: claims) ?? (claims["sub"] as? String)
    }
}

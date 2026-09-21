import Foundation
import TinyUsageDomain

public struct ClaudeSubscriptionConnector: UsageSourceConnector {
    public let descriptor = UsageSourceDescriptor(id: "claude.subscription", family: .claude, displayName: "Claude subscription", provenance: .privateProviderEndpoint, isExperimental: true)
    private let resolver: any CredentialResolver
    private let client: any CollectorHTTPClient
    private let endpoint: URL
    private let enabled: Bool

    public init(resolver: any CredentialResolver, client: any CollectorHTTPClient = URLSessionCollectorHTTPClient(), endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!, enabled: Bool) {
        self.resolver = resolver
        self.client = client
        self.endpoint = endpoint
        self.enabled = enabled
    }

    public func probe() async -> ProbeResult {
        guard enabled else { return .init(.disabled) }
        let candidates = await resolver.candidates(for: descriptor)
        return candidates.contains(where: { $0.expiresAt.map { $0 > .now } ?? true }) ? .init(.available) : .init(.missingCredential)
    }

    public func fetch(context: FetchContext) async throws -> SourceSnapshot {
        guard enabled else { throw ConnectorError.provider("Experimental Claude subscription source is disabled.") }
        let candidates = await resolver.candidates(for: descriptor).filter { $0.expiresAt.map { $0 > context.now } ?? true }
        guard !candidates.isEmpty else { throw ConnectorError.missingCredential }
        var lastCandidateError: ConnectorError?
        for credential in candidates {
            do { return try await fetch(using: credential, context: context) }
            catch let error as ConnectorError {
                switch error {
                case .invalidCredential, .insufficientScope, .invalidResponse:
                    lastCandidateError = error
                    continue
                default: throw error
                }
            }
        }
        throw lastCandidateError ?? ConnectorError.missingCredential
    }

    private func fetch(using credential: CredentialCandidate, context: FetchContext) async throws -> SourceSnapshot {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.secret.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await client.data(for: request)
        try HTTPValidation.checked(response)
        let root = try ProviderJSON.object(from: data)
        let metrics = ClaudeSubscriptionMapper.metrics(from: root, now: context.now)
        guard !metrics.isEmpty else { throw ConnectorError.invalidResponse }
        return SourceSnapshot(
            source: descriptor,
            accountID: ProviderJSON.string(root["account_id"]) ?? credential.accountID ?? "claude-subscription-\(credential.generation)",
            accountDisplayName: "Claude",
            plan: ProviderJSON.string(root["plan"]),
            metrics: metrics,
            fetchedAt: context.now,
            expiresAt: context.now.addingTimeInterval(10 * 60),
            warnings: [.init(id: "experimental", message: "Uses an experimental private provider endpoint.")]
        )
    }
}

private enum ClaudeSubscriptionMapper {
    static func metrics(from root: [String: Any], now: Date) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        appendWindow(root["five_hour"], id: "subscription.session", duration: 5 * 60 * 60, now: now, to: &metrics)
        appendWindow(root["seven_day"], id: "subscription.weekly", duration: 7 * 24 * 60 * 60, now: now, to: &metrics)
        appendWindow(root["seven_day_sonnet"], id: "subscription.model.sonnet.weekly", duration: 7 * 24 * 60 * 60, now: now, to: &metrics)
        appendWindow(root["seven_day_opus"], id: "subscription.model.opus.weekly", duration: 7 * 24 * 60 * 60, now: now, to: &metrics)

        if let limits = root["limits"] as? [Any] {
            for value in limits {
                guard let limit = value as? [String: Any],
                      let kind = ProviderJSON.string(limit["kind"]),
                      let percent = ProviderJSON.percent(limit["percent"] ?? limit["utilization"])
                else { continue }
                if kind == "session", !metrics.contains(where: { $0.id == "subscription.session" }) {
                    metrics.append(quotaMetric(id: "subscription.session", percent: percent, reset: limit["resets_at"], duration: 5 * 60 * 60, now: now))
                    continue
                }
                if kind == "weekly_all", !metrics.contains(where: { $0.id == "subscription.weekly" }) {
                    metrics.append(quotaMetric(id: "subscription.weekly", percent: percent, reset: limit["resets_at"], duration: 7 * 24 * 60 * 60, now: now))
                    continue
                }
                guard kind == "weekly_scoped",
                      let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let displayName = ProviderJSON.string(model["display_name"]) ?? ProviderJSON.string(model["id"])
                else { continue }
                let id = "subscription.model.\(ProviderJSON.slug(displayName)).weekly"
                guard !metrics.contains(where: { $0.id == id }) else { continue }
                metrics.append(quotaMetric(id: id, percent: percent, reset: limit["resets_at"], duration: 7 * 24 * 60 * 60, now: now))
            }
        }

        if let extra = root["extra_usage"] as? [String: Any],
           ProviderJSON.bool(extra["is_enabled"]) == true,
           let usedCents = ProviderJSON.nonnegative(extra["used_credits"]) {
            let positiveLimit = ProviderJSON.nonnegative(extra["monthly_limit"]).flatMap { $0 > 0 ? $0 : nil }
            metrics.append(UsageMetric(
                id: "subscription.extra_usage.month",
                kind: .cost,
                scope: .subscription,
                unit: .usd,
                used: usedCents / 100,
                limit: positiveLimit.map { $0 / 100 },
                provenance: .privateProviderEndpoint,
                collectedAt: now
            ))
        }
        return metrics
    }

    private static func appendWindow(_ value: Any?, id: String, duration: TimeInterval, now: Date, to metrics: inout [UsageMetric]) {
        guard let window = value as? [String: Any], let percent = ProviderJSON.percent(window["utilization"]) else { return }
        metrics.append(quotaMetric(id: id, percent: percent, reset: window["resets_at"], duration: duration, now: now))
    }

    private static func quotaMetric(id: String, percent: Decimal, reset: Any?, duration: TimeInterval, now: Date) -> UsageMetric {
        UsageMetric(id: id, kind: .quota, scope: .subscription, unit: .fraction, used: percent / 100, limit: 1, resetsAt: ProviderJSON.date(reset), windowSeconds: duration, provenance: .privateProviderEndpoint, collectedAt: now)
    }
}

public struct CodexSubscriptionConnector: UsageSourceConnector {
    public let descriptor = UsageSourceDescriptor(id: "codex.subscription", family: .codex, displayName: "Codex subscription", provenance: .privateProviderEndpoint, isExperimental: true)
    private let resolver: any CredentialResolver
    private let client: any CollectorHTTPClient
    private let endpoint: URL
    private let enabled: Bool

    public init(resolver: any CredentialResolver, client: any CollectorHTTPClient = URLSessionCollectorHTTPClient(), endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!, enabled: Bool) {
        self.resolver = resolver
        self.client = client
        self.endpoint = endpoint
        self.enabled = enabled
    }

    public func probe() async -> ProbeResult {
        guard enabled else { return .init(.disabled) }
        let candidates = await resolver.candidates(for: descriptor)
        return candidates.contains(where: { $0.expiresAt.map { $0 > .now } ?? true }) ? .init(.available) : .init(.missingCredential)
    }

    public func fetch(context: FetchContext) async throws -> SourceSnapshot {
        guard enabled else { throw ConnectorError.provider("Experimental Codex subscription source is disabled.") }
        let candidates = await resolver.candidates(for: descriptor).filter { $0.expiresAt.map { $0 > context.now } ?? true }
        guard !candidates.isEmpty else { throw ConnectorError.missingCredential }
        var lastCandidateError: ConnectorError?
        for credential in candidates {
            do { return try await fetch(using: credential, context: context) }
            catch let error as ConnectorError {
                switch error {
                case .invalidCredential, .insufficientScope, .invalidResponse:
                    lastCandidateError = error
                    continue
                default: throw error
                }
            }
        }
        throw lastCandidateError ?? ConnectorError.missingCredential
    }

    private func fetch(using credential: CredentialCandidate, context: FetchContext) async throws -> SourceSnapshot {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.secret.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenUsage-compatible TinyUsage", forHTTPHeaderField: "User-Agent")
        if let accountID = credential.accountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let (data, response) = try await client.data(for: request)
        try HTTPValidation.checked(response)
        let root = try ProviderJSON.object(from: data)
        let metrics = CodexSubscriptionMapper.metrics(from: root, response: response, now: context.now)
        guard !metrics.isEmpty else { throw ConnectorError.invalidResponse }
        return SourceSnapshot(
            source: descriptor,
            accountID: ProviderJSON.string(root["account_id"]) ?? credential.accountID ?? "codex-subscription-\(credential.generation)",
            accountDisplayName: "Codex",
            plan: ProviderJSON.string(root["plan_type"]),
            metrics: metrics,
            fetchedAt: context.now,
            expiresAt: context.now.addingTimeInterval(10 * 60),
            warnings: [.init(id: "experimental", message: "Uses an experimental private provider endpoint.")]
        )
    }
}

private enum CodexSubscriptionMapper {
    private enum WindowKind { case session, weekly }

    static func metrics(from root: [String: Any], response: HTTPURLResponse, now: Date) -> [UsageMetric] {
        var metrics = windowMetrics(
            rateLimit: root["rate_limit"] as? [String: Any],
            prefix: "subscription",
            headerPercents: (
                ProviderJSON.decimal(response.value(forHTTPHeaderField: "x-codex-primary-used-percent")),
                ProviderJSON.decimal(response.value(forHTTPHeaderField: "x-codex-secondary-used-percent"))
            ),
            now: now
        )

        if let additional = root["additional_rate_limits"] as? [Any] {
            for value in additional {
                guard let entry = value as? [String: Any],
                      let rateLimit = entry["rate_limit"] as? [String: Any]
                else { continue }
                let name = ProviderJSON.string(entry["limit_name"]) ?? ProviderJSON.string(entry["name"]) ?? "model"
                metrics.append(contentsOf: windowMetrics(rateLimit: rateLimit, prefix: "subscription.model.\(ProviderJSON.slug(name))", headerPercents: (nil, nil), now: now))
            }
        }

        if let resetCredits = root["rate_limit_reset_credits"] as? [String: Any],
           let available = ProviderJSON.nonnegative(resetCredits["available_count"]) {
            metrics.append(UsageMetric(id: "subscription.rate_limit_resets", kind: .credits, scope: .subscription, unit: .credits, available: available, provenance: .privateProviderEndpoint, collectedAt: now))
        }

        let credits = root["credits"] as? [String: Any]
        let balance = ProviderJSON.nonnegative(credits?["balance"])
            ?? (ProviderJSON.bool(credits?["has_credits"]) == false ? 0 : nil)
            ?? ProviderJSON.nonnegative(response.value(forHTTPHeaderField: "x-codex-credits-balance"))
        if let balance {
            metrics.append(UsageMetric(id: "subscription.credits", kind: .credits, scope: .subscription, unit: .credits, available: balance, provenance: .privateProviderEndpoint, collectedAt: now))
        }
        return metrics
    }

    private static func windowMetrics(rateLimit: [String: Any]?, prefix: String, headerPercents: (Decimal?, Decimal?), now: Date) -> [UsageMetric] {
        let rateLimit = rateLimit ?? [:]
        let candidates: [(Any?, Decimal?, WindowKind)] = [
            (rateLimit["primary_window"], headerPercents.0, .session),
            (rateLimit["secondary_window"], headerPercents.1, .weekly)
        ]
        var result: [UsageMetric] = []
        for (value, headerPercent, fallback) in candidates {
            let window = value as? [String: Any] ?? [:]
            guard !window.isEmpty || headerPercent != nil else { continue }
            guard let used = ProviderJSON.percent(window["used_percent"]) ?? headerPercent.flatMap({ ProviderJSON.percent($0) }) else { continue }
            let duration = ProviderJSON.positiveDouble(window["limit_window_seconds"])
            let kind: WindowKind
            if let duration, abs(duration - 5 * 60 * 60) < 60 { kind = .session }
            else if let duration, abs(duration - 7 * 24 * 60 * 60) < 60 { kind = .weekly }
            else { kind = fallback }
            let suffix = kind == .session ? "session" : "weekly"
            let id = "\(prefix).\(suffix)"
            guard !result.contains(where: { $0.id == id }) else { continue }
            let reset = ProviderJSON.date(window["reset_at"])
                ?? ProviderJSON.positiveDouble(window["reset_after_seconds"]).map { now.addingTimeInterval($0) }
            result.append(UsageMetric(id: id, kind: .quota, scope: .subscription, unit: .fraction, used: used / 100, limit: 1, resetsAt: reset, windowSeconds: duration, provenance: .privateProviderEndpoint, collectedAt: now))
        }
        return result
    }
}

private enum ProviderJSON {
    static func object(from data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectorError.invalidResponse }
        return value
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func decimal(_ value: Any?) -> Decimal? {
        if let value = value as? Decimal { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.decimalValue }
        if let value = string(value) { return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        decimal(value).map { NSDecimalNumber(decimal: $0).doubleValue }.flatMap { $0.isFinite ? $0 : nil }
    }

    static func positiveDouble(_ value: Any?) -> Double? {
        double(value).flatMap { $0 > 0 ? $0 : nil }
    }

    static func nonnegative(_ value: Any?) -> Decimal? {
        decimal(value).flatMap { $0 >= 0 ? $0 : nil }
    }

    static func percent(_ value: Any?) -> Decimal? {
        decimal(value).flatMap { (0...100).contains($0) ? $0 : nil }
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        guard let value = string(value)?.lowercased() else { return nil }
        if ["true", "1", "yes"].contains(value) { return true }
        if ["false", "0", "no"].contains(value) { return false }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let text = string(value) {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: text) { return date }
        }
        guard let epoch = double(value) else { return nil }
        return Date(timeIntervalSince1970: abs(epoch) >= 10_000_000_000 ? epoch / 1_000 : epoch)
    }

    static func slug(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
        let parts = String(scalars).split(separator: "-", omittingEmptySubsequences: true)
        return parts.isEmpty ? "model" : parts.joined(separator: "-")
    }
}

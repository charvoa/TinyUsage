import Foundation
import TinyUsageDomain

public struct AnthropicOrganizationConnector: UsageSourceConnector {
    public let descriptor = UsageSourceDescriptor(id: "claude.organization", family: .claude, displayName: "Anthropic organization", provenance: .officialAPI)
    private let apiKey: String
    private let accountID: String
    private let client: any CollectorHTTPClient
    private let baseURL: URL

    public init(apiKey: String, accountID: String = "claude-organization", client: any CollectorHTTPClient = URLSessionCollectorHTTPClient(), baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.accountID = accountID
        self.client = client
        self.baseURL = baseURL
    }

    public func probe() async -> ProbeResult { apiKey.isEmpty ? .init(.missingCredential) : .init(.available) }

    public func fetch(context: FetchContext) async throws -> SourceSnapshot {
        guard !apiKey.isEmpty else { throw ConnectorError.missingCredential }
        let start = Calendar(identifier: .gregorian).startOfDay(for: context.now)
        let usageData = try await request(path: "/v1/organizations/usage_report/messages", start: start, end: context.now)
        let root = try JSONDecoder().decode(AnthropicUsageResponse.self, from: usageData)
        let values = root.data.flatMap(\.results)
        let input = values.reduce(0) { $0 + $1.input }
        let output = values.reduce(0) { $0 + $1.output }
        var metrics = [
            UsageMetric(id: "api.tokens.input.day", kind: .tokens, scope: .officialAPI, unit: .tokens, used: Decimal(input), provenance: .officialAPI, collectedAt: context.now),
            UsageMetric(id: "api.tokens.output.day", kind: .tokens, scope: .officialAPI, unit: .tokens, used: Decimal(output), provenance: .officialAPI, collectedAt: context.now)
        ]
        var warnings: [ProviderWarning] = []
        do {
            let costData = try await request(path: "/v1/organizations/cost_report", start: start, end: context.now)
            let cost = try JSONDecoder().decode(AnthropicCostResponse.self, from: costData)
            let cents = cost.data.flatMap(\.results).reduce(Decimal.zero) { $0 + (Decimal(string: $1.amount) ?? 0) }
            metrics.append(UsageMetric(id: "api.cost.day", kind: .cost, scope: .officialAPI, unit: .usd, used: cents / 100, provenance: .officialAPI, collectedAt: context.now))
        } catch {
            warnings.append(.init(id: "cost-report-unavailable", message: "Official cost data is temporarily unavailable; token usage remains valid."))
        }
        return SourceSnapshot(source: descriptor, accountID: accountID, accountDisplayName: "Claude", metrics: metrics, fetchedAt: context.now, expiresAt: context.now.addingTimeInterval(10 * 60), warnings: warnings)
    }

    private func request(path: String, start: Date, end: Date) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "starting_at", value: start.ISO8601Format()), .init(name: "ending_at", value: end.ISO8601Format()), .init(name: "bucket_width", value: "1h"), .init(name: "limit", value: "24")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await client.data(for: request)
        try HTTPValidation.checked(response)
        return data
    }
}

private struct AnthropicUsageResponse: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable { let results: [Result] }
    struct Result: Decodable {
        let input: Int
        let output: Int
        enum CodingKeys: String, CodingKey { case uncached = "uncached_input_tokens", cached = "cache_read_input_tokens", created = "cache_creation_input_tokens", output = "output_tokens" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = (try c.decodeIfPresent(Int.self, forKey: .uncached) ?? 0) + (try c.decodeIfPresent(Int.self, forKey: .cached) ?? 0) + (try c.decodeIfPresent(Int.self, forKey: .created) ?? 0)
            output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        }
    }
}

private struct AnthropicCostResponse: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable { let results: [Result] }
    struct Result: Decodable { let amount: String }
}

public struct OpenAIOrganizationConnector: UsageSourceConnector {
    public let descriptor = UsageSourceDescriptor(id: "codex.organization", family: .codex, displayName: "OpenAI organization", provenance: .officialAPI)
    private let apiKey: String
    private let accountID: String
    private let client: any CollectorHTTPClient
    private let baseURL: URL

    public init(apiKey: String, accountID: String = "openai-organization", client: any CollectorHTTPClient = URLSessionCollectorHTTPClient(), baseURL: URL = URL(string: "https://api.openai.com")!) {
        self.apiKey = apiKey
        self.accountID = accountID
        self.client = client
        self.baseURL = baseURL
    }

    public func probe() async -> ProbeResult { apiKey.isEmpty ? .init(.missingCredential) : .init(.available) }

    public func fetch(context: FetchContext) async throws -> SourceSnapshot {
        guard !apiKey.isEmpty else { throw ConnectorError.missingCredential }
        let start = Calendar(identifier: .gregorian).startOfDay(for: context.now)
        let usage = try await request(path: "/v1/organization/usage/completions", start: start, end: context.now)
        let root = try JSONDecoder().decode(OpenAIUsageResponse.self, from: usage)
        let values = root.data.flatMap(\.results)
        var metrics = [
            UsageMetric(id: "api.tokens.input.day", kind: .tokens, scope: .officialAPI, unit: .tokens, used: Decimal(values.reduce(0) { $0 + $1.input }), provenance: .officialAPI, collectedAt: context.now),
            UsageMetric(id: "api.tokens.output.day", kind: .tokens, scope: .officialAPI, unit: .tokens, used: Decimal(values.reduce(0) { $0 + $1.output }), provenance: .officialAPI, collectedAt: context.now)
        ]
        var warnings: [ProviderWarning] = []
        do {
            let costData = try await request(path: "/v1/organization/costs", start: start, end: context.now)
            let cost = try JSONDecoder().decode(OpenAICostResponse.self, from: costData)
            metrics.append(UsageMetric(id: "api.cost.day", kind: .cost, scope: .officialAPI, unit: .usd, used: cost.data.flatMap(\.results).reduce(0) { $0 + (Decimal(string: $1.amount.value) ?? 0) }, provenance: .officialAPI, collectedAt: context.now))
        } catch {
            warnings.append(.init(id: "cost-report-unavailable", message: "Official cost data is temporarily unavailable; token usage remains valid."))
        }
        return SourceSnapshot(source: descriptor, accountID: accountID, accountDisplayName: "Codex", metrics: metrics, fetchedAt: context.now, expiresAt: context.now.addingTimeInterval(10 * 60), warnings: warnings)
    }

    private func request(path: String, start: Date, end: Date) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "start_time", value: String(Int(start.timeIntervalSince1970))), .init(name: "end_time", value: String(Int(end.timeIntervalSince1970))), .init(name: "bucket_width", value: "1h"), .init(name: "limit", value: "24")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await client.data(for: request)
        try HTTPValidation.checked(response)
        return data
    }
}

private struct OpenAIUsageResponse: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable { let results: [Result] }
    struct Result: Decodable {
        let input: Int
        let output: Int
        enum CodingKeys: String, CodingKey { case input = "input_tokens", output = "output_tokens" }
    }
}

private struct OpenAICostResponse: Decodable {
    let data: [Bucket]
    struct Bucket: Decodable { let results: [Result] }
    struct Result: Decodable { let amount: Amount }
    struct Amount: Decodable { let value: String }
}

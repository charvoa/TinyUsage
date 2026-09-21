import Foundation
import Testing
@testable import TinyUsageCollectorCore
import TinyUsageDomain

private struct FixtureClient: CollectorHTTPClient {
    let responses: [String: String]
    let status: Int
    var headers: [String: String] = [:]
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = responses.first(where: { request.url!.path.hasSuffix($0.key) })?.value ?? "{}"
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private actor MemoryRepository: SnapshotRepository {
    var values: [String: SourceSnapshot] = [:]
    func lastGood(for sourceID: String) -> SourceSnapshot? { values[sourceID] }
    func commit(_ snapshot: SourceSnapshot) { values[snapshot.source.id] = snapshot }
}

private actor FetchCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct FailingConnector: UsageSourceConnector {
    let descriptor = UsageSourceDescriptor(id: "claude.failing", family: .claude, displayName: "Failing source", provenance: .officialAPI)
    let counter: FetchCounter
    func probe() async -> ProbeResult { .init(.available) }
    func fetch(context: FetchContext) async throws -> SourceSnapshot {
        await counter.increment()
        throw ConnectorError.timedOut
    }
}

struct CollectorCoreTests {
    @Test func anthropicMapsOfficialUsageAndCost() async throws {
        let client = FixtureClient(responses: [
            "messages": #"{"data":[{"results":[{"uncached_input_tokens":10,"cache_read_input_tokens":2,"cache_creation_input_tokens":1,"output_tokens":5}]}]}"#,
            "cost_report": #"{"data":[{"results":[{"amount":"123.45"}]}]}"#
        ], status: 200)
        let source = AnthropicOrganizationConnector(apiKey: "secret", client: client, baseURL: URL(string: "https://fixture.invalid")!)
        let result = try await source.fetch(context: .init())
        #expect(result.metrics.first(where: { $0.id == "api.tokens.input.day" })?.used == 13)
        #expect(result.metrics.first(where: { $0.id == "api.cost.day" })?.used == Decimal(string: "1.2345"))
    }

    @Test func codexMapsSubscriptionWindows() async throws {
        let body = #"{"account_id":"opaque","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000000000,"limit_window_seconds":18000},"secondary_window":{"used_percent":50,"reset_at":2000000000,"limit_window_seconds":604800}},"credits":{"balance":4.5}}"#
        let resolver = StaticResolver(candidate: .init(secret: "secret", origin: .codexHome, generation: "1"))
        let connector = CodexSubscriptionConnector(resolver: resolver, client: FixtureClient(responses: ["usage": body], status: 200), endpoint: URL(string: "https://fixture.invalid/usage")!, enabled: true)
        let result = try await connector.fetch(context: .init())
        #expect(result.metrics.map(\.id).contains("subscription.session"))
        #expect(result.metrics.map(\.id).contains("subscription.weekly"))
        #expect(result.metrics.map(\.id).contains("subscription.credits"))
    }

    @Test func claudeAcceptsISOResetsScopedLimitsAndExtraUsage() async throws {
        let body = #"{"five_hour":{"utilization":"12.5","resets_at":"2099-01-01T00:00:00.000Z"},"seven_day":{"utilization":25,"resets_at":"2099-01-07T00:00:00Z"},"seven_day_sonnet":null,"limits":[{"kind":"weekly_scoped","percent":"33","resets_at":4071427200000,"scope":{"model":{"display_name":"Claude Fable"}}}],"extra_usage":{"is_enabled":true,"used_credits":"500","monthly_limit":1000}}"#
        let resolver = StaticResolver(candidate: .init(secret: "secret", origin: .claudeCode, generation: "1"))
        let connector = ClaudeSubscriptionConnector(resolver: resolver, client: FixtureClient(responses: ["usage": body], status: 200), endpoint: URL(string: "https://fixture.invalid/usage")!, enabled: true)
        let result = try await connector.fetch(context: .init())
        #expect(result.metrics.first(where: { $0.id == "subscription.session" })?.used == Decimal(string: "0.125"))
        #expect(result.metrics.first(where: { $0.id == "subscription.session" })?.resetsAt != nil)
        #expect(result.metrics.map(\.id).contains("subscription.model.claude-fable.weekly"))
        #expect(result.metrics.first(where: { $0.id == "subscription.extra_usage.month" })?.used == 5)
        #expect(result.metrics.first(where: { $0.id == "subscription.extra_usage.month" })?.limit == 10)
    }

    @Test func codexAcceptsStringNumbersAndClassifiesSoleWeeklyWindow() async throws {
        let body = #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":"41.5","reset_at":"2099-01-01T00:00:00.000Z","limit_window_seconds":"604800"}},"additional_rate_limits":[{"limit_name":"GPT-5.3 Codex Spark","rate_limit":{"primary_window":{"used_percent":"7","reset_at":4070908800,"limit_window_seconds":18000}}}],"credits":{"balance":"4.5"},"rate_limit_reset_credits":{"available_count":"2"}}"#
        let resolver = StaticResolver(candidate: .init(secret: "secret", origin: .codexHome, generation: "1"))
        let connector = CodexSubscriptionConnector(resolver: resolver, client: FixtureClient(responses: ["usage": body], status: 200), endpoint: URL(string: "https://fixture.invalid/usage")!, enabled: true)
        let result = try await connector.fetch(context: .init())
        #expect(result.metrics.first(where: { $0.id == "subscription.weekly" })?.used == Decimal(string: "0.415"))
        #expect(!result.metrics.map(\.id).contains("subscription.session"))
        #expect(result.metrics.map(\.id).contains("subscription.model.gpt-5-3-codex-spark.session"))
        #expect(result.metrics.first(where: { $0.id == "subscription.rate_limit_resets" })?.available == 2)
        #expect(result.metrics.first(where: { $0.id == "subscription.credits" })?.available == Decimal(string: "4.5"))
    }

    @Test func codexAcceptsHeaderOnlyUsageAndRelativeReset() async throws {
        let body = #"{"rate_limit":{"primary_window":{"reset_after_seconds":"90","limit_window_seconds":18000}},"credits":{"balance":"invalid"}}"#
        let resolver = StaticResolver(candidate: .init(secret: " secret\n", origin: .codexHome, generation: "1"))
        let client = FixtureClient(responses: ["usage": body], status: 200, headers: [
            "x-codex-primary-used-percent": "17.5",
            "x-codex-credits-balance": "8"
        ])
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let connector = CodexSubscriptionConnector(resolver: resolver, client: client, endpoint: URL(string: "https://fixture.invalid/usage")!, enabled: true)
        let result = try await connector.fetch(context: .init(now: now))
        #expect(result.metrics.first(where: { $0.id == "subscription.session" })?.used == Decimal(string: "0.175"))
        #expect(result.metrics.first(where: { $0.id == "subscription.session" })?.resetsAt == now.addingTimeInterval(90))
        #expect(result.metrics.first(where: { $0.id == "subscription.credits" })?.available == 8)
    }

    @Test func aggregationPreservesLastGoodAndSeparatesAccounts() {
        let official = makeSnapshot(source: .init(id: "claude.api", family: .claude, displayName: "API", provenance: .officialAPI), account: "org", metric: "api.tokens.day")
        let local = makeSnapshot(source: .init(id: "claude.local", family: .claude, displayName: "Local", provenance: .estimatedLocal), account: "local", metric: "local.cost.today")
        let result = ProviderAggregator.aggregate(successes: [local], failures: ["claude.api": ConnectorError.timedOut], lastGood: ["claude.api": official])
        #expect(result.count == 2)
        #expect(result.first(where: { $0.account.id == "org" })?.sourceErrors.count == 1)
        #expect(result.flatMap(\.metrics).count == 2)
    }

    @Test func orchestratorKeepsFailureVisibleWhileSourceIsBackedOff() async {
        let counter = FetchCounter()
        let connector = FailingConnector(counter: counter)
        let orchestrator = CollectionOrchestrator(connectors: [connector], repository: MemoryRepository())
        let start = Date.now
        let first = await orchestrator.collect(collectorID: "collector", now: start)
        let second = await orchestrator.collect(collectorID: "collector", now: start.addingTimeInterval(10))
        #expect(await counter.value == 1)
        #expect(first.collectorHealth == .degraded)
        #expect(second.collectorHealth == .degraded)
        #expect(second.snapshots.first?.sourceErrors.first?.sourceID == connector.descriptor.id)
    }

    @Test func scannerHandlesAppendTruncationAndCorruptRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "session.jsonl")
        try Data("{\"input_tokens\":2,\"output_tokens\":3}\ninvalid\n".utf8).write(to: file)
        let index = directory.appending(path: "index.json")
        let scanner = IncrementalJSONLScanner(indexURL: index)
        #expect(await scanner.scan(files: [file]).inputTokens == 2)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"input_tokens\":5}\n".utf8)); try handle.synchronize(); try handle.close()
        #expect(await scanner.scan(files: [file]).inputTokens == 7)
        try Data("{\"input_tokens\":1}\n".utf8).write(to: file)
        #expect(await scanner.scan(files: [file]).inputTokens == 1)
        let restored = IncrementalJSONLScanner(indexURL: index)
        #expect(await restored.scan(files: [file]).inputTokens == 1)
    }

    @Test func scannerDropsDeletedFilesAndDetectsInPlaceReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appending(path: "first.jsonl")
        let second = directory.appending(path: "second.jsonl")
        try Data("{\"input_tokens\":10}\n".utf8).write(to: first)
        try Data("{\"input_tokens\":2}\n".utf8).write(to: second)
        let scanner = IncrementalJSONLScanner(indexURL: directory.appending(path: "index.json"))
        #expect(await scanner.scan(files: [first, second]).inputTokens == 12)
        try FileManager.default.removeItem(at: second)
        #expect(await scanner.scan(files: [first]).inputTokens == 10)
        try Data("{\"input_tokens\":99}\n".utf8).write(to: first)
        #expect(await scanner.scan(files: [first]).inputTokens == 99)
    }

    @Test func localConnectorEstimatesKnownModelsUsingVersionedPublicPrices() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "session.jsonl")
        let now = Date.now
        let fixture = "{\"input_tokens\":1000000,\"output_tokens\":1000000,\"model\":\"claude-sonnet-4\",\"timestamp\":\"\(now.ISO8601Format())\"}\n"
        try Data(fixture.utf8).write(to: file)
        let connector = LocalLogConnector(family: .claude, files: { [file] })
        let snapshot = try await connector.fetch(context: .init(now: now))
        #expect(snapshot.metrics.first(where: { $0.id == "local.cost.today" })?.used == 18)
    }

    @Test func claudeResolverDoesNotLetInferenceTokenMaskOAuthUsageToken() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = home.appending(path: ".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = #"{"access_token":"inference-only","scope":"inference","oauth":{"accessToken":"oauth-usage","scope":"user:profile usage"}}"#
        try Data(fixture.utf8).write(to: directory.appending(path: ".credentials.json"))
        let resolver = LocalCredentialResolver(environment: [:], homeDirectory: home)
        let descriptor = UsageSourceDescriptor(id: "claude.subscription", family: .claude, displayName: "Claude", provenance: .privateProviderEndpoint)
        #expect(await resolver.candidates(for: descriptor).first?.secret == "oauth-usage")
    }

    @Test func resolverParsesMillisecondAndISOExpiry() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = home.appending(path: ".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = Date.now.addingTimeInterval(3_600)
        let milliseconds = Int(future.timeIntervalSince1970 * 1_000)
        let fixture = "{\"tokens\":[{\"access_token\":\"milliseconds\",\"expires_at\":\(milliseconds)},{\"access_token\":\"iso\",\"expires_at\":\"\(future.ISO8601Format())\"}]}"
        try Data(fixture.utf8).write(to: directory.appending(path: "auth.json"))
        let resolver = LocalCredentialResolver(environment: [:], homeDirectory: home)
        let descriptor = UsageSourceDescriptor(id: "codex.subscription", family: .codex, displayName: "Codex", provenance: .privateProviderEndpoint)
        let candidates = await resolver.candidates(for: descriptor)
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { ($0.expiresAt ?? .distantPast) > .now })
    }

    @Test func bundlePayloadDoesNotContainKnownSecret() throws {
        let bundle = SnapshotBundle(collectorID: "collector", revision: 1, snapshots: [], collectorHealth: .healthy)
        let text = String(decoding: try FrameCodec.encode(.snapshotBundle(bundle)), as: UTF8.self)
        #expect(!text.contains("secret-value"))
        #expect(!text.localizedCaseInsensitiveContains("authorization"))
        #expect(!text.localizedCaseInsensitiveContains("cookie"))
    }

    @Test func diagnosticsRedactHomePathsAndBearerTokens() throws {
        let account = ProviderAccount(id: "opaque", family: .claude, displayName: "Claude")
        let snapshot = ProviderSnapshot(account: account, metrics: [], fetchedAt: .now, expiresAt: .now, warnings: [.init(id: "w", message: "<home>/.claude failed with Bearer <redacted>")])
        let report = DiagnosticReport(bundle: .init(collectorID: "collector", revision: 1, snapshots: [snapshot], collectorHealth: .degraded))
        let text = String(decoding: try report.encoded(), as: UTF8.self)
        #expect(!text.contains("<home>"))
        #expect(!text.contains("<redacted>"))
    }

    private func makeSnapshot(source: UsageSourceDescriptor, account: String, metric: String) -> SourceSnapshot {
        .init(source: source, accountID: account, accountDisplayName: account, metrics: [.init(id: metric, kind: .tokens, scope: metric.hasPrefix("api") ? .officialAPI : .local, unit: .tokens, used: 1, provenance: source.provenance)], fetchedAt: .now, expiresAt: .now.addingTimeInterval(60))
    }
}

private struct StaticResolver: CredentialResolver {
    let candidate: CredentialCandidate
    func candidates(for source: UsageSourceDescriptor) async -> [CredentialCandidate] { [candidate] }
}

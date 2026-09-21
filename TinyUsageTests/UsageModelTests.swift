import Foundation
import Testing
import TinyUsageDomain

struct UsageModelTests {
    @Test func freshnessIsDerivedLocally() {
        let account = ProviderAccount(id: "opaque", family: .claude, displayName: "Claude")
        let snapshot = ProviderSnapshot(account: account, metrics: [], fetchedAt: .now, expiresAt: Date(timeIntervalSince1970: 0))
        #expect(snapshot.freshness() == .stale)
    }

    @Test func scopesAreNeverImplicitlyCombined() {
        let metrics = [
            UsageMetric(id: "subscription.session", kind: .quota, scope: .subscription, unit: .fraction, used: 0.2, limit: 1, provenance: .privateProviderEndpoint),
            UsageMetric(id: "api.tokens.day", kind: .tokens, scope: .officialAPI, unit: .tokens, used: 100, provenance: .officialAPI),
            UsageMetric(id: "local.cost.today", kind: .cost, scope: .local, unit: .usd, used: 2, provenance: .estimatedLocal)
        ]
        #expect(Dictionary(grouping: metrics, by: \.scope).count == 3)
    }

    @Test func combinedActivityPayloadStaysBelowActivityKitLimit() throws {
        let attributes = UsageActivityAttributes(combinedCollectorID: String(repeating: "c", count: 200))
        let summaries = ProviderFamily.allCases.map { family in
            UsageActivityAttributes.ProviderSummary(
                family: family,
                providerName: String(repeating: family.displayName, count: 20),
                metricLabel: String(repeating: "Weekly quota", count: 20),
                used: 0.42,
                limit: 1,
                available: nil,
                unit: .fraction,
                resetsAt: .now.addingTimeInterval(604_800),
                provenance: .privateProviderEndpoint,
                expiresAt: .now.addingTimeInterval(600)
            )
        }
        let state = UsageActivityAttributes.ContentState(providers: summaries, synchronizedAt: .now, isStale: false)
        let encoder = JSONEncoder()
        #expect(try encoder.encode(attributes).count + encoder.encode(state).count < 4_096)
        #expect(state.providers?.count == 2)
        #expect(state.providers?.allSatisfy { $0.providerName.count <= 40 && $0.metricLabel.count <= 40 } == true)
    }

    @Test func combinedActivityAlwaysIncludesIndependentClaudeAndCodexSlots() {
        let now = Date.now
        let snapshots = ProviderFamily.allCases.map { family in
            ProviderSnapshot(
                account: .init(id: family.rawValue, family: family, displayName: family.displayName),
                metrics: [.init(id: "subscription.session", kind: .quota, scope: .subscription, unit: .fraction, used: family == .claude ? 0.2 : 0.6, limit: 1, resetsAt: now.addingTimeInterval(3_600), provenance: .privateProviderEndpoint, collectedAt: now)],
                fetchedAt: now,
                expiresAt: now.addingTimeInterval(300)
            )
        }
        let bundle = SnapshotBundle(collectorID: "collector", revision: 1, generatedAt: now, snapshots: snapshots, collectorHealth: .healthy)
        let summaries = bundle.activitySummaries(at: now)
        #expect(summaries.map(\.family) == [.claude, .codex])
        #expect(summaries.map(\.used) == [0.2, 0.6])
    }

    @Test func combinedActivityHonorsActivitySpecificMetricChoices() {
        let now = Date.now
        let metrics = [
            UsageMetric(id: "subscription.session", kind: .quota, scope: .subscription, unit: .fraction, used: 0.2, limit: 1, resetsAt: now.addingTimeInterval(3_600), provenance: .privateProviderEndpoint, collectedAt: now),
            UsageMetric(id: "subscription.weekly", kind: .quota, scope: .subscription, unit: .fraction, used: 0.7, limit: 1, resetsAt: now.addingTimeInterval(604_800), provenance: .privateProviderEndpoint, collectedAt: now)
        ]
        let snapshots = ProviderFamily.allCases.map { family in
            ProviderSnapshot(account: .init(id: family.rawValue, family: family, displayName: family.displayName), metrics: metrics, fetchedAt: now, expiresAt: now.addingTimeInterval(300))
        }
        let bundle = SnapshotBundle(collectorID: "collector", revision: 1, generatedAt: now, snapshots: snapshots, collectorHealth: .healthy)
        var preferences = UsageDisplayPreferences()
        preferences.setMetricID("subscription.weekly", for: .claude, surface: .liveActivity)
        preferences.setMetricID("subscription.session", for: .codex, surface: .liveActivity)

        let summaries = bundle.activitySummaries(preferences: preferences, at: now)
        #expect(summaries.map(\.metricLabel) == ["Weekly", "Session"])
        #expect(summaries.map(\.used) == [0.7, 0.2])
    }
}

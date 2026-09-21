import Foundation
import Testing
@testable import TinyUsageDomain

struct DomainTests {
    @Test func frameRoundTripAndLimit() throws {
        let hello = SyncMessage.hello(.init(deviceName: "Phone", collectorID: "collector", pskIdentity: "pairing-key"))
        #expect(try FrameCodec.decode(FrameCodec.encode(hello)) == hello)
        #expect(try FrameCodec.decode(FrameCodec.encode(.pairingPending)) == .pairingPending)
        #expect(throws: SyncProtocolError.self) { try FrameCodec.decode(Data([0, 8, 0, 1])) }
    }

    @Test func unknownValuesRemainAbsent() {
        let metric = UsageMetric(id: "subscription.session", kind: .quota, scope: .subscription, unit: .fraction, provenance: .privateProviderEndpoint)
        #expect(metric.used == nil)
        #expect(metric.usedFraction == nil)
    }

    @Test func pairingCodeRoundTripsAndExpires() throws {
        let payload = PairingPayload(collectorID: "collector", pskIdentity: "phone", secret: Data(repeating: 7, count: 32), expiresAt: .now.addingTimeInterval(60))
        let decoded = try PairingPayload.decode(code: payload.encodedCode())
        #expect(decoded.collectorID == payload.collectorID)
        #expect(decoded.pskIdentity == payload.pskIdentity)
        #expect(decoded.secret == payload.secret)
        #expect(abs(decoded.expiresAt.timeIntervalSince(payload.expiresAt)) < 1)
        #expect(!payload.isExpired)
    }

    @Test func bundleSerializationContainsNoAuthenticationFields() throws {
        let data = try JSONEncoder.tinyUsage.encode(SnapshotBundle.empty)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("token"))
        #expect(!text.contains("cookie"))
        #expect(!text.contains("apikey"))
    }

    @Test func presentationKeepsClaudeAndCodexIndependentOfSnapshotOrder() {
        let now = Date.now
        let bundle = SnapshotBundle(
            collectorID: "collector",
            revision: 1,
            snapshots: [
                snapshot(.claude, id: "claude-local", metric: .init(id: "local.cost.today", kind: .cost, scope: .local, unit: .usd, used: 1.25, provenance: .estimatedLocal, collectedAt: now)),
                snapshot(.claude, id: "claude-subscription", metric: .init(id: "subscription.weekly", kind: .quota, scope: .subscription, unit: .fraction, used: 0.4, limit: 1, resetsAt: now.addingTimeInterval(86_400), provenance: .privateProviderEndpoint, collectedAt: now)),
                snapshot(.codex, id: "codex-subscription", metric: .init(id: "subscription.session", kind: .quota, scope: .subscription, unit: .fraction, used: 0.2, limit: 1, resetsAt: now.addingTimeInterval(3_600), provenance: .privateProviderEndpoint, collectedAt: now))
            ],
            collectorHealth: .healthy
        )

        #expect(bundle.primaryMetric(for: .claude, at: now)?.metric.id == "subscription.weekly")
        #expect(bundle.primaryMetric(for: .codex, at: now)?.metric.id == "subscription.session")
    }

    @Test func presentationPrioritizesValidQuotaAndFormatsAvailableCredits() {
        let now = Date.now
        let account = ProviderAccount(id: "codex", family: .codex, displayName: "Codex")
        let metrics = [
            UsageMetric(id: "subscription.credits", kind: .credits, scope: .subscription, unit: .credits, available: 12.5, provenance: .privateProviderEndpoint, collectedAt: now),
            UsageMetric(id: "subscription.session", kind: .quota, scope: .subscription, unit: .fraction, used: 0.9, limit: 1, resetsAt: now.addingTimeInterval(-1), provenance: .privateProviderEndpoint, collectedAt: now),
            UsageMetric(id: "subscription.weekly", kind: .quota, scope: .subscription, unit: .fraction, used: 0.35, limit: 1, resetsAt: now.addingTimeInterval(86_400), provenance: .privateProviderEndpoint, collectedAt: now)
        ]
        let bundle = SnapshotBundle(collectorID: "collector", revision: 1, snapshots: [.init(account: account, metrics: metrics, fetchedAt: now, expiresAt: now.addingTimeInterval(300))], collectorHealth: .healthy)

        #expect(bundle.primaryMetric(for: .codex, at: now)?.metric.id == "subscription.weekly")
        #expect(metrics[0].displayValue.contains("available"))
        #expect(metrics[0].displayValue != "—")
        #expect(metrics[2].displayValue.contains("35"))
    }

    @Test func displayPreferencesKeepWidgetAndActivityChoicesIndependent() throws {
        var preferences = UsageDisplayPreferences()
        preferences.setMetricID("subscription.session", for: .claude, surface: .widget)
        preferences.setMetricID("subscription.weekly", for: .claude, surface: .liveActivity)
        preferences.setMetricID("subscription.credits", for: .codex, surface: .widget)

        let decoded = try JSONDecoder().decode(UsageDisplayPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.metricID(for: .claude, surface: .widget) == "subscription.session")
        #expect(decoded.metricID(for: .claude, surface: .liveActivity) == "subscription.weekly")
        #expect(decoded.metricID(for: .codex, surface: .widget) == "subscription.credits")
        #expect(decoded.metricID(for: .codex, surface: .liveActivity) == nil)
    }

    @Test func missingPreferredMetricFallsBackToPrimaryQuota() {
        let now = Date.now
        let metric = UsageMetric(id: "subscription.session", kind: .quota, scope: .subscription, unit: .fraction, used: 0.25, limit: 1, resetsAt: now.addingTimeInterval(3_600), provenance: .privateProviderEndpoint, collectedAt: now)
        let bundle = SnapshotBundle(collectorID: "collector", revision: 1, snapshots: [snapshot(.codex, id: "codex", metric: metric)], collectorHealth: .healthy)
        #expect(bundle.selectedMetric(for: .codex, preferredID: "subscription.no-longer-returned", at: now)?.metric.id == "subscription.session")
    }

    @Test func automaticSelectionNeverPromotesCreditsOrCost() {
        let now = Date.now
        let credits = UsageMetric(id: "subscription.credits", kind: .credits, scope: .subscription, unit: .credits, available: 8, provenance: .privateProviderEndpoint, collectedAt: now)
        let cost = UsageMetric(id: "local.cost.today", kind: .cost, scope: .local, unit: .usd, used: 2, provenance: .estimatedLocal, collectedAt: now)
        let bundle = SnapshotBundle(
            collectorID: "collector",
            revision: 1,
            snapshots: [snapshot(.codex, id: "credits", metric: credits), snapshot(.codex, id: "cost", metric: cost)],
            collectorHealth: .healthy
        )

        #expect(bundle.selectedMetric(for: .codex, preferredID: nil, at: now) == nil)
        #expect(bundle.selectedMetric(for: .codex, preferredID: bundle.presentedMetrics(for: .codex).first { $0.metric.id == credits.id }?.id, at: now)?.metric.id == credits.id)
    }

    @Test func compoundSelectionKeepsSameMetricAcrossAccountsDistinct() {
        let now = Date.now
        let metric = UsageMetric(id: "subscription.weekly", kind: .quota, scope: .subscription, unit: .fraction, used: 0.4, limit: 1, resetsAt: now.addingTimeInterval(3_600), provenance: .privateProviderEndpoint, collectedAt: now)
        let bundle = SnapshotBundle(
            collectorID: "collector",
            revision: 1,
            snapshots: [snapshot(.claude, id: "personal", metric: metric), snapshot(.claude, id: "work", metric: metric)],
            collectorHealth: .healthy
        )
        let choices = bundle.selectableMetrics(for: .claude, at: now)

        #expect(choices.count == 2)
        #expect(Set(choices.map(\.id)).count == 2)
        #expect(bundle.selectedMetric(for: .claude, preferredID: choices[1].id, at: now)?.accountID == choices[1].accountID)
    }

    private func snapshot(_ family: ProviderFamily, id: String, metric: UsageMetric) -> ProviderSnapshot {
        .init(
            account: .init(id: id, family: family, displayName: family.displayName),
            metrics: [metric],
            fetchedAt: metric.collectedAt,
            expiresAt: metric.collectedAt.addingTimeInterval(300)
        )
    }
}

#if os(iOS)
import ActivityKit
import Foundation

public struct UsageActivityAttributes: ActivityAttributes, Sendable {
    public struct ProviderSummary: Codable, Hashable, Sendable, Identifiable {
        public var id: ProviderFamily { family }
        public var family: ProviderFamily
        public var providerName: String
        public var metricLabel: String
        public var used: Decimal?
        public var limit: Decimal?
        public var available: Decimal?
        public var unit: MetricUnit
        public var resetsAt: Date?
        public var provenance: MetricProvenance
        public var expiresAt: Date

        public init(family: ProviderFamily, providerName: String, metricLabel: String, used: Decimal?, limit: Decimal?, available: Decimal?, unit: MetricUnit, resetsAt: Date?, provenance: MetricProvenance, expiresAt: Date) {
            self.family = family
            self.providerName = String(providerName.prefix(40))
            self.metricLabel = String(metricLabel.prefix(40))
            self.used = used
            self.limit = limit
            self.available = available
            self.unit = unit
            self.resetsAt = resetsAt
            self.provenance = provenance
            self.expiresAt = expiresAt
        }

        public var usedFraction: Double? {
            guard let used, let limit, limit > 0 else { return nil }
            return min(max(NSDecimalNumber(decimal: used / limit).doubleValue, 0), 1)
        }

        public var displayValue: String {
            if let fraction = usedFraction { return fraction.formatted(.percent.precision(.fractionLength(0))) }
            let value = available ?? used
            guard let value else { return "—" }
            let formatted: String = switch unit {
            case .usd: value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
            case .tokens, .requests: value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
            case .fraction: value.formatted(.percent.precision(.fractionLength(0)))
            case .credits: value.formatted(.number.precision(.fractionLength(0...2)))
            }
            return available != nil && used == nil ? "\(formatted) available" : formatted
        }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var metricID: String
        public var used: Decimal?
        public var limit: Decimal?
        public var resetsAt: Date?
        public var synchronizedAt: Date
        public var provenance: MetricProvenance
        public var isStale: Bool
        public var providers: [ProviderSummary]?

        public init(metricID: String, used: Decimal?, limit: Decimal?, resetsAt: Date?, synchronizedAt: Date, provenance: MetricProvenance, isStale: Bool) {
            self.metricID = metricID
            self.used = used
            self.limit = limit
            self.resetsAt = resetsAt
            self.synchronizedAt = synchronizedAt
            self.provenance = provenance
            self.isStale = isStale
            providers = nil
        }

        public init(providers: [ProviderSummary], synchronizedAt: Date, isStale: Bool) {
            metricID = "combined"
            used = nil
            limit = nil
            resetsAt = nil
            self.synchronizedAt = synchronizedAt
            provenance = providers.contains(where: { $0.provenance == .privateProviderEndpoint }) ? .privateProviderEndpoint : .officialAPI
            self.isStale = isStale
            self.providers = Array(providers.prefix(2))
        }
    }

    public var accountID: String
    public var providerName: String
    public var family: ProviderFamily
    public var combined: Bool?

    public init(accountID: String, providerName: String, family: ProviderFamily) {
        self.accountID = accountID
        self.providerName = providerName
        self.family = family
        combined = nil
    }

    public init(combinedCollectorID: String) {
        accountID = String(combinedCollectorID.prefix(64))
        providerName = "TinyUsage"
        family = .claude
        combined = true
    }
}

public extension SnapshotBundle {
    func activitySummaries(preferences: UsageDisplayPreferences = .init(), at date: Date = .now) -> [UsageActivityAttributes.ProviderSummary] {
        ProviderFamily.allCases.compactMap { family in
            guard let selection = selectedMetric(for: family, preferredID: preferences.metricID(for: family, surface: .liveActivity), at: date) else { return nil }
            let metric = selection.metric
            return .init(
                family: family,
                providerName: family.displayName,
                metricLabel: metric.displayName,
                used: metric.used,
                limit: metric.limit,
                available: metric.available,
                unit: metric.unit,
                resetsAt: metric.resetsAt,
                provenance: metric.provenance,
                expiresAt: selection.expiresAt
            )
        }
    }
}
#endif

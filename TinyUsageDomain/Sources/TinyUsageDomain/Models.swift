import Foundation

public enum ProviderFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }
    public var displayName: String { self == .claude ? "Claude" : "Codex" }
}

public enum MetricKind: String, Codable, Sendable {
    case tokens, cost, quota, credits, requests
}

public enum MetricScope: String, Codable, Sendable, CaseIterable {
    case subscription, officialAPI, local

    public var title: String {
        switch self {
        case .subscription: "Subscription quota"
        case .officialAPI: "Official API usage"
        case .local: "Local estimate"
        }
    }

    public var shortTitle: String {
        switch self {
        case .subscription: "Subscription"
        case .officialAPI: "API"
        case .local: "Local"
        }
    }
}

public enum MetricUnit: String, Codable, Sendable {
    case tokens, usd, fraction, credits, requests
}

public enum MetricProvenance: String, Codable, Sendable {
    case officialAPI, privateProviderEndpoint, measuredLocal, estimatedLocal

    public var label: String {
        switch self {
        case .officialAPI: "Official API"
        case .privateProviderEndpoint: "Experimental"
        case .measuredLocal: "Measured locally"
        case .estimatedLocal: "Estimated locally"
        }
    }

    public var confidence: String {
        switch self {
        case .officialAPI: "High"
        case .privateProviderEndpoint: "Experimental"
        case .measuredLocal: "High"
        case .estimatedLocal: "Estimate"
        }
    }
}

public struct UsageSourceDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let family: ProviderFamily
    public let displayName: String
    public let provenance: MetricProvenance
    public let isExperimental: Bool

    public init(id: String, family: ProviderFamily, displayName: String, provenance: MetricProvenance, isExperimental: Bool = false) {
        self.id = id
        self.family = family
        self.displayName = displayName
        self.provenance = provenance
        self.isExperimental = isExperimental
    }
}

public struct ProviderAccount: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let family: ProviderFamily
    public var displayName: String
    public var plan: String?
    public var sources: [UsageSourceDescriptor]

    public init(id: String, family: ProviderFamily, displayName: String, plan: String? = nil, sources: [UsageSourceDescriptor] = []) {
        self.id = id
        self.family = family
        self.displayName = displayName
        self.plan = plan
        self.sources = sources
    }
}

public struct UsageMetric: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: MetricKind
    public let scope: MetricScope
    public let unit: MetricUnit
    public let used: Decimal?
    public let limit: Decimal?
    public let available: Decimal?
    public let resetsAt: Date?
    public let windowSeconds: TimeInterval?
    public let provenance: MetricProvenance
    public let collectedAt: Date

    public init(id: String, kind: MetricKind, scope: MetricScope, unit: MetricUnit, used: Decimal? = nil, limit: Decimal? = nil, available: Decimal? = nil, resetsAt: Date? = nil, windowSeconds: TimeInterval? = nil, provenance: MetricProvenance, collectedAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.unit = unit
        self.used = used
        self.limit = limit
        self.available = available
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.provenance = provenance
        self.collectedAt = collectedAt
    }

    public var usedFraction: Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return min(max(NSDecimalNumber(decimal: used / limit).doubleValue, 0), 1)
    }
}

public struct ProviderWarning: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let message: String
    public let occurredAt: Date

    public init(id: String, message: String, occurredAt: Date = .now) {
        self.id = id
        self.message = message
        self.occurredAt = occurredAt
    }
}

public struct SourceError: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sourceID: String
    public let message: String
    public let occurredAt: Date
    public let isAuthenticationError: Bool

    public init(id: String = UUID().uuidString, sourceID: String, message: String, occurredAt: Date = .now, isAuthenticationError: Bool = false) {
        self.id = id
        self.sourceID = sourceID
        self.message = message
        self.occurredAt = occurredAt
        self.isAuthenticationError = isAuthenticationError
    }
}

public struct ProviderSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(account.family.rawValue):\(account.id)" }
    public let account: ProviderAccount
    public let metrics: [UsageMetric]
    public let fetchedAt: Date
    public let expiresAt: Date
    public let warnings: [ProviderWarning]
    public let sourceErrors: [SourceError]

    public init(account: ProviderAccount, metrics: [UsageMetric], fetchedAt: Date, expiresAt: Date, warnings: [ProviderWarning] = [], sourceErrors: [SourceError] = []) {
        self.account = account
        self.metrics = metrics
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.warnings = warnings
        self.sourceErrors = sourceErrors
    }

    public func freshness(at date: Date = .now) -> SnapshotFreshness {
        date <= expiresAt ? .fresh : .stale
    }
}

public enum SnapshotFreshness: String, Codable, Sendable { case fresh, stale }

public enum CollectorHealth: String, Codable, Sendable { case healthy, degraded, refreshing, offline }

public struct SnapshotBundle: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let collectorID: String
    public let revision: UInt64
    public let generatedAt: Date
    public let snapshots: [ProviderSnapshot]
    public let collectorHealth: CollectorHealth

    public init(schemaVersion: Int = currentSchemaVersion, collectorID: String, revision: UInt64, generatedAt: Date = .now, snapshots: [ProviderSnapshot], collectorHealth: CollectorHealth) {
        self.schemaVersion = schemaVersion
        self.collectorID = collectorID
        self.revision = revision
        self.generatedAt = generatedAt
        self.snapshots = snapshots
        self.collectorHealth = collectorHealth
    }

    public static let empty = SnapshotBundle(collectorID: "unpaired", revision: 0, snapshots: [], collectorHealth: .offline)
}

public struct UsageMetricSelection: Hashable, Sendable, Identifiable {
    public var id: String { "\(family.rawValue):\(snapshotID):\(metric.id)" }
    public let family: ProviderFamily
    public let snapshotID: String
    public let accountID: String
    public let accountName: String
    public let fetchedAt: Date
    public let expiresAt: Date
    public let metric: UsageMetric

    public init(family: ProviderFamily, snapshot: ProviderSnapshot, metric: UsageMetric) {
        self.family = family
        snapshotID = snapshot.id
        accountID = snapshot.account.id
        accountName = snapshot.account.displayName
        fetchedAt = snapshot.fetchedAt
        expiresAt = snapshot.expiresAt
        self.metric = metric
    }

    public func freshness(at date: Date = .now) -> SnapshotFreshness {
        date <= expiresAt ? .fresh : .stale
    }
}

public extension UsageMetric {
    var displayName: String {
        switch id {
        case "subscription.session": return "Session"
        case "subscription.weekly": return "Weekly"
        case "subscription.credits": return "Credits"
        case "subscription.rate_limit_resets": return "Rate-limit resets"
        case "subscription.extra_usage.month": return "Extra usage this month"
        case "api.tokens.input.day": return "Input tokens today"
        case "api.tokens.output.day": return "Output tokens today"
        case "api.cost.day": return "Cost today"
        case "api.cost.month": return "Cost this month"
        case "local.tokens.input.today": return "Input tokens today"
        case "local.tokens.output.today": return "Output tokens today"
        case "local.cost.today": return "Estimated cost today"
        default:
            if id.hasPrefix("subscription.model."), id.hasSuffix(".weekly") {
                let name = id
                    .replacingOccurrences(of: "subscription.model.", with: "")
                    .replacingOccurrences(of: ".weekly", with: "")
                    .replacingOccurrences(of: "-", with: " ")
                return "\(name.capitalized) weekly"
            }
            if id.hasPrefix("local.tokens.model."), id.hasSuffix(".today") {
                let name = id
                    .replacingOccurrences(of: "local.tokens.model.", with: "")
                    .replacingOccurrences(of: ".today", with: "")
                    .replacingOccurrences(of: "-", with: " ")
                return "\(name.capitalized) today"
            }
            return kind.displayName
        }
    }

    var displayValue: String {
        if unit == .fraction, let fraction = usedFraction {
            return fraction.formatted(.percent.precision(.fractionLength(0)))
        }
        if let available {
            return "\(formatted(available)) available"
        }
        guard let used else { return "—" }
        if let limit, limit > 0 {
            return "\(formatted(used)) / \(formatted(limit))"
        }
        return formatted(used)
    }

    var isPrimaryQuota: Bool {
        scope == .subscription && kind == .quota && (used != nil || available != nil)
    }

    private func formatted(_ value: Decimal) -> String {
        switch unit {
        case .usd:
            return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
        case .tokens, .requests:
            return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        case .fraction:
            return value.formatted(.percent.precision(.fractionLength(0)))
        case .credits:
            return value.formatted(.number.precision(.fractionLength(0...2)))
        }
    }
}

public extension MetricKind {
    var displayName: String {
        switch self {
        case .tokens: "Tokens"
        case .cost: "Cost"
        case .quota: "Quota"
        case .credits: "Credits"
        case .requests: "Requests"
        }
    }
}

public extension SnapshotBundle {
    func snapshots(for family: ProviderFamily) -> [ProviderSnapshot] {
        snapshots
            .filter { $0.account.family == family }
            .sorted {
                if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt > $1.fetchedAt }
                return $0.account.displayName.localizedCaseInsensitiveCompare($1.account.displayName) == .orderedAscending
            }
    }

    func presentedMetrics(for family: ProviderFamily, scope: MetricScope? = nil) -> [UsageMetricSelection] {
        snapshots(for: family).flatMap { snapshot in
            snapshot.metrics
                .filter { scope == nil || $0.scope == scope }
                .map { UsageMetricSelection(family: family, snapshot: snapshot, metric: $0) }
        }.sorted { lhs, rhs in
            let left = metricPriority(lhs.metric)
            let right = metricPriority(rhs.metric)
            if left != right { return left < right }
            if lhs.metric.collectedAt != rhs.metric.collectedAt { return lhs.metric.collectedAt > rhs.metric.collectedAt }
            if lhs.accountName != rhs.accountName {
                return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    func selectableMetrics(for family: ProviderFamily, at date: Date = .now) -> [UsageMetricSelection] {
        presentedMetrics(for: family).filter {
            ($0.metric.used != nil || $0.metric.available != nil) &&
            ($0.metric.resetsAt.map { $0 > date } ?? true)
        }
    }

    func primaryMetric(for family: ProviderFamily, at date: Date = .now) -> UsageMetricSelection? {
        presentedMetrics(for: family, scope: .subscription).first {
            $0.metric.isPrimaryQuota && ($0.metric.resetsAt.map { $0 > date } ?? true)
        }
    }

    func selectedMetric(for family: ProviderFamily, preferredID: String?, at date: Date = .now) -> UsageMetricSelection? {
        let available = selectableMetrics(for: family, at: date)
        if let preferredID,
           let selected = available.first(where: { $0.id == preferredID || $0.metric.id == preferredID }) {
            return selected
        }
        return primaryMetric(for: family, at: date)
    }

    private func metricPriority(_ metric: UsageMetric) -> Int {
        switch metric.id {
        case "subscription.session": 0
        case "subscription.weekly": 1
        default:
            if metric.isPrimaryQuota { 2 }
            else if metric.scope == .subscription { 3 }
            else if metric.scope == .officialAPI { 4 }
            else { 5 }
        }
    }
}

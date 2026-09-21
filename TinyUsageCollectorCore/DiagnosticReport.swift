import Foundation
import TinyUsageDomain

public struct DiagnosticReport: Codable, Sendable {
    public struct Provider: Codable, Sendable {
        public let family: ProviderFamily
        public let sourceIDs: [String]
        public let metricIDs: [String]
        public let warnings: [String]
        public let errors: [String]
    }

    public let generatedAt: Date
    public let schemaVersion: Int
    public let revision: UInt64
    public let health: CollectorHealth
    public let providers: [Provider]

    public init(bundle: SnapshotBundle, generatedAt: Date = .now) {
        self.generatedAt = generatedAt
        schemaVersion = bundle.schemaVersion
        revision = bundle.revision
        health = bundle.collectorHealth
        providers = bundle.snapshots.map {
            Provider(
                family: $0.account.family,
                sourceIDs: $0.account.sources.map(\.id),
                metricIDs: $0.metrics.map(\.id),
                warnings: $0.warnings.map(\.id),
                errors: $0.sourceErrors.map { $0.isAuthenticationError ? "\($0.sourceID):authentication" : "\($0.sourceID):collection" }
            )
        }
    }

    public func encoded() throws -> Data { try JSONEncoder.tinyUsage.encode(self) }

}

import Foundation
import TinyUsageDomain

public enum ProviderAggregator {
    public static func aggregate(successes: [SourceSnapshot], failures: [String: Error], lastGood: [String: SourceSnapshot], now: Date = .now) -> [ProviderSnapshot] {
        var selected = Dictionary(uniqueKeysWithValues: successes.map { ($0.source.id, $0) })
        for (sourceID, cached) in lastGood where selected[sourceID] == nil { selected[sourceID] = cached }
        let grouped = Dictionary(grouping: selected.values, by: { "\($0.source.family.rawValue):\($0.accountID)" })

        return grouped.values.map { sourceSnapshots in
            let first = sourceSnapshots[0]
            let descriptors = sourceSnapshots.map(\.source).sorted { $0.id < $1.id }
            let errors = failures.compactMap { sourceID, error -> SourceError? in
                guard descriptors.contains(where: { $0.id == sourceID }) else { return nil }
                return SourceError(sourceID: sourceID, message: error.localizedDescription, occurredAt: now, isAuthenticationError: error as? ConnectorError == .invalidCredential)
            }
            let account = ProviderAccount(id: first.accountID, family: first.source.family, displayName: first.accountDisplayName, plan: first.plan, sources: descriptors)
            return ProviderSnapshot(
                account: account,
                metrics: sourceSnapshots.flatMap(\.metrics).sorted { $0.id < $1.id },
                fetchedAt: sourceSnapshots.map(\.fetchedAt).max() ?? now,
                expiresAt: sourceSnapshots.map(\.expiresAt).min() ?? now,
                warnings: sourceSnapshots.flatMap(\.warnings),
                sourceErrors: errors
            )
        }.sorted { $0.account.displayName < $1.account.displayName }
    }
}

extension ConnectorError: Equatable {
    public static func == (lhs: ConnectorError, rhs: ConnectorError) -> Bool {
        switch (lhs, rhs) {
        case (.missingCredential, .missingCredential), (.invalidCredential, .invalidCredential), (.insufficientScope, .insufficientScope), (.invalidResponse, .invalidResponse), (.timedOut, .timedOut): true
        case (.provider(let a), .provider(let b)): a == b
        default: false
        }
    }
}

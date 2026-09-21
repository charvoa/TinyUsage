import Foundation
import TinyUsageDomain

public actor CollectionOrchestrator {
    private var connectors: [any UsageSourceConnector]
    private let repository: any SnapshotRepository
    private var revision: UInt64
    private var failureCount: [String: Int] = [:]
    private var retryAfter: [String: Date] = [:]
    private var lastErrors: [String: Error] = [:]

    public init(connectors: [any UsageSourceConnector], repository: any SnapshotRepository, initialRevision: UInt64 = 0) {
        self.connectors = connectors
        self.repository = repository
        self.revision = initialRevision
    }

    public func updateConnectors(_ connectors: [any UsageSourceConnector]) {
        self.connectors = connectors
        let activeIDs = Set(connectors.map(\.descriptor.id))
        failureCount = failureCount.filter { activeIDs.contains($0.key) }
        retryAfter = retryAfter.filter { activeIDs.contains($0.key) }
        lastErrors = lastErrors.filter { activeIDs.contains($0.key) }
    }

    public func collect(collectorID: String, now: Date = .now) async -> SnapshotBundle {
        let eligible = connectors.filter { retryAfter[$0.descriptor.id, default: .distantPast] <= now }
        let backedOff = connectors.filter { retryAfter[$0.descriptor.id, default: .distantPast] > now }
        let results = await withTaskGroup(of: (String, Result<SourceSnapshot, Error>).self) { group in
            for connector in eligible {
                group.addTask {
                    do {
                        let value = try await withThrowingTaskGroup(of: SourceSnapshot.self) { timeoutGroup in
                            timeoutGroup.addTask { try await connector.fetch(context: .init(now: now)) }
                            timeoutGroup.addTask {
                                try await Task.sleep(for: .seconds(15))
                                throw ConnectorError.timedOut
                            }
                            let first = try await timeoutGroup.next()!
                            timeoutGroup.cancelAll()
                            return first
                        }
                        return (connector.descriptor.id, .success(value))
                    } catch { return (connector.descriptor.id, .failure(error)) }
                }
            }
            return await group.reduce(into: [(String, Result<SourceSnapshot, Error>)]()) { $0.append($1) }
        }

        var successes: [SourceSnapshot] = []
        var failures: [String: Error] = [:]
        var cached: [String: SourceSnapshot] = [:]
        for connector in backedOff {
            let sourceID = connector.descriptor.id
            cached[sourceID] = await repository.lastGood(for: sourceID)
            failures[sourceID] = lastErrors[sourceID] ?? ConnectorError.timedOut
            if cached[sourceID] == nil {
                cached[sourceID] = Self.errorPlaceholder(for: connector.descriptor, now: now)
            }
        }
        for (sourceID, result) in results {
            switch result {
            case .success(let snapshot):
                successes.append(snapshot)
                try? await repository.commit(snapshot)
                failureCount[sourceID] = 0
                retryAfter[sourceID] = nil
                lastErrors[sourceID] = nil
            case .failure(let error):
                failures[sourceID] = error
                lastErrors[sourceID] = error
                let count = failureCount[sourceID, default: 0] + 1
                failureCount[sourceID] = count
                retryAfter[sourceID] = now.addingTimeInterval(min(pow(2, Double(count)) * 30, 30 * 60))
                cached[sourceID] = await repository.lastGood(for: sourceID)
                if cached[sourceID] == nil, let descriptor = connectors.first(where: { $0.descriptor.id == sourceID })?.descriptor {
                    cached[sourceID] = Self.errorPlaceholder(for: descriptor, now: now)
                }
            }
        }
        revision &+= 1
        let snapshots = ProviderAggregator.aggregate(successes: successes, failures: failures, lastGood: cached, now: now)
        return SnapshotBundle(collectorID: collectorID, revision: revision, generatedAt: now, snapshots: snapshots, collectorHealth: failures.isEmpty ? .healthy : .degraded)
    }

    private static func errorPlaceholder(for descriptor: UsageSourceDescriptor, now: Date) -> SourceSnapshot {
        SourceSnapshot(
            source: descriptor,
            accountID: "\(descriptor.family.rawValue)-source-\(descriptor.id)",
            accountDisplayName: descriptor.family.displayName,
            metrics: [],
            fetchedAt: now,
            expiresAt: now
        )
    }
}

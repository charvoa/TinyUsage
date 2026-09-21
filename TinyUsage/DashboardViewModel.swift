import ActivityKit
import Network
import SwiftUI
import TinyUsageDomain
import WidgetKit

enum CompanionState: Equatable {
    case collectorNotInstalled, searching, localNetworkDenied, synchronized, offline, stale, incompatibleVersion
    var label: String {
        switch self {
        case .collectorNotInstalled: "Collector not paired"
        case .searching: "Searching for Mac…"
        case .localNetworkDenied: "Local network access denied"
        case .synchronized: "Synchronized"
        case .offline: "Mac offline"
        case .stale: "Local data is stale"
        case .incompatibleVersion: "Incompatible protocol version"
        }
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var bundle: SnapshotBundle
    @Published private(set) var connectionState: CompanionState
    @Published var presentedError: String?
    @Published var pairingCode = ""
    @Published private(set) var awaitingPairingApproval = false
    @Published var showLegacyCleanup = false
    @Published var selectedAccountID: String?
    @Published private(set) var isLiveActivityActive = false
    @Published private(set) var displayPreferences: UsageDisplayPreferences
    private let store: SnapshotBundleStore?
    private let displayPreferencesStore = UsageDisplayPreferencesStore(appGroupIdentifier: TinyUsageConstants.appGroup)
    private let credentials = PairingCredentialStore()
    private let client = BonjourSyncClient()
    private var activityOperationInFlight = false
    private var activityReconcileRequested = false
    private var desiredActivityActive: Bool

    init() {
        store = try? SnapshotBundleStore(appGroupIdentifier: TinyUsageConstants.appGroup)
        let cached = (try? store?.load()) ?? .empty
        bundle = cached
        displayPreferences = displayPreferencesStore.load()
        connectionState = (try? credentials.load()) == nil ? .collectorNotInstalled : (cached.snapshots.isEmpty ? .offline : .stale)
        let hasActivity = !Activity<UsageActivityAttributes>.activities.isEmpty
        isLiveActivityActive = hasActivity
        desiredActivityActive = hasActivity
    }

    func pair(code: String? = nil) async {
        awaitingPairingApproval = false
        do {
            let payload = try PairingPayload.decode(code: Self.code(from: code ?? pairingCode))
            guard !payload.isExpired else { throw SyncProtocolError.unauthorized }
            try credentials.save(payload)
            pairingCode = ""
            awaitingPairingApproval = true
            showLegacyCleanup = await synchronize()
        } catch { presentedError = error.localizedDescription }
    }

    func prepareForPairing() { client.prepareLocalNetworkAccess() }

    @discardableResult
    func synchronize(requestRefresh: Bool = false) async -> Bool {
        guard let pairing = try? credentials.load() else { connectionState = .collectorNotInstalled; return false }
        connectionState = .searching
        do {
            let lastRevision: UInt64? = bundle.snapshots.isEmpty ? nil : bundle.revision
            let isPending = credentials.hasPending(identity: pairing.pskIdentity)
            switch try await client.synchronize(pairing: pairing, awaitingApproval: isPending, lastRevision: lastRevision, requestRefresh: requestRefresh, timeout: requestRefresh ? .seconds(30) : .seconds(8)) {
            case .snapshotBundle(let incoming):
                guard incoming.schemaVersion == SnapshotBundle.currentSchemaVersion, incoming.collectorID == pairing.collectorID else { throw SyncProtocolError.incompatibleVersion }
                guard let store else { throw SyncProtocolError.unavailable("The shared App Group container is unavailable.") }
                try store.save(incoming)
                bundle = incoming
            case .notModified: break
            case .pairingPending:
                awaitingPairingApproval = true
                connectionState = .offline
                presentedError = nil
                return false
            case .error(let error): throw error
            default: throw SyncProtocolError.malformedFrame
            }
            connectionState = bundle.snapshots.contains(where: { $0.freshness() == .stale }) ? .stale : .synchronized
            WidgetCenter.shared.reloadAllTimelines()
            await updateActivities()
            if credentials.hasPending(identity: pairing.pskIdentity) { try credentials.promotePending() }
            awaitingPairingApproval = false
            return true
        } catch SyncProtocolError.incompatibleVersion { connectionState = .incompatibleVersion }
        catch SyncProtocolError.unauthorized {
            connectionState = .offline
            awaitingPairingApproval = credentials.hasPending(identity: pairing.pskIdentity)
            presentedError = "Approve this iPhone in TinyUsage Collector on your Mac, then pull to refresh."
        }
        catch let error as NWError {
            switch error {
            case .posix(let code) where code == .EPERM: connectionState = .localNetworkDenied
            case .dns(let code) where code == -65570: connectionState = .localNetworkDenied
            default: connectionState = .offline
            }
        }
        catch {
            connectionState = .offline
            if awaitingPairingApproval {
                presentedError = "The secure connection to the Mac failed: \(error.localizedDescription)"
            }
        }
        return false
    }

    func revoke() async {
        await stopCombinedActivity()
        guard let pairing = try? credentials.load() else { connectionState = .collectorNotInstalled; return }
        do {
            try await client.revoke(pairing: pairing)
            try credentials.delete()
            awaitingPairingApproval = false
            bundle = .empty
            try? store?.save(.empty)
            WidgetCenter.shared.reloadAllTimelines()
            connectionState = .collectorNotInstalled
        } catch {
            presentedError = "The Mac could not confirm revocation. Try again while it is reachable."
        }
    }

    func startCombinedActivity() async {
        desiredActivityActive = true
        activityReconcileRequested = true
        await reconcileActivityState()
    }

    func stopCombinedActivity() async {
        desiredActivityActive = false
        activityReconcileRequested = true
        await reconcileActivityState()
    }

    func refreshActivityStatus() {
        let hasActivity = !Activity<UsageActivityAttributes>.activities.isEmpty
        isLiveActivityActive = hasActivity
        desiredActivityActive = hasActivity
    }

    func availableMetrics(for family: ProviderFamily) -> [UsageMetricSelection] {
        bundle.selectableMetrics(for: family)
    }

    func preferredMetricID(for family: ProviderFamily, surface: UsageDisplaySurface) -> String {
        guard let stored = displayPreferences.metricID(for: family, surface: surface),
              let selection = availableMetrics(for: family).first(where: { $0.id == stored || $0.metric.id == stored })
        else { return "" }
        return selection.id
    }

    func setPreferredMetricID(_ metricID: String, for family: ProviderFamily, surface: UsageDisplaySurface) {
        var updated = displayPreferences
        updated.setMetricID(metricID.isEmpty ? nil : metricID, for: family, surface: surface)
        do {
            try displayPreferencesStore.save(updated)
            displayPreferences = updated
            WidgetCenter.shared.reloadAllTimelines()
            if surface == .liveActivity, isLiveActivityActive {
                Task { await updateActivities() }
            }
        } catch {
            presentedError = "Display preferences could not be saved: \(error.localizedDescription)"
        }
    }

    private func updateActivities() async {
        guard desiredActivityActive || !Activity<UsageActivityAttributes>.activities.isEmpty else {
            isLiveActivityActive = false
            return
        }
        desiredActivityActive = true
        activityReconcileRequested = true
        await reconcileActivityState()
    }

    private func reconcileActivityState() async {
        guard !activityOperationInFlight else { return }
        activityOperationInFlight = true
        defer {
            let shouldReconcileAgain = activityReconcileRequested
            activityOperationInFlight = false
            isLiveActivityActive = !Activity<UsageActivityAttributes>.activities.isEmpty
            // A tap or sync can arrive while ActivityKit is awaiting a request.
            // Re-run once with the latest desired state instead of dropping it.
            if shouldReconcileAgain {
                Task { await reconcileActivityState() }
            }
        }

        repeat {
            activityReconcileRequested = false
            if desiredActivityActive {
                guard let content = combinedActivityContent() else {
                    desiredActivityActive = false
                    presentedError = "No current Claude or Codex subscription quota is available."
                    continue
                }
                do {
                    let attributes = UsageActivityAttributes(combinedCollectorID: bundle.collectorID)
                    guard activityPayloadSize(attributes: attributes, state: content.state) < 4_096 else {
                        throw SyncProtocolError.frameTooLarge
                    }
                    try await Self.upsertCombinedActivity(attributes: attributes, state: content.state, staleDate: content.staleDate)
                } catch {
                    presentedError = error.localizedDescription
                }
            } else {
                await Self.endAllActivities()
            }
        } while activityReconcileRequested
    }

    private func combinedActivityContent(now: Date = .now) -> ActivityContent<UsageActivityAttributes.ContentState>? {
        let summaries = bundle.activitySummaries(preferences: displayPreferences, at: now)
        guard !summaries.isEmpty else { return nil }
        let state = UsageActivityAttributes.ContentState(
            providers: summaries,
            synchronizedAt: bundle.generatedAt,
            isStale: summaries.contains { $0.expiresAt <= now }
        )
        return .init(state: state, staleDate: summaries.map(\.expiresAt).min())
    }

    private func activityPayloadSize(attributes: UsageActivityAttributes, state: UsageActivityAttributes.ContentState) -> Int {
        let encoder = JSONEncoder()
        return ((try? encoder.encode(attributes).count) ?? 4_096) + ((try? encoder.encode(state).count) ?? 4_096)
    }

    private nonisolated static func upsertCombinedActivity(attributes: UsageActivityAttributes, state: UsageActivityAttributes.ContentState, staleDate: Date?) async throws {
        let activities = Activity<UsageActivityAttributes>.activities
        let content = ActivityContent(state: state, staleDate: staleDate)
        if let keeper = activities.first(where: { $0.attributes.combined == true }) {
            for duplicate in activities where duplicate.id != keeper.id {
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }
            await keeper.update(content)
            return
        }
        for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
        _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    private nonisolated static func endAllActivities() async {
        for activity in Activity<UsageActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func route(_ url: URL) {
        guard url.scheme == "tinyusage" else { return }
        if url.host == "account" { selectedAccountID = url.pathComponents.dropFirst().first }
        if url.host == "dashboard" { selectedAccountID = nil }
    }

    private static func code(from value: String) -> String {
        guard let components = URLComponents(string: value), components.scheme == "tinyusage" else { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        return components.queryItems?.first(where: { $0.name == "code" })?.value ?? value
    }
}

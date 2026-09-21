import SwiftUI
import TinyUsageDomain

struct DashboardView: View {
    @EnvironmentObject private var model: DashboardViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPairing = false
    @State private var showingDisplaySettings = false

    var body: some View {
        NavigationStack {
            Group {
                if model.connectionState == .collectorNotInstalled { onboarding }
                else { dashboard }
            }
            .navigationTitle("TinyUsage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Display settings", systemImage: "slider.horizontal.3") { showingDisplaySettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair", systemImage: "qrcode") { showingPairing = true }
                }
            }
            .sheet(isPresented: $showingPairing) { PairingView() }
            .sheet(isPresented: $showingDisplaySettings) { UsageDisplaySettingsView() }
            .sheet(isPresented: $model.showLegacyCleanup) { LegacyCredentialCleanupView() }
            .alert("TinyUsage", isPresented: .init(get: { model.presentedError != nil }, set: { if !$0 { model.presentedError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.presentedError ?? "")
            }
            .task { _ = await model.synchronize() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.refreshActivityStatus()
                    Task { _ = await model.synchronize() }
                }
            }
        }
    }

    private var dashboard: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ConnectionBanner(state: model.connectionState, generatedAt: model.bundle.generatedAt)

                    if model.isLiveActivityActive || !model.bundle.snapshots.isEmpty {
                        LiveActivityControl(isActive: model.isLiveActivityActive, configure: { showingDisplaySettings = true }) {
                            Task {
                                if model.isLiveActivityActive { await model.stopCombinedActivity() }
                                else { await model.startCombinedActivity() }
                            }
                        }
                    }

                    ForEach(ProviderFamily.allCases) { family in
                        let snapshots = model.bundle.snapshots(for: family)
                        if !snapshots.isEmpty {
                            ProviderFamilySection(family: family, snapshots: snapshots)
                        } else if !model.bundle.snapshots.isEmpty {
                            EmptyProviderFamilySection(family: family)
                        }
                    }

                    if model.bundle.snapshots.isEmpty {
                        ContentUnavailableView(
                            "No usage data",
                            systemImage: "chart.bar.xaxis",
                            description: Text("The collector has not produced a snapshot yet.")
                        )
                    }

                    Text("Last known data · synchronized \(model.bundle.generatedAt.formatted(.relative(presentation: .named)))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .refreshable { _ = await model.synchronize(requestRefresh: true) }
            .onChange(of: model.selectedAccountID) { _, accountID in
                guard let accountID, let snapshot = model.bundle.snapshots.first(where: { $0.account.id == accountID }) else { return }
                withAnimation { proxy.scrollTo(snapshot.id, anchor: .top) }
            }
        }
    }

    private var onboarding: some View {
        ContentUnavailableView {
            Label("Install the Mac collector", systemImage: "macbook.and.iphone")
        } description: {
            Text("TinyUsage keeps provider credentials on your Mac. Open Pair an iPhone in the collector, then scan its QR code here.")
        } actions: {
            Button("Pair with Mac") { showingPairing = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct ConnectionBanner: View {
    let state: CompanionState
    let generatedAt: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(state.label).font(.subheadline.weight(.semibold))
                Text("Last sync \(generatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var tint: Color { state == .synchronized ? .green : .orange }
    private var icon: String {
        switch state {
        case .synchronized: "checkmark.circle.fill"
        case .searching: "antenna.radiowaves.left.and.right"
        case .collectorNotInstalled: "link.badge.plus"
        default: "exclamationmark.triangle.fill"
        }
    }
}

private struct LiveActivityControl: View {
    let isActive: Bool
    let configure: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "waveform.circle.fill" : "waveform.circle")
                .font(.title2)
                .foregroundStyle(isActive ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Activity").font(.subheadline.weight(.semibold))
                Text(isActive ? "Your selected metrics are visible on the Lock Screen." : "Follow your selected metrics in one activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Configure", systemImage: "slider.horizontal.3", action: configure)
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .accessibilityLabel("Configure displayed metrics")
            Button(isActive ? "Stop" : "Start", action: action)
                .buttonStyle(.borderedProminent)
                .tint(isActive ? .red : .accentColor)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct UsageDisplaySettingsView: View {
    @EnvironmentObject private var model: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose the primary metric shown for each provider. Widget and Live Activity choices are independent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(UsageDisplaySurface.allCases, id: \.self) { surface in
                    Section(surface.title) {
                        ForEach(ProviderFamily.allCases) { family in
                            Picker(family.displayName, selection: binding(family: family, surface: surface)) {
                                Text("Automatic · Session first").tag("")
                                ForEach(model.availableMetrics(for: family)) { selection in
                                    Text(optionLabel(selection, in: family))
                                        .tag(selection.id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Displayed metrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func binding(family: ProviderFamily, surface: UsageDisplaySurface) -> Binding<String> {
        .init(
            get: { model.preferredMetricID(for: family, surface: surface) },
            set: { model.setPreferredMetricID($0, for: family, surface: surface) }
        )
    }

    private func optionLabel(_ selection: UsageMetricSelection, in family: ProviderFamily) -> String {
        let sameMetricCount = model.availableMetrics(for: family).filter { $0.metric.id == selection.metric.id }.count
        let source = sameMetricCount > 1 ? " · \(selection.accountName)" : ""
        return "\(selection.metric.displayName) · \(selection.metric.scope.shortTitle) · \(selection.metric.provenance.label)\(source)"
    }
}

private struct EmptyProviderFamilySection: View {
    let family: ProviderFamily

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: family == .claude ? "sparkles" : "terminal")
                .foregroundStyle(family == .claude ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(family.displayName).font(.headline)
                Text("No usage data").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct ProviderFamilySection: View {
    let family: ProviderFamily
    let snapshots: [ProviderSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: family == .claude ? "sparkles" : "terminal")
                    .foregroundStyle(family == .claude ? .orange : .green)
                Text(family.displayName).font(.title3.bold())
                Spacer()
                Text("\(snapshots.count) source\(snapshots.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshots) { snapshot in
                ProviderCard(snapshot: snapshot).id(snapshot.id)
            }
        }
    }
}

private struct ProviderCard: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.account.displayName).font(.headline)
                    if let plan = snapshot.account.plan {
                        Text(plan).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                FreshnessBadge(freshness: snapshot.freshness())
            }

            ForEach(MetricScope.allCases, id: \.self) { scope in
                let metrics = snapshot.metrics.filter { $0.scope == scope }
                if !metrics.isEmpty { MetricSection(scope: scope, metrics: metrics) }
            }

            ForEach(snapshot.warnings) { warning in
                NoticeRow(icon: "exclamationmark.circle", message: warning.message, tint: .orange)
            }
            ForEach(snapshot.sourceErrors) { error in
                NoticeRow(icon: "xmark.circle", message: error.message, tint: .red)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        }
    }
}

private struct MetricSection: View {
    let scope: MetricScope
    let metrics: [UsageMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scope.title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            ForEach(metrics) { metric in
                MetricRow(metric: metric)
                if metric.id != metrics.last?.id { Divider() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MetricRow: View {
    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.displayName).font(.subheadline.weight(.medium))
                Spacer()
                Text(metric.displayValue).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            if let fraction = metric.usedFraction {
                ProgressView(value: fraction).tint(fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .accentColor)
            }
            HStack(spacing: 5) {
                Text(metric.provenance.label)
                Spacer()
                Text(metric.collectedAt, style: .relative)
                if let reset = metric.resetsAt, reset > .now {
                    Text("· resets")
                    Text(reset, style: .relative)
                }
            }
            .font(.caption2)
            .foregroundStyle(metric.provenance == .privateProviderEndpoint ? .orange : .secondary)
        }
    }
}

private struct FreshnessBadge: View {
    let freshness: SnapshotFreshness
    var body: some View {
        Text(freshness == .fresh ? "Fresh" : "Stale")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(freshness == .fresh ? .green : .orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((freshness == .fresh ? Color.green : .orange).opacity(0.12), in: Capsule())
    }
}

private struct NoticeRow: View {
    let icon: String
    let message: String
    let tint: Color
    var body: some View {
        Label(message, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
    }
}

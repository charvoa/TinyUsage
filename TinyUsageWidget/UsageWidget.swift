import SwiftUI
import TinyUsageDomain
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let bundle: SnapshotBundle
    let preferences: UsageDisplayPreferences
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .init(date: .now, bundle: .empty, preferences: .init()) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let current = entry()
        let regularRefresh = current.date.addingTimeInterval(15 * 60)
        let nextReset = ProviderFamily.allCases.compactMap { family in
            current.bundle.selectedMetric(
                for: family,
                preferredID: current.preferences.metricID(for: family, surface: .widget),
                at: current.date
            )?.metric.resetsAt
        }.filter { $0 > current.date }.min()
        completion(.init(entries: [current], policy: .after(min(regularRefresh, nextReset ?? regularRefresh))))
    }
    private func entry() -> UsageEntry {
        let store = try? SnapshotBundleStore(appGroupIdentifier: TinyUsageConstants.appGroup)
        let preferences = UsageDisplayPreferencesStore(appGroupIdentifier: TinyUsageConstants.appGroup).load()
        return .init(date: .now, bundle: (try? store?.load()) ?? .empty, preferences: preferences)
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TinyUsageSummary", provider: UsageTimelineProvider()) {
            UsageWidgetView(entry: $0).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage summary")
        .description("Last known Claude and Codex usage from your Mac collector.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: widgetFamily == .systemSmall ? 8 : 10) {
            if entry.bundle.snapshots.isEmpty {
                Spacer()
                Label("Open TinyUsage to sync", systemImage: "macbook.and.iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                switch widgetFamily {
                case .systemSmall: smallContent
                case .systemMedium: mediumContent
                default: largeContent
                }
            }
        }
        .widgetURL(URL(string: "tinyusage://dashboard"))
    }

    private var smallContent: some View {
        VStack(spacing: 8) {
            ProviderCompactRow(family: .claude, selection: selected(.claude), now: entry.date)
            Divider()
            ProviderCompactRow(family: .codex, selection: selected(.codex), now: entry.date)
        }
    }

    private var mediumContent: some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderQuotaPanel(family: .claude, selection: selected(.claude), now: entry.date)
            Divider()
            ProviderQuotaPanel(family: .codex, selection: selected(.codex), now: entry.date)
        }
    }

    private var largeContent: some View {
        VStack(spacing: 10) {
            ProviderDetailPanel(family: .claude, selection: selected(.claude), bundle: entry.bundle, now: entry.date)
            Divider()
            ProviderDetailPanel(family: .codex, selection: selected(.codex), bundle: entry.bundle, now: entry.date)
            Spacer(minLength: 0)
            Label("Last known data · widget has no network access", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func selected(_ family: ProviderFamily) -> UsageMetricSelection? {
        entry.bundle.selectedMetric(
            for: family,
            preferredID: entry.preferences.metricID(for: family, surface: .widget),
            at: entry.date
        )
    }
}

private struct ProviderCompactRow: View {
    let family: ProviderFamily
    let selection: UsageMetricSelection?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProviderLabel(family: family)
                Spacer()
                if let selection {
                    Text(selection.metric.displayValue).font(.subheadline.bold()).monospacedDigit()
                } else {
                    Text("No quota").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let selection {
                if let fraction = selection.metric.usedFraction { ProgressView(value: fraction).tint(family.tint) }
                HStack {
                    Text(selection.metric.displayName)
                    Spacer()
                    MetricTiming(selection: selection, now: now)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProviderQuotaPanel: View {
    let family: ProviderFamily
    let selection: UsageMetricSelection?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProviderLabel(family: family)
            if let selection {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(selection.metric.displayName).foregroundStyle(.secondary)
                        Spacer()
                        Text(selection.metric.displayValue).bold().monospacedDigit()
                    }
                    if let fraction = selection.metric.usedFraction { ProgressView(value: fraction).tint(family.tint) }
                }
                .font(.caption)
            } else { Text("No selected metric").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            if let selection { MetricTiming(selection: selection, now: now) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct ProviderDetailPanel: View {
    let family: ProviderFamily
    let selection: UsageMetricSelection?
    let bundle: SnapshotBundle
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                ProviderLabel(family: family)
                Spacer()
                if let selection { MetricTiming(selection: selection, now: now) }
            }
            if let selection {
                HStack(alignment: .firstTextBaseline) {
                    Text(selection.metric.displayName).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(selection.metric.displayValue).font(.title3.bold()).monospacedDigit()
                }
                if let fraction = selection.metric.usedFraction { ProgressView(value: fraction).tint(family.tint) }
            }
            HStack(alignment: .top, spacing: 12) {
                DetailColumn(title: "SUBSCRIPTION", metrics: Array(bundle.presentedMetrics(for: family, scope: .subscription).prefix(2)))
                DetailColumn(title: "API", metrics: Array(bundle.presentedMetrics(for: family, scope: .officialAPI).prefix(2)))
                DetailColumn(title: "LOCAL", metrics: Array(bundle.presentedMetrics(for: family, scope: .local).prefix(2)))
            }
            if let error = snapshots.flatMap(\.sourceErrors).first {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    private var snapshots: [ProviderSnapshot] { bundle.snapshots(for: family) }
}

private struct DetailColumn: View {
    let title: String
    let metrics: [UsageMetricSelection]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            if metrics.isEmpty {
                Text("—").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(metrics) { selection in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(selection.metric.displayName).lineLimit(1)
                        Text(selection.metric.displayValue).bold().monospacedDigit().lineLimit(1)
                        Text(selection.accountName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderLabel: View {
    let family: ProviderFamily
    var body: some View {
        Label(family.displayName, systemImage: family == .claude ? "sparkles" : "terminal")
            .font(.subheadline.bold())
            .foregroundStyle(family.tint)
    }
}

private struct MetricTiming: View {
    let selection: UsageMetricSelection
    let now: Date

    @ViewBuilder
    var body: some View {
        if selection.expiresAt <= now {
            Label("Stale", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        } else if let reset = selection.metric.resetsAt, reset > now {
            Text("Resets \(reset, style: .relative)")
                .foregroundStyle(.secondary)
        }
    }
}

private extension ProviderFamily {
    var tint: Color { self == .claude ? .orange : .green }
}

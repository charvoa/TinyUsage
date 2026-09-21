import ActivityKit
import SwiftUI
import TinyUsageDomain
import WidgetKit

struct UsageLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UsageActivityAttributes.self) { context in
            lockScreenContent(context: context)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .activityBackgroundTint(.black.opacity(0.9))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "tinyusage://dashboard"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    expandedContent(context: context)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            } compactLeading: {
                compactIcons(state: context.state, attributes: context.attributes)
            } compactTrailing: {
                compactValue(context.state)
            } minimal: {
                providerIcon(context.state.providers?.first?.family ?? context.attributes.family)
            }
            .widgetURL(URL(string: "tinyusage://dashboard"))
        }
    }

    @ViewBuilder
    private func lockScreenContent(context: ActivityViewContext<UsageActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let providers = context.state.providers, !providers.isEmpty {
                ForEach(providers) { summary in
                    ProviderActivityRow(summary: summary, globallyStale: context.isStale)
                }
            } else {
                legacyContent(attributes: context.attributes, state: context.state)
            }
        }
    }

    @ViewBuilder
    private func expandedContent(context: ActivityViewContext<UsageActivityAttributes>) -> some View {
        if let providers = context.state.providers, !providers.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                ForEach(providers) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { providerIcon(summary.family); Text(summary.providerName).font(.subheadline.bold()) }
                        Text(summary.metricLabel).font(.caption).foregroundStyle(.secondary)
                        Text(summary.displayValue).font(.title3.bold()).monospacedDigit()
                        if let reset = summary.resetsAt, reset > .now {
                            Text("Resets \(reset, style: .relative)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            legacyContent(attributes: context.attributes, state: context.state)
        }
    }

    private func legacyContent(attributes: UsageActivityAttributes, state: UsageActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { providerIcon(attributes.family); Text(attributes.providerName).font(.headline); Spacer() }
            if let used = state.used, let limit = state.limit, limit > 0 {
                ProgressView(value: NSDecimalNumber(decimal: used / limit).doubleValue)
            }
            HStack {
                legacyValue(state).font(.title3.bold())
                Spacer()
                if let reset = state.resetsAt, reset > .now {
                    Text("Resets \(reset, style: .relative)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func compactValue(_ state: UsageActivityAttributes.ContentState) -> Text {
        guard let providers = state.providers, !providers.isEmpty else { return legacyValue(state) }
        let fractions = providers.compactMap(\.usedFraction)
        if let highest = fractions.max() {
            return Text(highest, format: .percent.precision(.fractionLength(0)))
        }
        return Text(providers[0].displayValue)
    }

    @ViewBuilder
    private func compactIcons(state: UsageActivityAttributes.ContentState, attributes: UsageActivityAttributes) -> some View {
        if let providers = state.providers, !providers.isEmpty {
            HStack(spacing: -2) {
                ForEach(providers) { providerIcon($0.family) }
            }
        } else {
            providerIcon(attributes.family)
        }
    }

    private func legacyValue(_ state: UsageActivityAttributes.ContentState) -> Text {
        if let used = state.used, let limit = state.limit, limit > 0 {
            return Text(NSDecimalNumber(decimal: used / limit).doubleValue, format: .percent.precision(.fractionLength(0)))
        }
        if let used = state.used { return Text(used.formatted()) }
        return Text("—")
    }

    private func providerIcon(_ family: ProviderFamily) -> some View {
        Image(systemName: family == .claude ? "sparkles" : "terminal")
            .foregroundStyle(family == .claude ? .orange : .green)
    }
}

private struct ProviderActivityRow: View {
    let summary: UsageActivityAttributes.ProviderSummary
    let globallyStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(summary.providerName, systemImage: summary.family == .claude ? "sparkles" : "terminal")
                    .font(.subheadline.bold())
                    .foregroundStyle(summary.family == .claude ? .orange : .green)
                Text(summary.metricLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(summary.displayValue).font(.headline).monospacedDigit()
            }
            if let fraction = summary.usedFraction {
                ProgressView(value: fraction).tint(summary.family == .claude ? .orange : .green)
            }
            HStack {
                if globallyStale || summary.expiresAt <= .now {
                    Text("Stale").foregroundStyle(.orange)
                } else if let reset = summary.resetsAt, reset > .now {
                    Text("Resets \(reset, style: .relative)")
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

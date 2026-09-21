import ServiceManagement
import SwiftUI
import TinyUsageDomain

struct CollectorMenuView: View {
    @EnvironmentObject private var model: CollectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.bundle.collectorHealth.rawValue.capitalized, systemImage: model.bundle.collectorHealth == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text("Revision \(model.bundle.revision) · \(model.bundle.generatedAt.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(model.bundle.snapshots.count) accounts · \(model.bundle.snapshots.flatMap(\.metrics).count) metrics")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.connectionDiagnostic)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ForEach(Array(model.bundle.snapshots.flatMap(\.sourceErrors).prefix(3))) { error in
                Label(error.message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            if let lastError = model.lastError {
                Label(lastError, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let pending = model.pairing.pendingDeviceName {
                Label("\(pending) is waiting for approval", systemImage: "iphone.badge.play")
                    .font(.caption)
                Button("Approve \(pending)") { model.confirmPairing() }
                    .buttonStyle(.borderedProminent)
            } else if model.pairing.offer != nil {
                Label("Waiting for the iPhone to connect…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Refresh now") { Task { await model.refresh() } }.disabled(model.isRefreshing)
            Button("Pair an iPhone…") { model.beginPairing() }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit TinyUsage") { NSApplication.shared.terminate(nil) }
        }.padding().frame(width: 300)
    }
}

struct CollectorSettingsView: View {
    @EnvironmentObject private var model: CollectorModel

    var body: some View {
        TabView {
            Form {
                TextField("Collector name", text: $model.configuration.collectorName)
                Toggle("Launch at login", isOn: $model.configuration.launchAtLogin)
                Button("Save settings") { model.saveSettings() }
                Button("Export redacted diagnostics…") { model.exportDiagnostics() }
            }.padding().tabItem { Label("General", systemImage: "gear") }
            Form {
                Toggle("Anthropic organization API", isOn: $model.configuration.anthropicOrganizationEnabled)
                SecureField("Anthropic Admin key", text: $model.anthropicKey)
                Toggle("OpenAI organization API", isOn: $model.configuration.openAIOrganizationEnabled)
                SecureField("OpenAI Admin key", text: $model.openAIKey)
                Divider()
                Toggle("Claude subscription (Experimental)", isOn: $model.configuration.claudeSubscriptionEnabled)
                Toggle("Codex subscription (Experimental)", isOn: $model.configuration.codexSubscriptionEnabled)
                Text("Experimental connectors use private provider endpoints and can be disabled independently.").font(.caption).foregroundStyle(.secondary)
                Button("Save providers") { model.saveSettings(); Task { await model.refresh() } }
            }.padding().tabItem { Label("Providers", systemImage: "server.rack") }
            PairingView().padding().tabItem { Label("Devices", systemImage: "iphone") }
        }.frame(width: 520, height: 420)
    }
}

private struct PairingView: View {
    @EnvironmentObject private var model: CollectorModel
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let image = model.pairing.qrImage, let code = model.pairing.pairingCode {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    Text("Scan with TinyUsage on iPhone. This offer expires after two minutes.").font(.caption)
                    Text(code).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(3)
                    Button("Copy pairing code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    Button("Cancel pairing", role: .cancel) { model.cancelPairing() }
                } else {
                    ContentUnavailableView("No active pairing offer", systemImage: "qrcode", description: Text("The pairing secret exists only in memory."))
                    Button("Pair an iPhone") { model.beginPairing() }.buttonStyle(.borderedProminent)
                }
                if let pending = model.pairing.pendingDeviceName {
                    Label("\(pending) is waiting for approval", systemImage: "iphone.badge.play")
                    Button("Approve \(pending)") { model.confirmPairing() }.buttonStyle(.borderedProminent)
                }
                if !model.pairing.pairedDevices.isEmpty {
                    Divider()
                    ForEach(model.pairing.pairedDevices) { Label($0.name, systemImage: "iphone") }
                    Button("Revoke all devices", role: .destructive) { model.revokeAllDevices() }
                }
            }
        }
    }
}

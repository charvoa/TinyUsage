import AppKit
import Combine
import Foundation
import OSLog
import ServiceManagement
import TinyUsageCollectorCore
import TinyUsageDomain
import UniformTypeIdentifiers

@MainActor
final class CollectorModel: ObservableObject {
    @Published var configuration: CollectorConfiguration
    @Published private(set) var bundle: SnapshotBundle
    @Published private(set) var isRefreshing = false
    @Published var lastError: String?
    @Published var anthropicKey = ""
    @Published var openAIKey = ""
    @Published private(set) var connectionDiagnostic = "Bonjour server is not active"
    let pairing: PairingManager

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.tinyusage.TinyUsageCollector", category: "collector")
    private let keychain = CollectorKeychain()
    private let configurationURL: URL
    private let cacheURL: URL
    private let claudeScanner: IncrementalJSONLScanner
    private let codexScanner: IncrementalJSONLScanner
    private let repository: FileSnapshotRepository
    private var orchestrator: CollectionOrchestrator?
    private var timer: Timer?
    private var server: SecureBonjourServer?
    private var pairingObservation: AnyCancellable?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "TinyUsageCollector")
        configurationURL = support.appending(path: "configuration.json")
        cacheURL = support.appending(path: "snapshot-v2.json")
        claudeScanner = IncrementalJSONLScanner(indexURL: support.appending(path: "indexes/claude.json"))
        codexScanner = IncrementalJSONLScanner(indexURL: support.appending(path: "indexes/codex.json"))
        repository = FileSnapshotRepository(directory: support.appending(path: "sources"))
        let config = CollectorConfiguration.load(from: configurationURL)
        configuration = config
        bundle = (try? SnapshotBundleStore(fileURL: cacheURL).load()) ?? .init(collectorID: config.collectorID, revision: 0, snapshots: [], collectorHealth: .offline)
        pairing = PairingManager(collectorID: config.collectorID, pairedDevices: config.pairedDevices)
        pairingObservation = pairing.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        pairing.onInvalidated = { [weak self] in self?.startServer() }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in Task { await self?.refresh() } }
        Task { startServer(); await refresh() }
    }

    func saveSettings() {
        do {
            if !anthropicKey.isEmpty { try keychain.save(anthropicKey, account: "anthropic.admin"); anthropicKey = "" }
            if !openAIKey.isEmpty { try keychain.save(openAIKey, account: "openai.admin"); openAIKey = "" }
            try configuration.save(to: configurationURL)
            if configuration.launchAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        } catch { lastError = error.localizedDescription }
    }

    func beginPairing() {
        pairing.begin()
        startServer()
    }

    func confirmPairing() {
        do {
            guard try pairing.confirmPendingDevice() != nil else { return }
            configuration.pairedDevices = pairing.pairedDevices
            try configuration.save(to: configurationURL)
            startServer()
        } catch {
            lastError = "Could not approve this iPhone: \(error.localizedDescription)"
        }
    }

    func revokeAllDevices() {
        pairing.revokeAll()
        configuration.pairedDevices = []
        try? configuration.save(to: configurationURL)
        startServer()
    }

    private func revokeDevice(identity: String) {
        pairing.revoke(identity: identity)
        configuration.pairedDevices = pairing.pairedDevices
        try? configuration.save(to: configurationURL)
        startServer()
    }

    func cancelPairing() { pairing.invalidate() }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TinyUsage-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DiagnosticReport(bundle: bundle).encoded().write(to: url, options: .atomic) }
        catch { lastError = error.localizedDescription }
    }

    private func startServer() {
        server?.stop()
        var keys = pairing.storedKeys()
        if let offer = pairing.offer, !offer.isExpired { keys.append(.init(identity: offer.pskIdentity, secret: offer.secret)) }
        guard !keys.isEmpty else {
            server = nil
            connectionDiagnostic = "Start pairing to activate the Bonjour server"
            return
        }
        let server = SecureBonjourServer(collectorID: configuration.collectorID, collectorName: configuration.collectorName, advertisedPairingIdentity: pairing.offer?.pskIdentity, keys: keys, bundleProvider: { [weak self] in await MainActor.run { self?.bundle ?? .empty } }, refreshHandler: { [weak self] in
            await self?.refresh()
            return .completed
        }, helloHandler: { [weak self] identity, name in await MainActor.run { self?.pairing.registerPending(identity: identity, name: name) ?? false } }, authorizationHandler: { [weak self] identity in await MainActor.run { self?.pairing.isAuthorized(identity: identity) ?? false } }, revokeHandler: { [weak self] identity in await MainActor.run { self?.revokeDevice(identity: identity) } }, statusHandler: { [weak self] status in
            Task { @MainActor in self?.connectionDiagnostic = status }
        })
        do { try server.start(); self.server = server }
        catch {
            lastError = error.localizedDescription
            connectionDiagnostic = "Bonjour could not start: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let resolver = LocalCredentialResolver(keychainLookup: { [keychain] service in keychain.loadExternal(service: service) })
        var connectors: [any UsageSourceConnector] = []
        if configuration.anthropicOrganizationEnabled { connectors.append(AnthropicOrganizationConnector(apiKey: keychain.load(account: "anthropic.admin") ?? "")) }
        if configuration.openAIOrganizationEnabled { connectors.append(OpenAIOrganizationConnector(apiKey: keychain.load(account: "openai.admin") ?? "")) }
        if configuration.claudeSubscriptionEnabled { connectors.append(ClaudeSubscriptionConnector(resolver: resolver, enabled: true)) }
        if configuration.codexSubscriptionEnabled { connectors.append(CodexSubscriptionConnector(resolver: resolver, enabled: true)) }
        connectors.append(LocalLogConnector(family: .claude, files: { Self.jsonlFiles(under: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")) }, scanner: claudeScanner))
        connectors.append(LocalLogConnector(family: .codex, files: { Self.jsonlFiles(under: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")) + Self.jsonlFiles(under: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/archived_sessions")) }, scanner: codexScanner))
        let orchestrator: CollectionOrchestrator
        if let existing = self.orchestrator {
            await existing.updateConnectors(connectors)
            orchestrator = existing
        } else {
            let created = CollectionOrchestrator(connectors: connectors, repository: repository, initialRevision: bundle.revision)
            self.orchestrator = created
            orchestrator = created
        }
        let result = await orchestrator.collect(collectorID: configuration.collectorID)
        do {
            try SnapshotBundleStore(fileURL: cacheURL).save(result)
            bundle = result
            logger.info("Collection completed with revision \(result.revision, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            logger.error("Could not persist collection result")
        }
    }

    private nonisolated static func jsonlFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }
}

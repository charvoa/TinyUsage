import Foundation

struct PairedDeviceRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String { identity }
    let identity: String
    let name: String
}

struct CollectorConfiguration: Codable, Sendable {
    var collectorID = UUID().uuidString
    var collectorName = Host.current().localizedName ?? "TinyUsage Mac"
    var anthropicOrganizationEnabled = false
    var openAIOrganizationEnabled = false
    var claudeSubscriptionEnabled = false
    var codexSubscriptionEnabled = false
    var launchAtLogin = false
    var pairedDevices: [PairedDeviceRecord] = []

    static func load(from url: URL) -> Self {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

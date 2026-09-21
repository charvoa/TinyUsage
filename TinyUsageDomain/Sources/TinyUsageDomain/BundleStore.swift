import Foundation

public struct SnapshotBundleStore: Sendable {
    public static let fileName = "snapshot-v2.json"
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public init(appGroupIdentifier: String) throws {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.fileURL = container.appending(path: Self.fileName)
    }

    public func load() throws -> SnapshotBundle? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let bundle = try JSONDecoder.tinyUsage.decode(SnapshotBundle.self, from: Data(contentsOf: fileURL))
        guard bundle.schemaVersion == SnapshotBundle.currentSchemaVersion else { throw SyncProtocolError.incompatibleVersion }
        return bundle
    }

    public func save(_ bundle: SnapshotBundle) throws {
        guard bundle.schemaVersion == SnapshotBundle.currentSchemaVersion else { throw SyncProtocolError.incompatibleVersion }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.tinyUsage.encode(bundle).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

public enum TinyUsageConstants {
    private static func info(_ key: String, fallback: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallback
    }

    public static let appGroup = info("TinyUsageAppGroupIdentifier", fallback: "group.dev.tinyusage.TinyUsage")
    public static let backgroundRefreshIdentifier = info("TinyUsageBackgroundRefreshIdentifier", fallback: "dev.tinyusage.TinyUsage.refresh")
    public static let keychainNamespace = info("TinyUsageKeychainNamespace", fallback: "dev.tinyusage.TinyUsage")
    public static let legacyPairingService = "com.nicolascharvoz.TinyUsage.pairing"
    public static let legacyProviderKeychainService = "com.nicolascharvoz.TinyUsage.credentials"
    public static let bonjourServiceType = "_tinyusage._tcp"
    public static let protocolVersion = 1
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

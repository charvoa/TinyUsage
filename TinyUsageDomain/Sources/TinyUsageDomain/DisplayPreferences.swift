import Foundation

public enum UsageDisplaySurface: String, Codable, CaseIterable, Sendable {
    case widget
    case liveActivity

    public var title: String { self == .widget ? "Widget" : "Live Activity" }
}

public struct UsageDisplayPreferences: Codable, Hashable, Sendable {
    private var widgetMetricIDs: [String: String]
    private var activityMetricIDs: [String: String]

    private enum CodingKeys: String, CodingKey { case widgetMetricIDs, activityMetricIDs }

    public init(widgetMetricIDs: [ProviderFamily: String] = [:], activityMetricIDs: [ProviderFamily: String] = [:]) {
        self.widgetMetricIDs = Dictionary(uniqueKeysWithValues: widgetMetricIDs.map { ($0.key.rawValue, $0.value) })
        self.activityMetricIDs = Dictionary(uniqueKeysWithValues: activityMetricIDs.map { ($0.key.rawValue, $0.value) })
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        widgetMetricIDs = try container.decodeIfPresent([String: String].self, forKey: .widgetMetricIDs) ?? [:]
        activityMetricIDs = try container.decodeIfPresent([String: String].self, forKey: .activityMetricIDs) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(widgetMetricIDs, forKey: .widgetMetricIDs)
        try container.encode(activityMetricIDs, forKey: .activityMetricIDs)
    }

    public func metricID(for family: ProviderFamily, surface: UsageDisplaySurface) -> String? {
        let value = (surface == .widget ? widgetMetricIDs : activityMetricIDs)[family.rawValue]
        return value?.isEmpty == false ? value : nil
    }

    public mutating func setMetricID(_ metricID: String?, for family: ProviderFamily, surface: UsageDisplaySurface) {
        let value = metricID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if surface == .widget { widgetMetricIDs[family.rawValue] = value?.isEmpty == false ? value : nil }
        else { activityMetricIDs[family.rawValue] = value?.isEmpty == false ? value : nil }
    }
}

public struct UsageDisplayPreferencesStore: Sendable {
    public static let key = "usage-display-preferences-v1"
    private let suiteName: String

    public init(appGroupIdentifier: String) { suiteName = appGroupIdentifier }

    public func load() -> UsageDisplayPreferences {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: Self.key),
              let preferences = try? JSONDecoder().decode(UsageDisplayPreferences.self, from: data)
        else { return .init() }
        return preferences
    }

    public func save(_ preferences: UsageDisplayPreferences) throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileNoSuchFile) }
        defaults.set(try JSONEncoder().encode(preferences), forKey: Self.key)
    }
}

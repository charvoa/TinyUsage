import Foundation
import TinyUsageDomain

public struct ProbeResult: Sendable, Equatable {
    public enum State: Sendable { case available, missingCredential, unsupported, disabled }
    public let state: State
    public let message: String?

    public init(_ state: State, message: String? = nil) {
        self.state = state
        self.message = message
    }
}

public struct FetchContext: Sendable {
    public let now: Date
    public let timeout: Duration

    public init(now: Date = .now, timeout: Duration = .seconds(15)) {
        self.now = now
        self.timeout = timeout
    }
}

public struct CredentialCandidate: Sendable {
    public enum Origin: String, Sendable { case keychain, claudeCode, claudeDesktop, codexHome, environment }
    public let secret: String
    public let origin: Origin
    public let generation: String
    public let scopes: Set<String>
    public let expiresAt: Date?
    public let accountID: String?

    public init(secret: String, origin: Origin, generation: String, scopes: Set<String> = [], expiresAt: Date? = nil, accountID: String? = nil) {
        self.secret = secret
        self.origin = origin
        self.generation = generation
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.accountID = accountID
    }
}

public struct SourceSnapshot: Codable, Hashable, Sendable {
    public let source: UsageSourceDescriptor
    public let accountID: String
    public let accountDisplayName: String
    public let plan: String?
    public let metrics: [UsageMetric]
    public let fetchedAt: Date
    public let expiresAt: Date
    public let warnings: [ProviderWarning]

    public init(source: UsageSourceDescriptor, accountID: String, accountDisplayName: String, plan: String? = nil, metrics: [UsageMetric], fetchedAt: Date, expiresAt: Date, warnings: [ProviderWarning] = []) {
        self.source = source
        self.accountID = accountID
        self.accountDisplayName = accountDisplayName
        self.plan = plan
        self.metrics = metrics
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.warnings = warnings
    }
}

public protocol UsageSourceConnector: Sendable {
    var descriptor: UsageSourceDescriptor { get }
    func probe() async -> ProbeResult
    func fetch(context: FetchContext) async throws -> SourceSnapshot
}

public protocol CredentialResolver: Sendable {
    func candidates(for source: UsageSourceDescriptor) async -> [CredentialCandidate]
}

public protocol SnapshotRepository: Sendable {
    func lastGood(for sourceID: String) async -> SourceSnapshot?
    func commit(_ snapshot: SourceSnapshot) async throws
}

public enum ConnectorError: LocalizedError, Sendable {
    case missingCredential
    case invalidCredential
    case insufficientScope
    case invalidResponse
    case provider(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "No compatible credential was found."
        case .invalidCredential: "The provider rejected the credential."
        case .insufficientScope: "The credential does not have the required usage scope."
        case .invalidResponse: "The provider returned an unreadable response."
        case .provider(let message): message
        case .timedOut: "The source timed out."
        }
    }
}

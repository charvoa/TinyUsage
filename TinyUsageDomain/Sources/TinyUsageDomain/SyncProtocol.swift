import Foundation

public enum SyncProtocolError: Error, Codable, Hashable, Sendable {
    case incompatibleVersion
    case malformedFrame
    case frameTooLarge
    case unauthorized
    case rateLimited
    case unavailable(String)
}

public struct Hello: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let deviceName: String
    public let collectorID: String?
    public let pskIdentity: String?

    public init(protocolVersion: Int = TinyUsageConstants.protocolVersion, deviceName: String, collectorID: String? = nil, pskIdentity: String? = nil) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.collectorID = collectorID
        self.pskIdentity = pskIdentity
    }
}

public enum RefreshStatus: String, Codable, Hashable, Sendable { case accepted, refreshing, completed, rateLimited, failed }

public enum SyncMessage: Codable, Hashable, Sendable {
    case hello(Hello)
    case pairingPending
    case syncRequest(lastRevision: UInt64?)
    case snapshotBundle(SnapshotBundle)
    case notModified(revision: UInt64)
    case refreshRequest
    case refreshStatus(RefreshStatus)
    case revokeRequest
    case revoked
    case error(SyncProtocolError)
}

public struct PairingPayload: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let collectorID: String
    public let pskIdentity: String
    public let secret: Data
    public let expiresAt: Date

    public init(protocolVersion: Int = 1, collectorID: String, pskIdentity: String, secret: Data, expiresAt: Date) {
        self.protocolVersion = protocolVersion
        self.collectorID = collectorID
        self.pskIdentity = pskIdentity
        self.secret = secret
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { expiresAt <= .now }

    public func encodedCode() throws -> String {
        let data = try JSONEncoder.tinyUsage.encode(self)
        return data.base64URLEncodedString()
    }

    public static func decode(code: String) throws -> PairingPayload {
        guard let data = Data(base64URLEncoded: code) else { throw SyncProtocolError.malformedFrame }
        return try JSONDecoder.tinyUsage.decode(Self.self, from: data)
    }
}

public enum FrameCodec {
    public static let maximumPayloadSize = 512 * 1024

    public static func encode(_ message: SyncMessage) throws -> Data {
        let payload = try JSONEncoder.tinyUsage.encode(message)
        guard payload.count <= maximumPayloadSize else { throw SyncProtocolError.frameTooLarge }
        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(payload)
        return result
    }

    public static func decode(_ frame: Data) throws -> SyncMessage {
        guard frame.count >= 4 else { throw SyncProtocolError.malformedFrame }
        let size = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= maximumPayloadSize else { throw SyncProtocolError.frameTooLarge }
        guard frame.count == Int(size) + 4 else { throw SyncProtocolError.malformedFrame }
        return try JSONDecoder.tinyUsage.decode(SyncMessage.self, from: frame.dropFirst(4))
    }
}

public extension JSONEncoder {
    static var tinyUsage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var tinyUsage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value.append(String(repeating: "=", count: (4 - value.count % 4) % 4))
        self.init(base64Encoded: value)
    }
}

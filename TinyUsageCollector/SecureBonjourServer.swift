import Foundation
import Network
import Security
import TinyUsageDomain

struct ServerPSK: Sendable {
    let identity: String
    let secret: Data
}

final class SecureBonjourServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TinyUsage.BonjourServer")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let collectorID: String
    private let collectorName: String
    private let advertisedPairingIdentity: String?
    private let keys: [ServerPSK]
    private let bundleProvider: @Sendable () async -> SnapshotBundle
    private let refreshHandler: @Sendable () async -> RefreshStatus
    private let helloHandler: @Sendable (String, String) async -> Bool
    private let authorizationHandler: @Sendable (String) async -> Bool
    private let revokeHandler: @Sendable (String) async -> Void
    private let statusHandler: @Sendable (String) -> Void
    private var connectionIdentities: [ObjectIdentifier: String] = [:]
    private var lastRefreshRequest = Date.distantPast

    init(collectorID: String, collectorName: String, advertisedPairingIdentity: String?, keys: [ServerPSK], bundleProvider: @escaping @Sendable () async -> SnapshotBundle, refreshHandler: @escaping @Sendable () async -> RefreshStatus, helloHandler: @escaping @Sendable (String, String) async -> Bool, authorizationHandler: @escaping @Sendable (String) async -> Bool, revokeHandler: @escaping @Sendable (String) async -> Void, statusHandler: @escaping @Sendable (String) -> Void = { _ in }) {
        self.collectorID = collectorID
        self.collectorName = collectorName
        self.advertisedPairingIdentity = advertisedPairingIdentity
        self.keys = keys
        self.bundleProvider = bundleProvider
        self.refreshHandler = refreshHandler
        self.helloHandler = helloHandler
        self.authorizationHandler = authorizationHandler
        self.revokeHandler = revokeHandler
        self.statusHandler = statusHandler
    }

    func start() throws {
        guard !keys.isEmpty else { throw SyncProtocolError.unauthorized }
        let tls = NWProtocolTLS.Options()
        for key in keys {
            sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, dispatchData(key.secret) as dispatch_data_t, dispatchData(Data(key.identity.utf8)) as dispatch_data_t)
        }
        // Network.framework currently keeps the listener's effective maximum at
        // TLS 1.2 when a TLS-PSK identity is configured. Requiring TLS 1.3 here
        // produces an invalid 1.3...1.2 range and the listener closes the
        // ClientHello with errSSLClosedNoNotify (-9816).
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(tls: tls, tcp: .init())
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters)
        listener.service = .init(name: collectorName, type: TinyUsageConstants.bonjourServiceType, txtRecord: txtRecord(["protocolVersion": String(TinyUsageConstants.protocolVersion), "name": collectorName, "id": advertisedPairingIdentity ?? UUID().uuidString]))
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [statusHandler] state in
            switch state {
            case .ready: statusHandler("Bonjour ready — waiting for a secure iPhone connection")
            case .failed(let error): statusHandler("Bonjour listener failed: \(error.localizedDescription)")
            case .cancelled: statusHandler("Bonjour listener stopped")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stateLock.lock()
        let active = Array(connections.values)
        connections.removeAll()
        connectionIdentities.removeAll()
        stateLock.unlock()
        active.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        stateLock.lock()
        connections[identifier] = connection
        stateLock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .ready = state, let connection {
                self?.statusHandler("Secure TLS connection established — waiting for iPhone hello")
                self?.receiveHeader(on: connection)
            }
            if case .failed(let error) = state {
                self?.statusHandler("Secure connection failed: \(error.localizedDescription)")
                self?.remove(identifier)
            }
            if case .cancelled = state { self?.remove(identifier) }
        }
        connection.start(queue: queue)
    }

    private func receiveHeader(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data, data.count == 4 else { connection.cancel(); return }
            let size = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size <= FrameCodec.maximumPayloadSize else { connection.cancel(); return }
            self.receivePayload(length: Int(size), header: data, on: connection)
        }
    }

    private func receivePayload(length: Int, header: Data, on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count == length, let message = try? FrameCodec.decode(header + data) else { connection.cancel(); return }
            Task { await self.handle(message, on: connection) }
        }
    }

    private func handle(_ message: SyncMessage, on connection: NWConnection) async {
        switch message {
        case .hello(let hello):
            guard hello.protocolVersion == TinyUsageConstants.protocolVersion else { send(.error(.incompatibleVersion), on: connection, closeAfter: true); return }
            // Older clients placed the PSK identity in collectorID. Keep that fallback
            // while using the unambiguous pskIdentity field for current clients.
            guard let identity = hello.pskIdentity ?? hello.collectorID, keys.contains(where: { $0.identity == identity }) else { send(.error(.unauthorized), on: connection, closeAfter: true); return }
            setIdentity(identity, for: connection)
            if await authorizationHandler(identity) {
                send(.hello(.init(deviceName: collectorName, collectorID: collectorID)), on: connection)
                receiveHeader(on: connection)
                return
            }
            guard await helloHandler(identity, hello.deviceName) else {
                statusHandler("Pairing request rejected — QR code expired or replaced")
                send(.error(.unauthorized), on: connection, closeAfter: true)
                return
            }
            statusHandler("\(hello.deviceName) connected — approval required")
            send(.pairingPending, on: connection, closeAfter: true)
            return
        case .syncRequest(let lastRevision):
            guard let identity = identity(for: connection), await authorizationHandler(identity) else { send(.error(.unauthorized), on: connection, closeAfter: true); return }
            let bundle = await bundleProvider()
            send(lastRevision == bundle.revision ? .notModified(revision: bundle.revision) : .snapshotBundle(bundle), on: connection)
        case .refreshRequest:
            guard let identity = identity(for: connection), await authorizationHandler(identity) else { send(.error(.unauthorized), on: connection, closeAfter: true); return }
            guard acceptRefreshRequest() else { send(.refreshStatus(.rateLimited), on: connection); return }
            send(.refreshStatus(await refreshHandler()), on: connection)
        case .revokeRequest:
            guard let identity = identity(for: connection), await authorizationHandler(identity) else { send(.error(.unauthorized), on: connection, closeAfter: true); return }
            send(.revoked, on: connection, closeAfter: true) { [weak self] in
                guard let self else { return }
                Task { await self.revokeHandler(identity) }
            }
            return
        default:
            send(.error(.malformedFrame), on: connection, closeAfter: true)
            return
        }
        receiveHeader(on: connection)
    }

    private func send(_ message: SyncMessage, on connection: NWConnection, closeAfter: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        guard let frame = try? FrameCodec.encode(message) else { connection.cancel(); return }
        connection.send(content: frame, completion: .contentProcessed { error in
            if error != nil || closeAfter { connection.cancel() }
            if error == nil { completion?() }
        })
    }

    private func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    private func txtRecord(_ values: [String: String]) -> Data {
        values.sorted(by: { $0.key < $1.key }).reduce(into: Data()) { result, pair in
            let bytes = Data("\(pair.key)=\(pair.value)".utf8).prefix(255)
            result.append(UInt8(bytes.count))
            result.append(bytes)
        }
    }

    private func remove(_ identifier: ObjectIdentifier) {
        stateLock.lock()
        connections[identifier] = nil
        connectionIdentities[identifier] = nil
        stateLock.unlock()
    }

    private func setIdentity(_ identity: String, for connection: NWConnection) {
        stateLock.lock()
        connectionIdentities[ObjectIdentifier(connection)] = identity
        stateLock.unlock()
    }

    private func identity(for connection: NWConnection) -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return connectionIdentities[ObjectIdentifier(connection)]
    }

    private func acceptRefreshRequest(now: Date = .now) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard now.timeIntervalSince(lastRefreshRequest) >= 60 else { return false }
        lastRefreshRequest = now
        return true
    }
}

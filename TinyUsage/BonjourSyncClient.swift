import Foundation
import Network
import Security
import TinyUsageDomain
import UIKit

final class BonjourSyncClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TinyUsage.BonjourClient")
    private let permissionLock = NSLock()
    private var permissionBrowser: NWBrowser?

    func prepareLocalNetworkAccess() {
        permissionLock.lock()
        guard permissionBrowser == nil else { permissionLock.unlock(); return }
        let browser = NWBrowser(for: .bonjour(type: TinyUsageConstants.bonjourServiceType, domain: nil), using: .tcp)
        permissionBrowser = browser
        permissionLock.unlock()
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            switch state {
            case .ready, .failed, .cancelled:
                browser?.cancel()
                self?.permissionLock.lock()
                self?.permissionBrowser = nil
                self?.permissionLock.unlock()
            default: break
            }
        }
        browser.start(queue: queue)
    }

    func synchronize(pairing: PairingPayload, awaitingApproval: Bool, lastRevision: UInt64?, requestRefresh: Bool = false, timeout: Duration = .seconds(8)) async throws -> SyncMessage {
        return try await withThrowingTaskGroup(of: SyncMessage.self) { group in
            group.addTask { try await self.discoverAndSync(pairing: pairing, awaitingApproval: awaitingApproval, lastRevision: lastRevision, requestRefresh: requestRefresh) }
            group.addTask { try await Task.sleep(for: timeout); throw SyncProtocolError.unavailable("Collector discovery timed out.") }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    func revoke(pairing: PairingPayload, timeout: Duration = .seconds(8)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let endpoints = try await self.discover()
                var lastError: Error = SyncProtocolError.unavailable("No compatible collector was found.")
                for endpoint in endpoints {
                    do { try await self.revoke(endpoint: endpoint, pairing: pairing); return }
                    catch { lastError = error }
                }
                throw lastError
            }
            group.addTask { try await Task.sleep(for: timeout); throw SyncProtocolError.unavailable("Collector discovery timed out.") }
            try await group.next()!
            group.cancelAll()
        }
    }

    private func discoverAndSync(pairing: PairingPayload, awaitingApproval: Bool, lastRevision: UInt64?, requestRefresh: Bool) async throws -> SyncMessage {
        let endpoints = try await discover(preferredPairingIdentity: awaitingApproval ? pairing.pskIdentity : nil)
        guard !endpoints.isEmpty else { throw SyncProtocolError.unavailable("No compatible collector was found.") }
        return try await withThrowingTaskGroup(of: SyncMessage.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    try await self.sync(endpoint: endpoint, pairing: pairing, lastRevision: lastRevision, requestRefresh: requestRefresh)
                }
            }
            var lastError: Error = SyncProtocolError.unavailable("No compatible collector was found.")
            while let result = await group.nextResult() {
                switch result {
                case .success(let message):
                    group.cancelAll()
                    return message
                case .failure(let error):
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private func sync(endpoint: NWEndpoint, pairing: PairingPayload, lastRevision: UInt64?, requestRefresh: Bool) async throws -> SyncMessage {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, dispatchData(pairing.secret) as dispatch_data_t, dispatchData(Data(pairing.pskIdentity.utf8)) as dispatch_data_t)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(tls: tls, tcp: .init())
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await waitUntilReady(connection)
            try await send(.hello(.init(deviceName: UIDevice.current.name, collectorID: pairing.collectorID, pskIdentity: pairing.pskIdentity)), on: connection)
            let greeting = try await receive(on: connection)
            if case .pairingPending = greeting { return .pairingPending }
            guard case .hello(let hello) = greeting, hello.collectorID == pairing.collectorID else { throw SyncProtocolError.unauthorized }
            if requestRefresh {
                try await send(.refreshRequest, on: connection)
                switch try await receive(on: connection) {
                case .refreshStatus(.rateLimited): break
                case .refreshStatus(.completed), .refreshStatus(.accepted): break
                case .error(let error): throw error
                default: throw SyncProtocolError.malformedFrame
                }
            }
            try await send(.syncRequest(lastRevision: lastRevision), on: connection)
            return try await receive(on: connection)
        } onCancel: {
            connection.cancel()
        }
    }

    private func revoke(endpoint: NWEndpoint, pairing: PairingPayload) async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, dispatchData(pairing.secret) as dispatch_data_t, dispatchData(Data(pairing.pskIdentity.utf8)) as dispatch_data_t)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(tls: tls, tcp: .init())
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await waitUntilReady(connection)
            try await send(.hello(.init(deviceName: UIDevice.current.name, collectorID: pairing.collectorID, pskIdentity: pairing.pskIdentity)), on: connection)
            guard case .hello(let hello) = try await receive(on: connection), hello.collectorID == pairing.collectorID else { throw SyncProtocolError.unauthorized }
            try await send(.revokeRequest, on: connection)
            guard case .revoked = try await receive(on: connection) else { throw SyncProtocolError.unauthorized }
        } onCancel: { connection.cancel() }
    }

    private func discover(preferredPairingIdentity: String? = nil) async throws -> [NWEndpoint] {
        let descriptor: NWBrowser.Descriptor = preferredPairingIdentity == nil
            ? .bonjour(type: TinyUsageConstants.bonjourServiceType, domain: nil)
            : .bonjourWithTXTRecord(type: TinyUsageConstants.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate<[NWEndpoint]>(continuation)
                gate.onFinish = { browser.cancel() }
                browser.stateUpdateHandler = { state in
                    if case .failed(let error) = state { gate.fail(error) }
                    if case .cancelled = state { gate.fail(CancellationError()) }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    let matching = results.compactMap { result -> NWEndpoint? in
                        guard let preferredPairingIdentity else { return result.endpoint }
                        guard case .bonjour(let record) = result.metadata,
                              record["id"] == preferredPairingIdentity else { return nil }
                        return result.endpoint
                    }
                    if !matching.isEmpty {
                        gate.succeed(matching)
                    } else if preferredPairingIdentity != nil, !results.isEmpty {
                        // Approval restarts the Mac listener with a fresh ephemeral TXT id.
                        // Give the matching pairing advertisement a short head start, then
                        // authenticate all visible candidates concurrently with TLS-PSK.
                        let fallback = results.map(\.endpoint)
                        self.queue.asyncAfter(deadline: .now() + 0.75) {
                            gate.succeed(fallback)
                        }
                    }
                }
                browser.start(queue: queue)
            }
        } onCancel: { browser.cancel() }
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed(())
                case .failed(let error): gate.fail(error)
                case .cancelled: gate.fail(CancellationError())
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ message: SyncMessage, on connection: NWConnection) async throws {
        let data = try FrameCodec.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receive(on connection: NWConnection) async throws -> SyncMessage {
        let header = try await receiveExactly(4, on: connection)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= FrameCodec.maximumPayloadSize else { throw SyncProtocolError.frameTooLarge }
        return try FrameCodec.decode(header + (try await receiveExactly(Int(size), on: connection)))
    }

    private func receiveExactly(_ length: Int, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == length { continuation.resume(returning: data) }
                else { continuation.resume(throwing: SyncProtocolError.malformedFrame) }
            }
        }
    }

    private func dispatchData(_ data: Data) -> DispatchData { data.withUnsafeBytes { DispatchData(bytes: $0) } }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    var onFinish: (@Sendable () -> Void)?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func succeed(_ value: Value) { finish { $0.resume(returning: value) } }
    func fail(_ error: Error) { finish { $0.resume(throwing: error) } }
    private func finish(_ action: (CheckedContinuation<Value, Error>) -> Void) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        action(continuation)
        onFinish?()
    }
}

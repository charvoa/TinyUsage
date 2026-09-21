import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import Security
import TinyUsageDomain

@MainActor
final class PairingManager: ObservableObject {
    @Published private(set) var offer: PairingPayload?
    @Published private(set) var pairingCode: String?
    @Published var pendingDeviceName: String?
    @Published private(set) var pendingIdentity: String?
    @Published private(set) var pairedDevices: [PairedDeviceRecord]

    private var expirationTask: Task<Void, Never>?
    private let keychain = CollectorKeychain()
    private let collectorID: String
    var onInvalidated: (() -> Void)?

    init(collectorID: String, pairedDevices: [PairedDeviceRecord]) {
        self.collectorID = collectorID
        self.pairedDevices = pairedDevices
    }

    func begin() {
        expirationTask?.cancel()
        pendingDeviceName = nil
        pendingIdentity = nil
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        let payload = PairingPayload(collectorID: collectorID, pskIdentity: UUID().uuidString, secret: Data(bytes), expiresAt: .now.addingTimeInterval(120))
        offer = payload
        pairingCode = try? payload.encodedCode()
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.invalidate()
        }
    }

    func invalidate() {
        expirationTask?.cancel()
        expirationTask = nil
        offer = nil
        pairingCode = nil
        pendingDeviceName = nil
        pendingIdentity = nil
        onInvalidated?()
    }

    @discardableResult
    func registerPending(identity: String, name: String) -> Bool {
        guard identity == offer?.pskIdentity, offer?.isExpired == false else { return false }
        pendingIdentity = identity
        pendingDeviceName = name
        return true
    }

    @discardableResult func confirmPendingDevice() throws -> PairedDeviceRecord? {
        guard let offer, let name = pendingDeviceName, pendingIdentity == offer.pskIdentity, !offer.isExpired else { invalidate(); return nil }
        try keychain.save(offer.secret.base64EncodedString(), account: "psk.\(offer.pskIdentity)")
        let record = PairedDeviceRecord(identity: offer.pskIdentity, name: name)
        pairedDevices.removeAll { $0.identity == record.identity }
        pairedDevices.append(record)
        invalidate()
        return record
    }

    func revokeAll() {
        for device in pairedDevices { try? keychain.delete(account: "psk.\(device.identity)") }
        pairedDevices.removeAll()
        invalidate()
    }

    func revoke(identity: String) {
        try? keychain.delete(account: "psk.\(identity)")
        pairedDevices.removeAll { $0.identity == identity }
    }

    func storedKeys() -> [ServerPSK] {
        pairedDevices.compactMap { record in
            guard let encoded = keychain.load(account: "psk.\(record.identity)"), let secret = Data(base64Encoded: encoded) else { return nil }
            return ServerPSK(identity: record.identity, secret: secret)
        }
    }

    func isAuthorized(identity: String) -> Bool { pairedDevices.contains { $0.identity == identity } }

    var qrImage: NSImage? {
        guard let pairingCode else { return nil }
        let url = "tinyusage://pair?code=\(pairingCode)"
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        // Low correction keeps the long authenticated payload less dense and easier to scan.
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

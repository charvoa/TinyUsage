import AVFoundation
import SwiftUI
import VisionKit

struct PairingView: View {
    @EnvironmentObject private var model: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var scannerError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Local network") { Text("TinyUsage searches only your local network. iOS will ask for Local Network and Camera access; no pairing data is sent to a server.") }
                Section("Scan") { Button("Scan collector QR code", systemImage: "qrcode.viewfinder") { requestCameraAndScan() } }
                Section("Accessibility code") {
                    TextField("Paste the long Base64URL code", text: $model.pairingCode, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Pair") {
                        Task {
                            await model.pair()
                            if !model.awaitingPairingApproval && model.connectionState == .synchronized { dismiss() }
                        }
                    }.disabled(model.pairingCode.isEmpty)
                }
                if model.awaitingPairingApproval {
                    Section("Waiting for Mac approval") {
                        Label("On your Mac, open the TinyUsage menu and select Approve this iPhone.", systemImage: "iphone.badge.play")
                        Button("I've approved it — connect now") {
                            Task {
                                if await model.synchronize() { dismiss() }
                            }
                        }.buttonStyle(.borderedProminent)
                    }
                }
                if model.connectionState != .collectorNotInstalled { Section { Button("Revoke this collector", role: .destructive) { Task { await model.revoke(); dismiss() } } } }
            }
            .navigationTitle("Pair with Mac")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScanner(completion: { value in
                    scanning = false
                    Task {
                        await model.pair(code: value)
                        if !model.awaitingPairingApproval && model.connectionState == .synchronized { dismiss() }
                    }
                }, failure: { message in
                    scanning = false
                    scannerError = message
                })
            }
            .alert("Camera unavailable", isPresented: .init(get: { scannerError != nil }, set: { if !$0 { scannerError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(scannerError ?? "") }
            .task { model.prepareForPairing() }
        }
    }

    private func requestCameraAndScan() {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            scannerError = "QR scanning is not available on this device. Paste the long pairing code instead."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            scanning = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { scanning = true }
                    else { scannerError = "Camera access was denied. Enable it in Settings, or paste the long pairing code." }
                }
            }
        default:
            scannerError = "Camera access is disabled. Enable it in Settings, or paste the long pairing code."
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let completion: (String) -> Void
    let failure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion, failure: failure) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        guard !context.coordinator.didStart else { return }
        context.coordinator.didStart = true
        DispatchQueue.main.async {
            do { try uiViewController.startScanning() }
            catch { context.coordinator.failure("The camera scanner could not start: \(error.localizedDescription)") }
        }
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let completion: (String) -> Void
        let failure: (String) -> Void
        var didStart = false
        private var didComplete = false
        init(completion: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
            self.completion = completion
            self.failure = failure
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            complete(with: addedItems)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            complete(with: [item])
        }
        private func complete(with items: [RecognizedItem]) {
            guard !didComplete else { return }
            for item in items {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, value.hasPrefix("tinyusage://pair") {
                    didComplete = true
                    completion(value)
                    return
                }
            }
        }
    }
}

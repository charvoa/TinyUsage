import Security
import SwiftUI
import TinyUsageDomain

struct LegacyCredentialCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Legacy provider keys") {
                    Text("TinyUsage no longer uses provider credentials on iPhone. Existing keys have not been deleted automatically.")
                    Text("Delete them only after confirming that your Mac collector is synchronized.").foregroundStyle(.secondary)
                    Button("Keep legacy keys") { dismiss() }
                    Button("Delete legacy keys", role: .destructive) {
                        let status = SecItemDelete([
                            kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: TinyUsageConstants.legacyProviderKeychainService
                        ] as CFDictionary)
                        if status == errSecSuccess || status == errSecItemNotFound {
                            UserDefaults.standard.set(true, forKey: "legacyCredentialDeletionCompleted")
                            dismiss()
                        }
                    }
                }
            }.navigationTitle("Privacy cleanup")
        }
    }
}

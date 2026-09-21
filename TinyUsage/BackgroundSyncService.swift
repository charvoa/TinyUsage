import Foundation

@MainActor
enum BackgroundSyncService {
    static func refresh() async -> Bool {
        let model = DashboardViewModel()
        _ = await model.synchronize()
        return model.connectionState == .synchronized || model.connectionState == .stale
    }
}

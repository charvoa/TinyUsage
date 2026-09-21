import SwiftUI

@main
struct TinyUsageApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DashboardViewModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(model)
                .onOpenURL { url in
                    if url.scheme == "tinyusage", url.host == "pair" { Task { await model.pair(code: url.absoluteString) } }
                    else { model.route(url) }
                }
        }
    }
}

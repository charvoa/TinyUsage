import SwiftUI

@main
struct TinyUsageCollectorApp: App {
    @StateObject private var model = CollectorModel()

    var body: some Scene {
        MenuBarExtra("TinyUsage", systemImage: "gauge.with.dots.needle.67percent") {
            CollectorMenuView().environmentObject(model)
        }
        Settings {
            CollectorSettingsView().environmentObject(model)
        }
    }
}

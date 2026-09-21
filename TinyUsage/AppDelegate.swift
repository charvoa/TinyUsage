import BackgroundTasks
import TinyUsageDomain
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: TinyUsageConstants.backgroundRefreshIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            self.handle(task)
        }
        schedule()
        return true
    }
    func applicationDidEnterBackground(_ application: UIApplication) { schedule() }
    private func handle(_ task: BGAppRefreshTask) {
        schedule()
        let operation = Task { task.setTaskCompleted(success: await BackgroundSyncService.refresh()) }
        task.expirationHandler = { operation.cancel() }
    }
    private func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: TinyUsageConstants.backgroundRefreshIdentifier)
        request.earliestBeginDate = .now.addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

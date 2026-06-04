import UIKit

@MainActor
enum BackgroundTaskService {
    private static var taskId: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String) {
        guard taskId == .invalid else {
            AppLog.info("Background task already active name=\(name)")
            return
        }
        taskId = UIApplication.shared.beginBackgroundTask(withName: name) {
            AppLog.error("Background task expired name=\(name)")
            end()
        }
        AppLog.info("Background task began name=\(name) id=\(taskId.rawValue)")
    }

    static func end() {
        guard taskId != .invalid else { return }
        let ending = taskId
        taskId = .invalid
        UIApplication.shared.endBackgroundTask(ending)
        AppLog.info("Background task ended id=\(ending.rawValue)")
    }
}

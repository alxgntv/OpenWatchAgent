import UIKit
import WatchConnectivity

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppLog.info("AppDelegate didFinishLaunching — activating WatchConnectivity early")
        KeychainStore.migrateExistingItemsForLockedAccess()
        _ = WatchConnectivityPhoneService.shared
        _ = AppModel.shared
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AppLog.info("OpenWatch entered background — WCSession and queued watch commands remain active")
    }
}

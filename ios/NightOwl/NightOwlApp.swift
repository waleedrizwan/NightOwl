import SwiftUI
import UserNotifications

@main
struct NightOwlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(Store.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await Store.shared.refresh() } }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { app.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Store.shared.registerDevice(token.map { String(format: "%02x", $0) }.joined())
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("push registration failed: \(error)")
    }

    // Show the banner even when the app is open, and pull the new night in.
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        await Store.shared.refresh()
        return [.banner, .sound]
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let night = response.notification.request.content.userInfo["night"] as? String
        await MainActor.run { Store.shared.openNight = night }
        await Store.shared.refresh()
    }
}

//
//  SiriusApp.swift
//  Sirius
//
//  Created by MAXWELL TAWIAH on 10/9/26.
//

import SwiftUI
import CoreData
import UserNotifications

final class SiriusAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let deepLinkNotification = Notification.Name("SiriusNotificationDeepLink")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["deep_link"] as? String,
              let url = URL(string: value) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: Self.deepLinkNotification, object: url)
        }
    }
}

@main
struct SiriusApp: App {
    @UIApplicationDelegateAdaptor(SiriusAppDelegate.self) private var appDelegate
    private let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

//
//  AppDelegate.swift
//  Hardcord Lock App
//
//  Hosts the notification-action handling for AI-mode nudges.
//

import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerNotificationCategories(center)
        return true
    }

    private func registerNotificationCategories(_ center: UNUserNotificationCenter) {
        let lockNow = UNNotificationAction(
            identifier: HabitEngine.actionLockNow,
            title: "LOCK NOW",
            options: [.foreground]
        )
        let skip = UNNotificationAction(
            identifier: HabitEngine.actionSkip,
            title: "Not today",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: HabitEngine.categoryIdentifier,
            actions: [lockNow, skip],
            intentIdentifiers: [],
            // Report swipe-to-dismiss too: it is the bandit's "no" signal.
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    // Show the nudge even while the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Handle taps on the nudge / its actions.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier

        if category == HabitEngine.categoryIdentifier {
            let lead = response.notification.request.content.userInfo[NudgeScheduler.leadKey] as? Int
            switch action {
            case HabitEngine.actionLockNow:
                // ONLY the explicit "LOCK NOW" action starts a lock. Merely
                // tapping the banner (UNNotificationDefaultActionIdentifier)
                // must just open the app — locking someone for hours because
                // they glanced at a notification is not consent.
                if let lead { LeadBanditStore.record(leadMinutes: lead, accepted: true) }
                Task { @MainActor in
                    HabitEngine.shared.requestChallenge()
                }
            case HabitEngine.actionSkip, UNNotificationDismissActionIdentifier:
                if let lead { LeadBanditStore.record(leadMinutes: lead, accepted: false) }
            default:
                break // Banner tap → just open the app; neither a yes nor a no.
            }
        }
        completionHandler()
    }
}

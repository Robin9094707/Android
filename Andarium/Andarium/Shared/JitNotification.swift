// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UserNotifications

#if !APP_STORE

/// The notification the built-in JIT shows. When a start prepares the JIT
/// itself (no StikDebug), the person gets a short notice that the guest is
/// running on the JIT, so the setup they did in Settings is confirmed. An App
/// Store build has no JIT and none of this.
enum JitNotification {
    private static let identifier = "andarium.jit.ready"

    /// Asks once for permission to notify, when the person turns the built-in
    /// JIT on. A refusal is kept by the system; nothing is shown then.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Shows that the guest is running on the built-in JIT. Shown only if the
    /// person allowed notifications; it is cleared and shown again each time.
    static func jitReady() {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "JIT is on", table: "JIT",
            comment: "Notification title when the built-in JIT prepared the JIT for a start. JIT is a name and stays as it is.")
        content.body = String(
            localized: "Andarium prepared the JIT itself. The virtual machine is running at full speed.",
            table: "JIT",
            comment: "Notification body when the built-in JIT prepared the JIT. JIT is a name and stays as it is.")
        content.sound = .default
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

#endif

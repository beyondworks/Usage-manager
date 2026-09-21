import Foundation
import UserNotifications
import UsageCore

/// Local macOS notifications. UNUserNotificationCenter when the app has a bundle
/// identity and permission (per-session identifiers so repeats replace instead of
/// stacking); otherwise `osascript display notification`.
@MainActor
final class Notifier {
    static let shared = Notifier()
    private var useUN = false

    func prepare() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // current() traps without a bundle
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.useUN = granted }
        }
    }

    func fire(title: String, body: String, id: String) {
        FileHandle.standardError.write(Data("[notify] \(title) — \(body) [\(id)]\n".utf8))
        // The self-check drives a fake over-threshold session; it should not put a real
        // banner on the user's screen, so offline runs stop at the log line above.
        guard !Paths.offline else { return }
        guard useUN else { return osascript(title: title, body: body) }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if error != nil { Task { @MainActor in self.osascript(title: title, body: body) } }
        }
    }

    private func osascript(title: String, body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        try? p.run()
    }
}

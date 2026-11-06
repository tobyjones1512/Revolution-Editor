import AppKit
import UserNotifications

/// System notifications for build, Hot Swap, port and conversion results.
@MainActor enum AppNotifications {
	static func requestAuthorization() {
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
	}

	static func post(title: String, body: String, url: String? = nil) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		if let url { content.userInfo = ["url": url] }
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
	}

	static func buildFinished(success: Bool, project: String) {
		post(title: success ? "Build Succeeded" : "Build Failed", body: success ? "\(project) built successfully." : "\(project) failed to build. Check the console for details.")
	}

	static func hotSwap(project: String, failure: String?) {
		if let failure {
			post(title: "Hot Swap Failed", body: "\(project): \(failure)")
		} else {
			post(title: "Hot Swap Started", body: "\(project) is booting in Dolphin.")
		}
	}

	static func port(success: Bool, detail: String) {
		post(title: success ? "Port Succeeded" : "Port Failed", body: detail)
	}

	static func conversion(success: Bool, detail: String) {
		post(title: success ? "Conversion Succeeded" : "Conversion Failed", body: detail)
	}
}

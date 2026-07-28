import AppKit
import UserNotifications

/// Everything here needs an application identity, which is why it lives in Imp rather than in
/// whatever Imp is running: an unbundled process can neither post a notification nor own a window.

/// Somewhere for a completion handler to leave its answer, since a captured `var` is not sendable.
final class Box<T>: @unchecked Sendable {
    var v: T
    init(_ v: T) { self.v = v }
}

func notifyAuthorized() -> Bool {
    let sem = DispatchSemaphore(value: 0), ok = Box(false)
    UNUserNotificationCenter.current().getNotificationSettings { s in
        ok.v = s.authorizationStatus == .authorized
        sem.signal()
    }
    sem.wait()
    return ok.v
}

func notifyRequest() {
    let sem = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in sem.signal() }
    sem.wait()
}

func notify(_ title: String, _ body: String) -> Int32 {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    let sem = DispatchSemaphore(value: 0), err = Box<Error?>(nil)
    UNUserNotificationCenter.current().add(req) { e in
        err.v = e
        sem.signal()
    }
    sem.wait()
    guard let e = err.v else { return 0 }
    FileHandle.standardError.write("Imp: \(e.localizedDescription)\n".data(using: .utf8)!)
    return 1
}

/// A modal box, for when a notification is too easy to miss. Exits with the index of the button pressed.
@MainActor func alert(_ title: String, _ body: String, buttons: [String]) -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = body
    for b in buttons { a.addButton(withTitle: b) }
    app.activate(ignoringOtherApps: true)
    return Int32(a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
}

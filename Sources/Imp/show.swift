import AppKit
import UserNotifications
import WebKit

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

/// On macOS the authorization request is a banner, not a modal: clicking it opens Settings
/// and fires the completion with false before the person has decided anything. So only a
/// true return is definitive; false means "not yet", and the caller must poll.
func notifyRequest() -> Bool {
    let sem = DispatchSemaphore(value: 0), ok = Box(false)
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { g, _ in
        ok.v = g
        sem.signal()
    }
    sem.wait()
    return ok.v
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


/// Modal panel shell shared by every windowed widget: Esc or the close button ends the
/// modal session. Returns .cancel for those, .OK otherwise.
final class CloseStopper: NSObject, NSWindowDelegate {
    func windowWillClose(_ n: Notification) { NSApplication.shared.stopModal(withCode: .cancel) }
}

/// A faceless app has no menu bar, so cmd-C/cmd-A key equivalents have nothing to route
/// through; this minimal Edit menu restores them (nil targets walk the responder chain).
@MainActor func installEditMenu() {
    let main = NSMenu(), edit = NSMenuItem(), m = NSMenu(title: "Edit")
    m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.submenu = m
    main.addItem(edit)
    NSApplication.shared.mainMenu = main
}

@MainActor func runPanel(_ title: String, _ content: NSView, w: CGFloat = 800, h: CGFloat = 600) -> NSApplication.ModalResponse {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    installEditMenu()
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    panel.title = title
    panel.hidesOnDeactivate = false  // the NSPanel default hides it when another app activates, leaving a blocked process with no visible window
    panel.level = .floating          // stay above other windows until dealt with; macOS has no cross-app modality
    content.frame = panel.contentView!.bounds
    content.autoresizingMask = [.width, .height]
    panel.contentView!.addSubview(content)
    panel.center()
    let stopper = CloseStopper()
    panel.delegate = stopper
    let mon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
        if e.keyCode == 53 { NSApplication.shared.stopModal(withCode: .cancel); return nil }  // Esc
        return e
    }
    app.activate(ignoringOtherApps: true)
    let res = app.runModal(for: panel)
    if let mon { NSEvent.removeMonitor(mon) }
    panel.delegate = nil
    panel.close()
    return res
}

/// A web page (or stdin HTML, when `target` is "-") in a modal panel.
@MainActor func web(_ title: String, _ target: String) -> Int32 {
    let v = WKWebView(frame: .zero)
    if target == "-" {
        let html = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        v.loadHTMLString(html, baseURL: nil)
    } else if let u = URL(string: target), u.scheme != nil {
        v.load(URLRequest(url: u))
    } else {
        let f = URL(fileURLWithPath: target)
        v.loadFileURL(f, allowingReadAccessTo: f.deletingLastPathComponent())
    }
    _ = runPanel(title, v)
    return 0
}


/// A numbered menu in a modal panel: press an item's digit to choose it. The chosen index
/// goes to stdout (not the exit code, which dies at 255); Esc or close prints nothing.
@MainActor func pick(_ title: String, _ items: [String]) -> Int32 {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    for (i, item) in items.enumerated() {
        let l = NSTextField(labelWithString: "\(i)  \(item)")
        l.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        l.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(l)
    }
    let mon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
        if let d = Int(e.characters ?? ""), d < items.count {
            NSApplication.shared.stopModal(withCode: .init(1000 + d))
            return nil
        }
        return e
    }
    let res = runPanel(title, stack, w: 460, h: CGFloat(items.count * 26 + 28))
    if let mon { NSEvent.removeMonitor(mon) }
    guard res.rawValue >= 1000 else { return 1 }
    print(res.rawValue - 1000)
    return 0
}

/// Stdin, monospaced and selectable, in a scrollable modal panel.
@MainActor func show(_ title: String) -> Int32 {
    let sv = NSTextView.scrollableTextView()
    let tv = sv.documentView as! NSTextView
    tv.string = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    tv.isEditable = false
    tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    tv.textContainerInset = NSSize(width: 8, height: 8)
    _ = runPanel(title, sv, w: 640, h: 420)
    return 0
}

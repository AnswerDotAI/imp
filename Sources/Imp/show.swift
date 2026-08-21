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


/// Modal panel shell shared by every wisp: Esc or the close button ends the
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

/// Where a panel goes, parsed from `--frame`: "tr"/"tl"/"br"/"bl" pin to that corner of the
/// visible screen (dock and menu bar respected), "400x300" sets the size centered, "400x300@tr" both.
struct FrameSpec {
    var w: CGFloat?, h: CGFloat?, corner: String?
    init?(_ s: String) {
        var size = s
        if let at = s.firstIndex(of: "@") {
            size = String(s[..<at])
            corner = String(s[s.index(after: at)...])
        } else if ["tl", "tr", "bl", "br"].contains(s) {
            size = ""
            corner = s
        }
        if let c = corner, !["tl", "tr", "bl", "br"].contains(c) { return nil }
        if !size.isEmpty {
            let parts = size.split(separator: "x")
            guard parts.count == 2, let pw = Double(parts[0]), let ph = Double(parts[1]) else { return nil }
            w = pw
            h = ph
        }
        if w == nil && corner == nil { return nil }
    }
}

/// A panel that can never become key: it cannot steal focus while the person works
/// elsewhere, and Esc cannot reach it, since Esc is only delivered to the key window.
final class KeylessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor func makePanel(_ title: String, _ content: NSView, w: CGFloat, h: CGFloat, frame: FrameSpec?, live: Bool = false, key: Bool = false) -> NSPanel {
    let w = frame?.w ?? w, h = frame?.h ?? h
    var style: NSWindow.StyleMask = [.titled, .closable]
    if live { style.insert(.nonactivatingPanel) }
    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    let panel = !live ? NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
              : key   ? KeyPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
                      : KeylessPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
    panel.title = title
    panel.hidesOnDeactivate = false  // the NSPanel default hides it when another app activates, leaving a blocked process with no visible window
    panel.level = .floating          // stay above other windows until dealt with; macOS has no cross-app modality
    content.frame = panel.contentView!.bounds
    content.autoresizingMask = [.width, .height]
    panel.contentView!.addSubview(content)
    if let c = frame?.corner, let vis = NSScreen.main?.visibleFrame {
        let m: CGFloat = 16, sz = panel.frame.size  // the window frame, so the title bar is accounted for
        panel.setFrameOrigin(NSPoint(x: c.hasSuffix("l") ? vis.minX + m : vis.maxX - sz.width - m,
                                     y: c.hasPrefix("b") ? vis.minY + m : vis.maxY - sz.height - m))
    } else { panel.center() }
    return panel
}

@MainActor func runPanel(_ title: String, _ content: NSView, w: CGFloat = 800, h: CGFloat = 600, frame: FrameSpec? = nil) -> NSApplication.ModalResponse {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    installEditMenu()
    let panel = makePanel(title, content, w: w, h: h, frame: frame)
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

/// Ends a live panel when the person closes it: distinct from EOF's 0, since "your lamp
/// was dismissed" is information the caller may want.
final class LiveCloser: NSObject, NSWindowDelegate {
    func windowWillClose(_ n: Notification) { exit(2) }
}

/// The leashed mode shared by live wisps: stdin is the lifeline. Each stdin line goes to
/// `onLine` on the main thread, EOF exits 0, the close button exits 2, and a parent's
/// SIGTERM exits 0 so a terminate never reads as a dismissal. The app is never activated,
/// so the person's frontmost app keeps its place; without `key` the panel never takes key
/// focus either, and with `key` it takes the keyboard while that app stays frontmost.
@MainActor func runLive(_ title: String, _ content: NSView, w: CGFloat, h: CGFloat, frame: FrameSpec?, key: Bool = false, onLine: @escaping (String) -> Void) -> Never {
    signal(SIGTERM) { _ in exit(0) }  // exit 2 must keep meaning "the person closed the panel": AppKit answers a terminate by closing windows first, so a caller killing its own wisp would exit 2 and read as a dismissal
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = makePanel(title, content, w: w, h: h, frame: frame, live: true, key: key)
    let closer = LiveCloser()
    panel.delegate = closer
    if key { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(content) }
    else { panel.orderFrontRegardless() }
    let handler = Box(onLine)
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            DispatchQueue.main.async { MainActor.assumeIsolated { handler.v(line) } }
        }
        DispatchQueue.main.async { exit(0) }
    }
    app.run()
    exit(0)
}

/// JSON-lines bridge for a live page. `ready` is always first: page scripts may post while
/// loading, so their messages wait here until didFinish proves that caller JS is safe to run.
final class WebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var pending = [Any](), ready = false

    func write(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else {
            FileHandle.standardError.write("Imp: page posted a value that is not JSON-serializable\n".data(using: .utf8)!)
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage) {
        if ready { write(["kind": "message", "value": m.body]) }
        else { pending.append(m.body) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !ready else { return }
        ready = true
        write(["kind": "ready"])
        for value in pending { write(["kind": "message", "value": value]) }
        pending.removeAll()
    }

    func failed(_ error: Error) {
        FileHandle.standardError.write("Imp: page failed to load: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
}

/// A web page in a panel. `target` "-" reads HTML from stdin; nil is about:blank. Live mode
/// evaluates each stdin line as JavaScript in the loaded page: the page defines its own
/// update functions and the caller sends calls, so updates are incremental and flicker-free.
/// A live page writes JSON-lines `ready` and `message` events to stdout; the latter carry
/// whatever it sends with webkit.messageHandlers.imp.postMessage(value).
@MainActor func web(_ title: String, _ target: String?, frame: FrameSpec? = nil, live: Bool = false, key: Bool = false) -> Int32 {
    let cfg = WKWebViewConfiguration()
    let bridge = live ? WebBridge() : nil
    if let bridge { cfg.userContentController.add(bridge, name: "imp") }
    let v = WKWebView(frame: .zero, configuration: cfg)
    v.navigationDelegate = bridge
    let t = target ?? "about:blank"
    if t == "-" {
        if live {
            FileHandle.standardError.write("Imp: --live reads JS lines from stdin, so \"-\" has no meaning; pass a url or file, or omit for about:blank\n".data(using: .utf8)!)
            return usageExit
        }
        let html = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        v.loadHTMLString(html, baseURL: nil)
    } else if let u = URL(string: t), u.scheme != nil {
        v.load(URLRequest(url: u))
    } else {
        let f = URL(fileURLWithPath: t)
        v.loadFileURL(f, allowingReadAccessTo: f.deletingLastPathComponent())
    }
    if live {
        runLive(title, v, w: 800, h: 600, frame: frame, key: key) { line in
            v.evaluateJavaScript(line) { _, e in
                if let e { FileHandle.standardError.write("Imp: \(e.localizedDescription)\n".data(using: .utf8)!) }
            }
        }
    }
    _ = runPanel(title, v, frame: frame)
    return 0
}


/// A key-driven menu in a panel. `keys` assigns one keystroke per item, in order; nil
/// assigns incrementing digits. The chosen index goes to stdout (not the exit
/// code, which dies at 255); Esc or close prints nothing and exits 1.
@MainActor func pick(_ title: String, _ items: [String], keys: String? = nil, frame: FrameSpec? = nil) -> Int32 {
    var assigned = [Character]()
    if let keys {
        guard keys.count == items.count else {
            FileHandle.standardError.write("Imp: --keys needs one character per item\n".data(using: .utf8)!)
            return usageExit
        }
        assigned = Array(keys.lowercased())
    } else {
        let pool = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        guard items.count <= pool.count else {
            FileHandle.standardError.write("Imp: more than 36 items need --keys; only digits and letters exist\n".data(using: .utf8)!)
            return usageExit
        }
        assigned = items.indices.map { pool[$0] }
    }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    for (i, label) in items.enumerated() {
        let l = NSTextField(labelWithString: "\(assigned[i])  \(label)")
        l.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(l)
        // A row wider than the stack breaks its leading pin and drifts toward center: cap it so truncation engages
        l.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28).isActive = true
    }
    let mon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
        if let ch = e.characters?.lowercased().first, let idx = assigned.firstIndex(of: ch) {
            NSApplication.shared.stopModal(withCode: .init(1000 + idx))
            return nil
        }
        return e
    }
    let res = runPanel(title, stack, w: 460, h: CGFloat(items.count * 26 + 28), frame: frame)
    if let mon { NSEvent.removeMonitor(mon) }
    guard res.rawValue >= 1000 else { return 1 }
    print(res.rawValue - 1000)
    return 0
}

/// Stdin, monospaced and selectable, in a scrollable panel. Live mode replaces the text
/// with each stdin line as it arrives, which is all a badge or ticker needs.
@MainActor func show(_ title: String, frame: FrameSpec? = nil, live: Bool = false) -> Int32 {
    let sv = NSTextView.scrollableTextView()
    let tv = sv.documentView as! NSTextView
    tv.isEditable = false
    tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    tv.textContainerInset = NSSize(width: 8, height: 8)
    if live { runLive(title, sv, w: 220, h: 72, frame: frame) { tv.string = $0 } }
    tv.string = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    _ = runPanel(title, sv, w: 640, h: 420, frame: frame)
    return 0
}

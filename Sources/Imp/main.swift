import ApplicationServices
import AVFoundation
import CImp
import Contacts
import CoreGraphics
import Darwin
import EventKit
import Foundation
import Photos
import Speech

// The version the build stamps into Info.plist as CFBundleShortVersionString (see DEV.md)
let impVersion = "0.2.0"
let usageExit: Int32 = 64

func exePath(_ pid: pid_t) -> String {
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(decoding: buf[..<Int(n)], as: UTF8.self) : ""
}

/// Does TCC attribute this process to Imp? A process spawned by a terminal inherits the
/// terminal's identity, so any grant it reports is the wrong one.
func amImp() -> Bool {
    let r = responsiblePid(for: getpid())
    return r == getpid() || exePath(r) == exePath(getpid())
}

func spawn(_ args: [String], disclaim: Bool = false) -> pid_t {
    let argv = args.map { strdup($0) } + [nil]
    defer { for p in argv { free(p) } }
    var pid: pid_t = 0
    let rc = impSpawn(argv, disclaim: disclaim ? 1 : 0, pid: &pid)
    if rc != 0 {
        FileHandle.standardError.write("Imp: cannot run \(args[0]): \(String(cString: strerror(rc)))\n".data(using: .utf8)!)
        exit(127)
    }
    return pid
}

nonisolated(unsafe) var childPid: pid_t = 0

func wait(_ pid: pid_t) -> Int32 {
    childPid = pid
    for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig, { s in kill(childPid, s) }) }
    defer { for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig, SIG_DFL) } }  // else the handler outlives the child and forwards ctrl-c to a dead pid
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return exitStatus(of: status)
}

/// The AVFoundation-family categories need their usage string in Info.plist (`imp_plist`
/// in this repo's devtool.py): macOS kills the process outright when one is requested without it.
/// Each completion carries the person's actual answer, so a true return is definitive.
func askSync(_ f: (@escaping @Sendable (Bool) -> Void) -> Void) -> Bool {
    let sem = DispatchSemaphore(value: 0), ok = Box(false)
    f { g in ok.v = g; sem.signal() }
    sem.wait()
    return ok.v
}

struct Perm {
    let name: String
    let pane: String       // Settings URL, printed when the one-shot dialog does not come
    let check: () -> Bool
    let request: () -> Bool?  // true confirms the grant (skip polling); false or nil decide nothing, so poll `check`
}

nonisolated(unsafe) let perms = [
    Perm(name: "accessibility", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
         check: { AXIsProcessTrusted() },
         request: { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary); return nil }),
    Perm(name: "screen", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
         check: { CGPreflightScreenCaptureAccess() },
         request: { _ = CGRequestScreenCaptureAccess(); return nil }),
    Perm(name: "notifications", pane: "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
         check: { notifyAuthorized() },
         request: { notifyRequest() }),
    Perm(name: "microphone", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
         check: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         request: { askSync { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) } }),
    Perm(name: "camera", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
         check: { AVCaptureDevice.authorizationStatus(for: .video) == .authorized },
         request: { askSync { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) } }),
    Perm(name: "speech", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
         check: { SFSpeechRecognizer.authorizationStatus() == .authorized },
         request: { askSync { done in SFSpeechRecognizer.requestAuthorization { done($0 == .authorized) } } }),
    Perm(name: "contacts", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts",
         check: { CNContactStore.authorizationStatus(for: .contacts) == .authorized },
         request: { askSync { done in CNContactStore().requestAccess(for: .contacts) { g, _ in done(g) } } }),
    Perm(name: "calendars", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
         check: { EKEventStore.authorizationStatus(for: .event) == .fullAccess },
         request: { askSync { done in EKEventStore().requestFullAccessToEvents { g, _ in done(g) } } }),
    Perm(name: "reminders", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders",
         check: { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess },
         request: { askSync { done in EKEventStore().requestFullAccessToReminders { g, _ in done(g) } } }),
    Perm(name: "photos", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos",
         check: { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized },
         request: { askSync { done in PHPhotoLibrary.requestAuthorization(for: .readWrite) { done($0 == .authorized) } } }),
]

func perm(_ name: String) -> Perm? { perms.first { $0.name == name } }

/// Ask a fresh copy of ourselves, because a grant made after launch is invisible to the
/// process that requested it (Screen Recording never updates in place; Accessibility may not).
/// Its stdout goes to /dev/null for the spawn's brief life, so `--check`'s "ok" never leaks into our own output.
func granted(_ p: Perm) -> Bool {
    let saved = dup(1)
    let devnull = open("/dev/null", O_WRONLY)
    dup2(devnull, 1)
    close(devnull)
    defer { dup2(saved, 1); close(saved) }
    return wait(spawn([exePath(getpid()), "--check", p.name])) == 0
}

func waitFor(_ p: Perm, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if granted(p) { return true }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return false
}


/// Automation consent is per target app, asked with an Apple Events round trip rather than
/// a Perm row. With `ask`, the dialog can only appear while the target is running, and the
/// answer comes back synchronously, so a zero return is definitive.
func automationStatus(_ bundle: String, ask: Bool) -> OSStatus {
    var addr = AEAddressDesc()
    let data = Array(bundle.utf8)
    data.withUnsafeBufferPointer { _ = AECreateDesc(typeApplicationBundleID, $0.baseAddress, data.count, &addr) }
    defer { AEDisposeDesc(&addr) }
    return AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, ask)
}

func autoTarget(_ name: String) -> String? {
    name.hasPrefix("automation:") ? String(name.dropFirst("automation:".count)) : nil
}

func checkName(_ name: String) -> Bool {
    if let t = autoTarget(name) { return automationStatus(t, ask: false) == noErr }
    return perm(name)?.check() ?? false
}

func grantAutomation(_ name: String, _ target: String) -> Bool {
    switch automationStatus(target, ask: true) {
    case noErr: print("\(name): granted"); return true
    case -600: print("\(name): the target app is not running; open it and re-run")
    case let st: print("""
        \(name): STILL MISSING (status \(st))
        # open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        then switch the app on under Imp there, and re-run this command to confirm.
        """)
    }
    return false
}
/// macOS shows each permission dialog once per app per category, so a denied grant can
/// never be re-prompted: when no dialog comes, all we can honestly do is say what to do next.
func grant(_ names: [String]) -> Int32 {
    var failed = [String]()
    for name in names {
        if let t = autoTarget(name) {
            if checkName(name) { print("\(name): already granted"); continue }
            if !grantAutomation(name, t) { failed.append(name) }
            continue
        }
        guard let p = perm(name) else {
            print("unknown permission: \(name) (known: \(perms.map(\.name).joined(separator: ", ")))")
            return usageExit
        }
        if granted(p) { print("\(p.name): already granted"); continue }
        print("""
        \(p.name): Please approve the dialog naming Imp.
        I'll wait up to 2 mins for you to complete that.
        Hit ctrl-c to stop me waiting.
        macOS shows the dialog only once. To grant it by hand:
        # open "\(p.pane)"
        then switch Imp on in that pane, and re-run this command to confirm.
        """)
        let answer = p.request()
        if answer == true || waitFor(p, seconds: 120) { print("\(p.name): granted"); continue }
        print("\(p.name): STILL MISSING")
        failed.append(p.name)
    }
    return failed.isEmpty ? 0 : 1
}

/// tccutil's names for our categories. Notifications are missing because they are not TCC.
let tccNames = ["accessibility": "Accessibility", "screen": "ScreenCapture", "microphone": "Microphone",
                "camera": "Camera", "speech": "SpeechRecognition", "contacts": "AddressBook",
                "calendars": "Calendar", "reminders": "Reminders", "photos": "Photos",
                "automation": "AppleEvents"]  // resets every target at once: tccutil cannot scope to one

/// Return categories to not-determined, so the next --grant can show a dialog again, even
/// after a past denial. Like a grant, a reset only applies to processes started after it.
func reset(_ names: [String]) -> Int32 {
    let bundle = Bundle.main.bundleIdentifier ?? "com.answerdotai.imp"
    var failed = [String]()
    for name in names {
        guard let svc = name == "all" ? "All" : tccNames[autoTarget(name) != nil ? "automation" : name] else {
            if name == "notifications" {
                print("notifications: not TCC. In System Settings, Notifications, right-click Imp and choose Reset Notifications.")
            } else {
                print("unknown permission: \(name) (known: \(tccNames.keys.sorted().joined(separator: ", ")), all)")
            }
            failed.append(name)
            continue
        }
        let rc = wait(spawn(["/usr/bin/tccutil", "reset", svc, bundle]))
        print("\(name): \(rc == 0 ? "reset" : "tccutil failed (\(rc))")")
        if rc != 0 { failed.append(name) }
    }
    return failed.isEmpty ? 0 : 1
}

func status() {
    print("running as: \(amImp() ? "Imp" : "another process, so these are not Imp's grants")")
    for p in perms { print("\(p.name.padding(toLength: 14, withPad: " ", startingAt: 0)): \(p.check())") }
}

/// Pull the shared panel flags out of a wisp verb's arguments, leaving the positionals.
func panelOpts(_ rest: [String]) -> (pos: [String], live: Bool, key: Bool, frame: FrameSpec?) {
    var pos = [String](), live = false, key = false, frame: FrameSpec? = nil
    var i = 0
    while i < rest.count {
        let a = rest[i]
        if a == "--live" { live = true }
        else if a == "--key" { key = true }
        else if a == "--frame" {
            i += 1
            guard i < rest.count, let f = FrameSpec(rest[i]) else {
                print("bad --frame spec\(i < rest.count ? ": \(rest[i])" : "")")
                usage()
            }
            frame = f
        }
        else { pos.append(a) }
        i += 1
    }
    return (pos, live, key, frame)
}


func usage(_ code: Int32 = usageExit) -> Never {
    print("""
    usage: Imp <command> [args...]      run a command with Imp's permissions
           Imp --grant <a,b>            get the named permissions, one at a time
           Imp --check <a,b>            print "ok" and exit 0 if all are granted, else exit 1 silently
           Imp --reset <a,b|all>        return categories to not-determined, so a dialog can come again
           Imp --status                 report every permission's state
           Imp --version                print the version
           Imp --notify <title> [body]  post a notification
           Imp --alert <title> [body] [button...]  show a message box; the exit code is the button index
           Imp --web <title> [url|file|-]      show a web page in a panel; "-" reads HTML from stdin, no target is about:blank
           Imp --pick <title> [--keys <chars>] <item...>  choose by key: one char per item, or digits then letters; index to stdout
           Imp --show <title>                  show stdin in a scrollable monospaced panel

    --web and --show take --live: stdin becomes the lifeline (a line per update: text for
    --show, JS evaluated in the page for --web), EOF exits 0, closing the panel exits 2,
    and the panel never takes focus. --web --live also takes --key: the panel takes the
    keyboard while the previous app stays frontmost; stdout emits a JSON ready event, then
    JSON message events for webkit.messageHandlers.imp.postMessage(value). --web, --pick, and --show take
    --frame <spec>, where spec is tr|tl|br|bl (corner), 400x300 (size), or 400x300@tr (both).
           Imp --snap <path|->          capture a still from the default camera; '-' writes it to stdout

    permissions: \(perms.map(\.name).joined(separator: ", ")), automation:<bundle-id>
    """)
    exit(code)
}

let args = CommandLine.arguments
if args.count > 1, args[1] == "--version" { print(impVersion); exit(0) }

// Everything Imp does must happen as Imp, so re-spawn ourselves disclaimed if we were
// launched by something that already owns a TCC identity. Re-spawn by our real path, since
// a shell gives argv[0] as the bare name when it finds us on PATH, and posix_spawn has no
// PATH lookup of its own.
if !amImp() { exit(wait(spawn([exePath(getpid())] + args.dropFirst(), disclaim: true))) }

if args.count < 2 { usage() }
switch args[1] {
case "--status": status(); exit(0)
case "--help", "-h": usage(0)
case "--reset":
    if args.count < 3 { usage() }
    exit(reset(args[2].split(separator: ",").map(String.init)))
case "--grant", "--check":
    if args.count < 3 { usage() }
    let names = args[2].split(separator: ",").map(String.init)
    if args[1] == "--grant" { exit(grant(names)) }
    if !names.allSatisfy(checkName) { exit(1) }
    print("ok")
    exit(0)
case "--notify":
    if args.count < 3 { usage() }
    exit(notify(args[2], args.count > 3 ? args[3] : ""))
case "--alert":
    if args.count < 3 { usage() }
    let buttons = args.count > 4 ? Array(args[4...]) : ["OK"]
    exit(alert(args[2], args.count > 3 ? args[3] : "", buttons: buttons))
case "--web":
    let (pos, live, key, frame) = panelOpts(Array(args.dropFirst(2)))
    guard pos.count == 2 || (live && pos.count == 1) else { usage() }  // a target is optional only when live JS can build the page
    if key && !live { print("--key requires --live: a modal panel already takes focus"); usage() }
    exit(web(pos[0], pos.count > 1 ? pos[1] : nil, frame: frame, live: live, key: key))
case "--pick":
    var rest = Array(args.dropFirst(2)), keys: String? = nil
    if let i = rest.firstIndex(of: "--keys") {
        guard i + 1 < rest.count else { usage() }
        keys = rest[i + 1]
        rest.removeSubrange(i...(i + 1))
    }
    let (pos, live, key, frame) = panelOpts(rest)
    if live { print("--pick cannot be --live: a pick exists to be answered"); usage() }
    if key { print("--pick cannot take --key: a pick already has the keyboard"); usage() }
    guard pos.count >= 2 else { usage() }
    exit(pick(pos[0], Array(pos.dropFirst()), keys: keys, frame: frame))
case "--show":
    let (pos, live, key, frame) = panelOpts(Array(args.dropFirst(2)))
    if key { print("--show cannot take --key: use --web for an interactive page"); usage() }
    guard pos.count == 1 else { usage() }
    exit(show(pos[0], frame: frame, live: live))
case "--snap":
    if args.count < 3 { usage() }
    exit(snap(args[2]))
default:
    if args[1].hasPrefix("-") { print("unknown option: \(args[1])"); usage() }
    exit(wait(spawn(Array(args.dropFirst()))))
}

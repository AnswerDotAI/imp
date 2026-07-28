import ApplicationServices
import CImp
import CoreGraphics
import Darwin
import Foundation

// The version the build stamps into Info.plist as CFBundleShortVersionString (see DEV.md)
let impVersion = "0.1.0"

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
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return exitStatus(of: status)
}

struct Perm {
    let name: String
    let pane: String       // Settings URL, for the categories macOS will not prompt for twice
    let manual: String?    // What the user must do by hand, when there is no prompt
    let check: () -> Bool
    let request: () -> Void
}

nonisolated(unsafe) let perms = [
    Perm(name: "accessibility", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", manual: nil,
         check: { AXIsProcessTrusted() },
         request: { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }),
    Perm(name: "screen", pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", manual: nil,
         check: { CGPreflightScreenCaptureAccess() },
         request: { _ = CGRequestScreenCaptureAccess() }),
    // manual is nil because macOS does prompt for this one; the Settings pane is only the fallback
    Perm(name: "notifications", pane: "x-apple.systempreferences:com.apple.Notifications-Settings.extension", manual: nil,
         check: { notifyAuthorized() },
         request: { notifyRequest() }),
]

func perm(_ name: String) -> Perm? { perms.first { $0.name == name } }

/// Ask a fresh copy of ourselves, because a grant made after launch is invisible to the
/// process that requested it (Screen Recording never updates in place; Accessibility may not).
func granted(_ p: Perm) -> Bool { wait(spawn([exePath(getpid()), "--check", p.name])) == 0 }

func openPane(_ p: Perm) {
    _ = wait(spawn(["/usr/bin/open", p.pane]))
}

func waitFor(_ p: Perm, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if granted(p) { return true }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return false
}

/// macOS shows each dialog once per app per category, so a denied grant can never be
/// re-prompted: fall through to the Settings pane and wait for the user instead.
func grant(_ names: [String]) -> Int32 {
    var failed = [String]()
    for name in names {
        guard let p = perm(name) else {
            print("unknown permission: \(name) (known: \(perms.map(\.name).joined(separator: ", ")))")
            return 2
        }
        if granted(p) { print("\(p.name): already granted"); continue }
        if p.manual == nil {
            print("\(p.name): asking. Say yes to the prompt; if none appears this waits 20s, then opens Settings.")
            p.request()
            if waitFor(p, seconds: 20) { print("\(p.name): granted"); continue }
        }
        print("\(p.name): needs granting by hand. Opening Settings.")
        if let m = p.manual { print("  \(m)") }
        else { print("  Find Imp in the list that opens and switch it on.") }
        openPane(p)
        if waitFor(p, seconds: 180) { print("\(p.name): granted") }
        else { print("\(p.name): STILL MISSING"); failed.append(p.name) }
    }
    return failed.isEmpty ? 0 : 1
}

func status() {
    print("running as: \(amImp() ? "Imp" : "another process, so these are not Imp's grants")")
    for p in perms { print("\(p.name.padding(toLength: 14, withPad: " ", startingAt: 0)): \(p.check())") }
}

func usage() -> Never {
    print("""
    usage: Imp <command> [args...]      run a command with Imp's permissions
           Imp --grant <a,b>            get the named permissions, one at a time
           Imp --check <a,b>            exit 0 if all are granted, else 1
           Imp --status                 report every permission's state
           Imp --version                print the version
           Imp --notify <title> [body]  post a notification
           Imp --alert <title> [body] [button...]  show a message box; the exit code is the button index
    """)
    exit(2)
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
case "--grant", "--check":
    if args.count < 3 { usage() }
    let names = args[2].split(separator: ",").map(String.init)
    if args[1] == "--grant" { exit(grant(names)) }
    exit(names.allSatisfy { perm($0)?.check() ?? false } ? 0 : 1)
case "--notify":
    if args.count < 3 { usage() }
    exit(notify(args[2], args.count > 3 ? args[3] : ""))
case "--alert":
    if args.count < 3 { usage() }
    let buttons = args.count > 4 ? Array(args[4...]) : ["OK"]
    exit(alert(args[2], args.count > 3 ? args[3] : "", buttons: buttons))
default: exit(wait(spawn(Array(args.dropFirst()))))
}

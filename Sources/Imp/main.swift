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
    defer { for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig, SIG_DFL) } }  // else the handler outlives the child and forwards ctrl-c to a dead pid
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return exitStatus(of: status)
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
]

func perm(_ name: String) -> Perm? { perms.first { $0.name == name } }

/// Ask a fresh copy of ourselves, because a grant made after launch is invisible to the
/// process that requested it (Screen Recording never updates in place; Accessibility may not).
func granted(_ p: Perm) -> Bool { wait(spawn([exePath(getpid()), "--check", p.name])) == 0 }

func waitFor(_ p: Perm, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if granted(p) { return true }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return false
}

/// macOS shows each permission dialog once per app per category, so a denied grant can
/// never be re-prompted: when no dialog comes, all we can honestly do is say what to do next.
func grant(_ names: [String]) -> Int32 {
    var failed = [String]()
    for name in names {
        guard let p = perm(name) else {
            print("unknown permission: \(name) (known: \(perms.map(\.name).joined(separator: ", ")))")
            return 2
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
           Imp --web <title> <url|file|->      show a web page in a panel; "-" reads HTML from stdin
           Imp --pick <title> <item...>        choose by digit (max 10 items); the index goes to stdout, Esc exits 1
           Imp --show <title>                  show stdin in a scrollable monospaced panel
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
case "--web":
    if args.count < 4 { usage() }
    exit(web(args[2], args[3]))
case "--pick":
    if args.count < 4 || args.count > 13 { usage() }  // a digit selects, so ten items at most
    exit(pick(args[2], Array(args[3...])))
case "--show":
    if args.count < 3 { usage() }
    exit(show(args[2]))
default: exit(wait(spawn(Array(args.dropFirst()))))
}

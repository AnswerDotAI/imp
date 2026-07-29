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

/// The AVFoundation-family categories need their usage string in Info.plist (`imp_plist`
/// in macmage's devtool.py): macOS kills the process outright when one is requested without it.
/// Each completion carries the person's actual answer, so a true return is definitive.
func askSync(_ f: (@escaping @Sendable (Bool) -> Void) -> Void) -> Bool {
    let sem = DispatchSemaphore(value: 0), ok = Box(false)
    f { g in ok.v = g; sem.signal() }
    sem.wait()
    return ok.v
}

/// TEMPORARY probe: open the default audio device for real and count sample buffers,
/// because "TCC says no" and "capture fails" are different claims.
final class MicTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let n = Box(0), bytes = Box(0), nonzero = Box(0)
    func captureOutput(_ o: AVCaptureOutput, didOutput b: CMSampleBuffer, from c: AVCaptureConnection) {
        n.v += 1
        // Digital silence is all-zero bytes whatever the sample format, so a byte scan needs no format handling
        var abl = AudioBufferList(), blk: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            b, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blk)
        for buf in UnsafeMutableAudioBufferListPointer(&abl) {
            guard let d = buf.mData else { continue }
            let raw = UnsafeRawBufferPointer(start: d, count: Int(buf.mDataByteSize))
            bytes.v += raw.count
            nonzero.v += raw.reduce(0) { $1 == 0 ? $0 : $0 + 1 }
        }
    }
}

func micTest() -> Int32 {
    print("authorizationStatus: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 authorized)")
    guard let dev = AVCaptureDevice.default(for: .audio) else { print("no audio device"); return 1 }
    print("device: \(dev.localizedName)")
    let sess = AVCaptureSession(), outp = AVCaptureAudioDataOutput(), tap = MicTap()
    do { sess.addInput(try AVCaptureDeviceInput(device: dev)) }
    catch { print("input failed: \(error)"); return 1 }
    outp.setSampleBufferDelegate(tap, queue: DispatchQueue(label: "mic"))
    sess.addOutput(outp)
    sess.startRunning()
    Thread.sleep(forTimeInterval: 1.5)
    sess.stopRunning()
    print("buffers in 1.5s: \(tap.n.v), bytes: \(tap.bytes.v), nonzero bytes: \(tap.nonzero.v)")
    return tap.n.v > 0 ? 0 : 1
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

/// tccutil's names for our categories. Notifications are missing because they are not TCC.
let tccNames = ["accessibility": "Accessibility", "screen": "ScreenCapture", "microphone": "Microphone",
                "camera": "Camera", "speech": "SpeechRecognition", "contacts": "AddressBook",
                "calendars": "Calendar", "reminders": "Reminders", "photos": "Photos"]

/// Return categories to not-determined, so the next --grant can show a dialog again, even
/// after a past denial. Like a grant, a reset only applies to processes started after it.
func reset(_ names: [String]) -> Int32 {
    let bundle = Bundle.main.bundleIdentifier ?? "com.answerdotai.imp"
    var failed = [String]()
    for name in names {
        guard let svc = name == "all" ? "All" : tccNames[name] else {
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

func usage() -> Never {
    print("""
    usage: Imp <command> [args...]      run a command with Imp's permissions
           Imp --grant <a,b>            get the named permissions, one at a time
           Imp --check <a,b>            exit 0 if all are granted, else 1
           Imp --reset <a,b|all>        return categories to not-determined, so a dialog can come again
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
case "--reset":
    if args.count < 3 { usage() }
    exit(reset(args[2].split(separator: ",").map(String.init)))
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
case "--mictest": exit(micTest())  // TEMPORARY probe: does the mic actually deliver samples?
default: exit(wait(spawn(Array(args.dropFirst()))))
}

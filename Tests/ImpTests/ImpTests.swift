import Testing
import CImp
import Foundation

@Test func arithmetic() {
    #expect(1 + 1 == 2)
}

// The macros Swift cannot import, checked against the encoding wait(2) actually uses:
// an exit code sits in the high byte, a killing signal in the low seven bits.
@Test func exitStatusDecoding() {
    #expect(exitStatus(of: 0) == 0)
    #expect(exitStatus(of: 3 << 8) == 3)
    #expect(exitStatus(of: SIGTERM) == 128 + SIGTERM)
}

let imp = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/Imp")

func runImp(_ args: [String]) throws -> (Int32, String) {
    let p = Process(), out = Pipe()
    p.executableURL = imp
    p.arguments = args
    p.standardOutput = out
    p.standardError = out
    try p.run()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

@Test func checkReportsAllMissingPermissions() throws {
    let (status, out) = try runImp(["--check", "microphone,camera"])
    #expect(status == 1)
    #expect(out == "missing: microphone, camera\n")
}

@Test func combinedGrantRunsEveryName() throws {
    let (status, out) = try runImp(["--grant", "not-a-permission,also-not-a-permission"])
    #expect(status == 64)
    #expect(out.contains("unknown permission: not-a-permission"))
    #expect(out.contains("unknown permission: also-not-a-permission"))
}

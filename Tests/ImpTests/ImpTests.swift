import Testing
import CImp

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

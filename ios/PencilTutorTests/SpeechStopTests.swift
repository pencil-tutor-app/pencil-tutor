import XCTest
@testable import PencilTutor

/// `SpeechOutput.stopIfSpeaking`: a dismissed hint is cut off, but an answer that happens to be playing is not.
@MainActor
final class SpeechStopTests: XCTestCase {
    private var directory: URL!
    private var log: SessionLog!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-stop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = SessionLog(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOnlySpeechWithTheNamedPurposeIsStopped() {
        let speech = SpeechOutput(log: log, remote: nil, deviceOnlyReason: "unit_test")
        speech.speak("Check line two.", purpose: "hint")
        XCTAssertEqual(speech.speakingPurpose, "hint")
        XCTAssertFalse(speech.stopIfSpeaking(purpose: "answer", reason: "hint_disputed"), "not an answer's business")
        XCTAssertEqual(speech.speakingPurpose, "hint")
        XCTAssertTrue(speech.stopIfSpeaking(purpose: "hint", reason: "hint_disputed"))
        XCTAssertNil(speech.speakingPurpose)
        XCTAssertFalse(speech.stopIfSpeaking(purpose: "hint", reason: "hint_disputed"), "nothing left to stop")
        speech.stop()
    }
}

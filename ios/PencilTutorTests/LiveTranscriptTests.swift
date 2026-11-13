import XCTest
@testable import PencilTutor

final class LiveTranscriptTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testFragmentsFromOneSpeakerJoinIntoOneTurnAndFinishWhenQuiet() {
        var transcript = LiveTranscript()
        transcript.add(.student, fragment: "Hi", at: at(0))
        transcript.add(.student, fragment: ", can you", at: at(0.4))
        transcript.add(.student, fragment: " check my work?", at: at(0.8))
        XCTAssertTrue(transcript.finishQuiet(at: at(1.5)).isEmpty, "0.7 s after the last fragment is not quiet yet")
        let finished = transcript.finishQuiet(at: at(2.5))
        XCTAssertEqual(finished, [LiveTurn(speaker: .student, text: "Hi, can you check my work?")])
        XCTAssertEqual(transcript.turns, finished)
    }

    func testAGapLongerThanTheLimitStartsANewTurnAndReturnsTheOldOne() {
        var transcript = LiveTranscript()
        transcript.add(.student, fragment: "first thing", at: at(0))
        let finished = transcript.add(.student, fragment: "second thing", at: at(3))
        XCTAssertEqual(finished, [LiveTurn(speaker: .student, text: "first thing")])
        XCTAssertEqual(transcript.finishAll(), [LiveTurn(speaker: .student, text: "second thing")])
    }

    func testBothSpeakersCanTalkAtOnceAndKeepTheirOwnTurns() {
        var transcript = LiveTranscript()
        transcript.add(.tutor, fragment: "Sure,", at: at(0))
        transcript.add(.student, fragment: "wait", at: at(0.3))
        transcript.add(.tutor, fragment: " on it.", at: at(0.5))
        let all = transcript.finishAll()
        XCTAssertEqual(Set(all.map(\.text)), ["Sure, on it.", "wait"])
    }

    func testTheQuestionIsWhatTheStudentSaidSinceTheLastQuestionIncludingAnOpenTurn() {
        var transcript = LiveTranscript()
        transcript.add(.student, fragment: "is the second line right", at: at(0))
        transcript.finishQuiet(at: at(2))
        transcript.add(.student, fragment: "and the third", at: at(5))
        XCTAssertEqual(transcript.takeQuestion(), "is the second line right and the third")
    }

    func testAnOpenTurnIsNotCountedTwiceWhenItFinishesAfterTheQuestionWasTaken() {
        var transcript = LiveTranscript()
        transcript.add(.student, fragment: "check my work", at: at(0))
        XCTAssertEqual(transcript.takeQuestion(), "check my work")
        transcript.finishQuiet(at: at(2))
        transcript.add(.student, fragment: "now line three", at: at(6))
        XCTAssertEqual(transcript.takeQuestion(), "now line three", "the earlier words were already asked")
    }

    func testWithNothingNewTheQuestionRepeatsTheLastThingTheStudentSaid() {
        var transcript = LiveTranscript()
        transcript.add(.student, fragment: "is this right", at: at(0))
        transcript.finishQuiet(at: at(2))
        XCTAssertEqual(transcript.takeQuestion(), "is this right")
        XCTAssertEqual(transcript.takeQuestion(), "is this right", "a second ask with no new speech still has a question")
    }

    func testAStudentWhoNeverSpokeHasAnEmptyQuestion() {
        var transcript = LiveTranscript()
        transcript.add(.tutor, fragment: "Hello", at: at(0))
        transcript.finishAll()
        XCTAssertEqual(transcript.takeQuestion(), "")
    }

    func testRecentTurnsAreBoundedAndOldestFirst() {
        var transcript = LiveTranscript()
        for index in 0..<20 {
            transcript.add(index.isMultiple(of: 2) ? .student : .tutor, fragment: "turn \(index)", at: at(Double(index) * 5))
            transcript.finishQuiet(at: at(Double(index) * 5 + 3))
        }
        XCTAssertLessThanOrEqual(transcript.turns.count, LiveTranscript.keep)
        let recent = transcript.recent(limit: 6)
        XCTAssertEqual(recent.count, 6)
        XCTAssertEqual(recent.last?.text, "turn 19")
        XCTAssertEqual(recent.first?.text, "turn 14")
        XCTAssertEqual(recent.last?.role, "tutor")
    }

    func testVeryLongSpeechIsClipped() {
        var transcript = LiveTranscript()
        transcript.add(.student, fragment: String(repeating: "a", count: 5_000), at: at(0))
        let question = transcript.takeQuestion(maxCharacters: 600)
        XCTAssertLessThanOrEqual(question.count, 600)
        XCTAssertLessThanOrEqual(transcript.recent(maxCharactersPerTurn: 240).first?.text.count ?? 0, 240)
    }
}

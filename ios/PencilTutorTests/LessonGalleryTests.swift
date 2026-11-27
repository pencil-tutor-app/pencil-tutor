import SwiftUI
import XCTest
@testable import PencilTutor

/// Draws the lesson panel in each state it can be in (example pending, checked, withheld, with a conversation) into PNG files, so a
/// person can look at the type setting without an iPad. Skipped unless `LESSON_GALLERY_DIR` is set (with xcodebuild:
/// `TEST_RUNNER_LESSON_GALLERY_DIR=/some/folder xcodebuild test ...`). No sound, no app launch.
@MainActor
final class LessonGalleryTests: XCTestCase {
    func testDrawTheLessonPanelInEveryState() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LESSON_GALLERY_DIR"], !directory.isEmpty else {
            throw XCTSkip("set LESSON_GALLERY_DIR to write the gallery")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("lesson-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }

        func lesson(example: TeachExample, practice: Result<TeachPracticeResponse, Error>?, hold: Bool = false) async -> LessonSession {
            let client = FakeTeachClient()
            var reply = FakeTeachClient.lesson()
            reply.lesson?.title = "Solving by undoing"
            reply.lesson?.steps = ["An equation is a balance: whatever you do to one side, do to the other.",
                           "To get x alone, undo what was done to it, last operation first.",
                           "Undo adding by subtracting, and undo multiplying by dividing: x^2 = 9 gives x = ±3.",
                           "Check by putting your answer back: √(2x + 1) = 5 means 2x + 1 = 25."]
            reply.lesson?.example = example
            client.answerExplain(.success(reply))
            if let practice { client.answerPractice([practice]) }
            client.holdPractice(hold)
            let env = AppEnvironment(forTesting: client, log: SessionLog(directory: logDirectory))
            let session = LessonSession(courseSlug: "bc-math-9-unit-3", concept: "solving equations", env: env)
            session.start()
            let deadline = Date().addingTimeInterval(5)
            while session.phase == .loading, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            if !hold {
                while session.practiceState == .preparing, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            return session
        }

        let example = TeachExample(promptPlain: "Solve 2x + 1 = 9", steps: ["Subtract 1 from both sides: 2x = 8", "Divide both sides by 2: x = 4"], finalAnswer: "x = 4")
        let pending = await lesson(example: example, practice: nil, hold: true)
        let checked = await lesson(example: example, practice: .success(FakeTeachClient.practice(exampleChecked: true)))
        checked.noteExchange(student: "Why undo the last one first?", tutor: "Because it was done last, so it comes off first: 3x + 2 = 14 loses the + 2 before the 3.")
        let withheld = await lesson(example: example, practice: .success(FakeTeachClient.practice(exampleChecked: false)))

        for (name, session) in [("pending", pending), ("checked-with-conversation", checked), ("withheld", withheld)] {
            let sheet = LessonPanelContent(lesson: session, bodySize: 20)
                .padding(20)
                .frame(width: 520, alignment: .leading)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, "could not draw \(name)")
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: directory).appendingPathComponent("lesson-\(name).png"))
            session.stop()
        }
        XCTAssertNil(pending.visibleExample)
        XCTAssertNil(withheld.visibleExample)
        XCTAssertNotNil(checked.visibleExample)
    }
}

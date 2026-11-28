import SwiftUI
import XCTest
@testable import PencilTutor

/// Draws the Show me how panel in each state it can be in (working it out, the steps with Try one like it, not checked, failed, and
/// the steps with Try one like it refused) into PNG files, so a person can look at the type setting without an iPad. Skipped unless
/// `SHOW_ME_GALLERY_DIR` is set (with xcodebuild: `TEST_RUNNER_SHOW_ME_GALLERY_DIR=/some/folder xcodebuild test ...`). No sound, no app launch.
@MainActor
final class ShowMeGalleryTests: XCTestCase {
    func testDrawThePanelInEveryState() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SHOW_ME_GALLERY_DIR"], !directory.isEmpty else {
            throw XCTSkip("set SHOW_ME_GALLERY_DIR to write the gallery")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("show-me-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }

        let problem = Problem(id: "la-02", promptPlain: "Solve by Gaussian elimination: x + y + z = 6, 2x - y + z = 3, x + 2y - z = 2.")
        let seven = ["Write the augmented matrix: [1 1 1 6; 2 -1 1 3; 1 2 -1 2]",
                     "Subtract 2 times row 1 from row 2: [0 -3 -1 -9]", "Subtract row 1 from row 3: [0 1 -2 -4]",
                     "Swap rows 2 and 3 so the pivot is 1", "Add 3 times row 2 to row 3: [0 0 -7 -21]",
                     "Divide row 3 by -7: z = 3", "Back-substitute: y = 2, then x = 1"]

        func session(_ configure: (FakeTutorClient) -> Void, hold: Bool = false) async -> ShowMeSession {
            let client = FakeTutorClient()
            client.answerSolve(.success(FakeTutorClient.solved(steps: seven, finalAnswer: "(x, y, z) = (1, 2, 3)")))
            configure(client)
            client.holdSolves(hold)
            let env = AppEnvironment(forTesting: client, log: SessionLog(directory: logDirectory))
            let show = ShowMeSession(problem: problem, courseSlug: "linear-algebra", sessionID: "gallery", env: env)
            Task { await show.open(source: .button) }
            let deadline = Date().addingTimeInterval(5)
            while show.phase == .closed, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            if !hold {
                while show.phase == .loading, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            return show
        }

        let loading = await session({ _ in }, hold: true)
        let shown = await session({ _ in })
        let notChecked = await session({ $0.answerSolve(.success(FakeTutorClient.notChecked())) })
        let failed = await session({ $0.answerSolve(.failure(TutorError.timedOut)) })
        let likeRefused = await session({ $0.answerPractice(.success(TeachPracticeResponse(problem: nil, reason: "not_checked", problemRef: nil, exampleChecked: nil, requestId: "r", model: "m", latencyMs: 1))) })
        likeRefused.tryOneLikeIt()
        let deadline = Date().addingTimeInterval(5)
        while likeRefused.next != .notChecked, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }

        for (name, show) in [("loading", loading), ("steps", shown), ("not-checked", notChecked), ("failed", failed), ("like-it-refused", likeRefused)] {
            let sheet = ShowMePanel(showMe: show, statement: problem.promptParts, bodySize: 17)
                .frame(width: 360, height: 640)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, "could not draw \(name)")
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: directory).appendingPathComponent("show-me-\(name).png"))
            show.stop()
        }
        XCTAssertEqual(loading.phase, .loading)
        XCTAssertEqual(notChecked.phase, .notChecked)
        XCTAssertEqual(likeRefused.next, .notChecked)
    }
}

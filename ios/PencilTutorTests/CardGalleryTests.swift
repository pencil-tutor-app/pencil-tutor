import SwiftUI
import XCTest
@testable import PencilTutor

/// Draws the problem card for a handful of prompts from every course into PNG files, so a person can look at the typesetting
/// (exponents, roots, fractions, matrices, the longest word problems) without opening each problem on an iPad. Skipped unless
/// `CARD_GALLERY_DIR` is set (with xcodebuild: `TEST_RUNNER_CARD_GALLERY_DIR=/some/folder xcodebuild test ...`).
@MainActor
final class CardGalleryTests: XCTestCase {
    func testDrawTheCardForSamplePromptsFromEveryCourse() throws {
        guard let directory = ProcessInfo.processInfo.environment["CARD_GALLERY_DIR"], !directory.isEmpty else {
            throw XCTSkip("set CARD_GALLERY_DIR to write the gallery")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        UserDefaults.standard.set(false, forKey: "problemCard.collapsed")

        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared")
        struct Entry: Decodable { let slug: String; let title: String; let file: String }
        struct Manifest: Decodable { let courses: [Entry] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: shared.appendingPathComponent("courses/index.json")))

        for entry in manifest.courses {
            let problems = try ProblemBank.decode(Data(contentsOf: shared.appendingPathComponent(entry.file)))
            var picks: [Problem] = []
            func add(_ problem: Problem?) {
                if let problem, !picks.contains(where: { $0.id == problem.id }) { picks.append(problem) }
            }
            add(problems.first { $0.promptPlain.contains("^") })
            add(problems.first { $0.promptPlain.contains(";") && $0.promptPlain.contains("[") })
            add(problems.first { $0.promptPlain.contains("√") || $0.promptPlain.contains("∛") })
            add(problems.first { $0.promptPlain.contains("Σ") })
            add(problems.first { $0.promptParts.contains { if case .fraction = $0 { return true } else { return false } } })
            add(problems.first { $0.promptPlain.contains("/") && !$0.promptPlain.contains("^") })
            add(problems.first)
            add(problems.max { $0.promptPlain.count < $1.promptPlain.count })

            let sheet = VStack(alignment: .leading, spacing: 14) {
                Text("\(entry.title)  (\(entry.slug))").font(.headline)
                ForEach(picks) { problem in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(problem.id).font(.caption2).foregroundStyle(.secondary)
                        ProblemCardView(problem: problem, heading: entry.title)
                            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(16)
            .frame(width: 520, alignment: .leading)
            .background(Color.white)
            .environment(\.colorScheme, .light)

            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, "could not draw \(entry.slug)")
            let png = try XCTUnwrap(image.pngData())
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("card-\(entry.slug).png"))
        }
    }
}

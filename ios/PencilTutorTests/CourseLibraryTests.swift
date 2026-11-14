import XCTest
@testable import PencilTutor

final class CourseLibraryTests: XCTestCase {
    private let sample = """
    {"version":1,"courses":[
      {"slug":"bc-math-5","title":"BC Math 5","group":"elementary","grade":5,"count":90,"resource":"course-bc-math-5"},
      {"slug":"bc-math-7","title":"BC Math 7","group":"elementary","grade":7,"count":64,"resource":"course-bc-math-7"},
      {"slug":"bc-math-9","title":"BC Math 9","group":"high_school","grade":9,"count":1,"resource":"course-bc-math-9"},
      {"slug":"calculus-1","title":"Calculus I","group":"college","grade":null,"count":70,"resource":"course-calculus-1"}
    ]}
    """

    func testDecodesAManifest() throws {
        let courses = try CourseLibrary.decodeManifest(Data(sample.utf8))
        XCTAssertEqual(courses.map { $0.slug }, ["bc-math-5", "bc-math-7", "bc-math-9", "calculus-1"])
        XCTAssertEqual(courses[0].group, .elementary)
        XCTAssertEqual(courses[2].group, .highSchool)
        XCTAssertEqual(courses[3].group, .college)
        XCTAssertNil(courses[3].grade)
        XCTAssertEqual(courses[0].resource, "course-bc-math-5")
    }

    func testSubtitlesAndSectionHeaders() throws {
        let courses = try CourseLibrary.decodeManifest(Data(sample.utf8))
        XCTAssertEqual(courses[0].subtitle, "Grade 5 · 90 problems")
        XCTAssertEqual(courses[2].subtitle, "Grade 9 · 1 problem")
        XCTAssertEqual(courses[3].subtitle, "70 problems")
        let sections = CourseLibrary.sections(courses)
        XCTAssertEqual(sections.map { $0.group }, [.elementary, .highSchool, .college])
        XCTAssertEqual(sections.map { $0.header }, ["Elementary · Grades 5-7", "High school · Grade 9", "College"])
    }

    func testAShelfWithNoCourseIsLeftOutAndTheOrderWithinAShelfIsKept() throws {
        let courses = try CourseLibrary.decodeManifest(Data(sample.utf8)).filter { $0.group != .highSchool }.reversed()
        let sections = CourseLibrary.sections(Array(courses))
        XCTAssertEqual(sections.map { $0.group }, [.elementary, .college])
        XCTAssertEqual(sections[0].courses.map { $0.slug }, ["bc-math-7", "bc-math-5"])
    }

    func testBadManifestsAreRejected() {
        let badVersion = #"{"version":2,"courses":[{"slug":"a","title":"A","group":"college","grade":null,"count":1,"resource":"course-a"}]}"#
        let empty = #"{"version":1,"courses":[]}"#
        let repeated = """
        {"version":1,"courses":[
          {"slug":"a","title":"A","group":"college","grade":null,"count":1,"resource":"course-a"},
          {"slug":"a","title":"B","group":"college","grade":null,"count":1,"resource":"course-a"}]}
        """
        let unknownShelf = #"{"version":1,"courses":[{"slug":"a","title":"A","group":"kindergarten","grade":null,"count":1,"resource":"course-a"}]}"#
        for json in [badVersion, empty, repeated, unknownShelf, "not json"] {
            XCTAssertThrowsError(try CourseLibrary.decodeManifest(Data(json.utf8)), json)
        }
    }

    /// The committed manifest, read from the repo (the test runs on the simulator, which shares the host disk): every course
    /// file decodes, the counts match the manifest, and no id appears twice across all courses.
    func testTheRealManifestAndEveryCourseFileDecode() throws {
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PencilTutorTests
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("shared")
        struct Entry: Decodable { let slug: String; let title: String; let group: String; let count: Int; let file: String }
        struct Manifest: Decodable { let courses: [Entry] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: shared.appendingPathComponent("courses/index.json")))
        XCTAssertGreaterThanOrEqual(manifest.courses.count, 9)
        var seen = Set<String>()
        for entry in manifest.courses {
            let problems = try ProblemBank.decode(Data(contentsOf: shared.appendingPathComponent(entry.file)))
            XCTAssertEqual(problems.count, entry.count, "\(entry.slug): count must match the manifest")
            XCTAssertTrue(problems.allSatisfy { !$0.promptPlain.isEmpty && !$0.promptParts.isEmpty }, entry.slug)
            for problem in problems { XCTAssertTrue(seen.insert(problem.id).inserted, "duplicate id \(problem.id)") }
            XCTAssertNotNil(CourseGroup(rawValue: entry.group), "\(entry.slug): unknown group \(entry.group)")
        }
        XCTAssertTrue(seen.contains("u3-04"), "the original twelve stay reachable")
    }

    /// What the build put in this app: the manifest, a file per course, and no answers in any of them.
    func testTheBundledCoursesLoadAndHoldNoAnswers() throws {
        let courses = try CourseLibrary.loadBundledCourses()
        XCTAssertGreaterThanOrEqual(courses.count, 9)
        var total = 0
        for course in courses {
            let url = try XCTUnwrap(Bundle.main.url(forResource: course.resource, withExtension: "json"), "\(course.slug) file is bundled")
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("worked_solution"), course.slug)
            XCTAssertFalse(text.contains("final_answer"), course.slug)
            let problems = try CourseLibrary.loadBundledProblems(for: course)
            XCTAssertEqual(problems.count, course.count, course.slug)
            total += problems.count
        }
        XCTAssertGreaterThan(total, 500)
        let found = try XCTUnwrap(CourseLibrary.find(problemID: "u3-04", in: courses))
        XCTAssertEqual(found.course.slug, "bc-math-9-unit-3")
        XCTAssertNil(CourseLibrary.find(problemID: "zz-99", in: courses))
    }

    // MARK: - Long prompts

    func testAMatrixStaysInOnePiece() {
        let words = PromptLayout.words("The matrix is P = [0.8 0.3; 0.2 0.7] (columns: from city). Find it.")
        XCTAssertTrue(words.contains("[0.8\u{00A0}0.3;\u{00A0}0.2\u{00A0}0.7]"), "\(words)")
        XCTAssertEqual(words.first, "The")
        XCTAssertEqual(words.last, "it.")
    }

    func testAnOverlongBracketIsLeftToWrap() {
        let long = "[" + String(repeating: "word ", count: 12) + "end]"
        XCTAssertGreaterThan(PromptLayout.words(long).count, 5)
    }

    func testFontShrinksWithLength() {
        XCTAssertEqual(PromptLayout.fontSize(forLength: 12), 26)
        XCTAssertEqual(PromptLayout.fontSize(forLength: 100), 23)
        XCTAssertEqual(PromptLayout.fontSize(forLength: 150), 20)
        XCTAssertEqual(PromptLayout.fontSize(forLength: 263), 18)
    }
}

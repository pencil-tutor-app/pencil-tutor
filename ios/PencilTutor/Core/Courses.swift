import Foundation

/// Which shelf a course sits on in the picker. The build decides it (`group` in `shared/courses/index.json`).
enum CourseGroup: String, Codable, CaseIterable, Hashable {
    case elementary
    case highSchool = "high_school"
    case college

    var title: String {
        switch self {
        case .elementary: return "Elementary"
        case .highSchool: return "High school"
        case .college: return "College"
        }
    }
}

/// One course in the picker: a title, a shelf, a grade (nil for college courses) and how many problems it holds.
struct Course: Identifiable, Hashable, Codable {
    let slug: String
    let title: String
    let group: CourseGroup
    let grade: Int?
    let count: Int
    /// Name of the bundled file (without `.json`) that holds this course's problems.
    let resource: String

    var id: String { slug }

    /// "Grade 5 · 90 problems", or "70 problems" for a course with no grade.
    var subtitle: String {
        let size = count == 1 ? "1 problem" : "\(count) problems"
        guard let grade else { return size }
        return "Grade \(grade) · \(size)"
    }
}

/// The courses of one shelf, in display order.
struct CourseSection: Identifiable, Hashable {
    let group: CourseGroup
    let courses: [Course]

    var id: CourseGroup { group }

    /// "Grades 5-7", "Grade 9" or nil when no course on the shelf has a grade. Worked out from the courses, so a new course
    /// widens it without a code change.
    var gradeRange: String? {
        let grades = courses.compactMap { $0.grade }
        guard let low = grades.min(), let high = grades.max() else { return nil }
        return low == high ? "Grade \(low)" : "Grades \(low)-\(high)"
    }

    var header: String {
        guard let gradeRange else { return group.title }
        return "\(group.title) · \(gradeRange)"
    }
}

private struct CourseManifest: Decodable {
    let version: Int
    let courses: [Course]
}

enum CourseLibrary {
    /// The only manifest shape this build reads. A bundle with another version fails loudly instead of showing half a list.
    static let supportedVersion = 1

    static func decodeManifest(_ data: Data) throws -> [Course] {
        let manifest = try JSONDecoder().decode(CourseManifest.self, from: data)
        guard manifest.version == supportedVersion else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "course manifest version \(manifest.version) is not supported")
            )
        }
        guard !manifest.courses.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "course manifest is empty"))
        }
        guard Set(manifest.courses.map { $0.slug }).count == manifest.courses.count else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "course manifest repeats a slug"))
        }
        return manifest.courses
    }

    /// Loads `courses.json`, which the build copies into the app from `shared/courses/index.json`.
    static func loadBundledCourses(bundle: Bundle = .main) throws -> [Course] {
        guard let url = bundle.url(forResource: "courses", withExtension: "json") else {
            throw TutorError.problemBankMissing
        }
        return try decodeManifest(Data(contentsOf: url))
    }

    /// Loads one course's problems from the bundle.
    static func loadBundledProblems(for course: Course, bundle: Bundle = .main) throws -> [Problem] {
        guard let url = bundle.url(forResource: course.resource, withExtension: "json") else {
            throw TutorError.problemBankMissing
        }
        let problems = try ProblemBank.decode(Data(contentsOf: url))
        guard !problems.isEmpty else { throw TutorError.problemBankMissing }
        return problems
    }

    /// Groups the courses by shelf in the order Elementary, High school, College, keeping the manifest's order inside a
    /// shelf. A shelf with no course is left out.
    static func sections(_ courses: [Course]) -> [CourseSection] {
        CourseGroup.allCases.compactMap { group in
            let inGroup = courses.filter { $0.group == group }
            return inGroup.isEmpty ? nil : CourseSection(group: group, courses: inGroup)
        }
    }

    /// Finds the course that holds a problem id and the problem itself (for `--open-problem`).
    static func find(problemID: String, in courses: [Course], bundle: Bundle = .main) -> (course: Course, problem: Problem)? {
        for course in courses {
            if let problems = try? loadBundledProblems(for: course, bundle: bundle),
               let problem = problems.first(where: { $0.id == problemID }) {
                return (course, problem)
            }
        }
        return nil
    }
}

import Foundation

/// The courses the app ships with and, on demand, the problems of each. Reads the bundle once and keeps what it read.
@MainActor
final class CourseCatalog: ObservableObject {
    @Published private(set) var courses: [Course] = []
    /// Plain-words notice for the picker when something is wrong (nil when all is well).
    @Published private(set) var notice: String?

    private let bundle: Bundle
    private var loaded = false
    private var problemsBySlug: [String: [Problem]] = [:]

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    var sections: [CourseSection] { CourseLibrary.sections(courses) }

    func course(slug: String) -> Course? { courses.first { $0.slug == slug } }

    func loadIfNeeded(log: SessionLog) {
        guard !loaded else { return }
        loaded = true
        do {
            courses = try CourseLibrary.loadBundledCourses(bundle: bundle)
            log.record("courses_loaded", ["courses": courses.count, "problems": courses.reduce(0) { $0 + $1.count }])
        } catch {
            let (student, detail) = TutorError.describe(error)
            notice = student
            log.record("error", ["where": "course_manifest", "detail": detail])
        }
    }

    /// The problems of one course. Cached after the first read; a read that fails is logged and thrown.
    func problems(for course: Course, log: SessionLog) throws -> [Problem] {
        if let cached = problemsBySlug[course.slug] { return cached }
        do {
            let problems = try CourseLibrary.loadBundledProblems(for: course, bundle: bundle)
            problemsBySlug[course.slug] = problems
            log.record("course_problems_loaded", ["course": course.slug, "count": problems.count])
            return problems
        } catch {
            let (_, detail) = TutorError.describe(error)
            log.record("error", ["where": "course_problems", "course": course.slug, "detail": detail])
            throw error
        }
    }

    /// For `--open-problem <id>`: the course that holds the problem, and the problem.
    func find(problemID: String) -> (course: Course, problem: Problem)? {
        CourseLibrary.find(problemID: problemID, in: courses, bundle: bundle)
    }
}

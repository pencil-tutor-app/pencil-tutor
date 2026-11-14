import SwiftUI

/// Where a tap in the course lists leads. A path of one is a course's problem list; a path of two is a problem.
enum CourseRoute: Hashable {
    case course(Course)
    case problem(course: Course, problem: Problem)
}

/// The home of the app once there is a code: pick a course, then a problem. Opens straight into the course the student used
/// last, and Back goes to the picker.
struct ProblemListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var account: StudentAccount
    @StateObject private var catalog = CourseCatalog()
    @State private var path: [CourseRoute] = []
    @State private var openedAtLaunch = false
    /// Remembered between launches. `-lastCourseSlug <slug>` on the command line overrides it (UI tests pass an empty one).
    @AppStorage("lastCourseSlug") private var lastCourseSlug = ""

    var body: some View {
        NavigationStack(path: $path) {
            CoursePickerView(catalog: catalog, lastCourseSlug: lastCourseSlug)
                .navigationDestination(for: CourseRoute.self) { route in
                    switch route {
                    case .course(let course):
                        CourseProblemsView(course: course, catalog: catalog)
                    case .problem(let course, let problem):
                        ProblemScreen(problem: problem, env: env, courseTitle: course.title)
                    }
                }
        }
        .onAppear(perform: start)
        .onChange(of: path) { _, newPath in
            // The student chose a course: remember it for next time.
            if case .course(let course)? = newPath.first, course.slug != lastCourseSlug {
                lastCourseSlug = course.slug
                env.log.record("course_chosen", ["course": course.slug])
            }
        }
    }

    /// Loads the courses, then opens `--open-problem <id>` (device smoke test) or, failing that, the course used last time.
    private func start() {
        catalog.loadIfNeeded(log: env.log)
        guard !openedAtLaunch else { return }
        openedAtLaunch = true
        if let id = LaunchOptions.openProblemID {
            if let found = catalog.find(problemID: id) {
                env.log.record("launch_open_problem", ["problem_id": id, "course": found.course.slug])
                path = [.course(found.course), .problem(course: found.course, problem: found.problem)]
            } else {
                env.log.record("error", ["where": "launch_open_problem", "detail": "no problem with id \(id)"])
            }
        } else if !lastCourseSlug.isEmpty {
            if let course = catalog.course(slug: lastCourseSlug) {
                env.log.record("course_restored", ["course": course.slug])
                path = [.course(course)]
            } else {
                env.log.record("course_restore_skipped", ["reason": "not_in_manifest", "course": lastCourseSlug])
            }
        }
    }
}

/// The first screen: every course on its shelf (Elementary, High school, College).
struct CoursePickerView: View {
    @ObservedObject var catalog: CourseCatalog
    let lastCourseSlug: String
    @EnvironmentObject private var account: StudentAccount

    var body: some View {
        List {
            if let notice = catalog.notice {
                Text(notice)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("problemListNotice")
            }
            if let block = account.block {
                Text(block.message)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("problemListBlocked")
            }
            ForEach(catalog.sections) { section in
                Section {
                    ForEach(section.courses) { course in
                        NavigationLink(value: CourseRoute.course(course)) {
                            CourseRow(course: course, isLast: course.slug == lastCourseSlug)
                        }
                        .accessibilityIdentifier("course-\(course.slug)")
                    }
                } header: {
                    Text(section.header)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("courseSection-\(section.group.rawValue)")
                }
            }
        }
        .navigationTitle("Pick a course")
        .appToolbar(showsAllowance: true)
    }
}

private struct CourseRow: View {
    let course: Course
    let isLast: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(course.title)
                    .font(.system(size: 22, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                Text(course.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isLast {
                Text("Last used")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .fixedSize()
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// One course's problems, one row each. A long prompt wraps over as many lines as it needs; nothing is cut off.
struct CourseProblemsView: View {
    let course: Course
    @ObservedObject var catalog: CourseCatalog
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var account: StudentAccount
    @State private var problems: [Problem] = []
    @State private var notice: String?

    var body: some View {
        List {
            if let notice {
                Text(notice)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("problemListNotice")
            }
            if let block = account.block {
                Text(block.message)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("problemListBlocked")
            }
            ForEach(problems) { problem in
                NavigationLink(value: CourseRoute.problem(course: course, problem: problem)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(problem.promptPlain)
                            .font(.system(size: problem.promptPlain.count > 100 ? 19 : 22, design: .serif))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(problem.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .padding(.vertical, 6)
                }
                .accessibilityIdentifier("problem-\(problem.id)")
            }
        }
        .navigationTitle(course.title)
        .navigationBarTitleDisplayMode(.inline)
        .appToolbar()
        .onAppear(perform: load)
    }

    private func load() {
        guard problems.isEmpty else { return }
        do {
            problems = try catalog.problems(for: course, log: env.log)
            env.log.record("course_opened", ["course": course.slug, "count": problems.count])
        } catch {
            notice = TutorError.describe(error).student
        }
    }
}

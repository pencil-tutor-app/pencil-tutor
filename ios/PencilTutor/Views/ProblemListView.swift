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
                        CourseProblemsView(course: course, catalog: catalog) { problem in
                            path.append(.problem(course: course, problem: problem))
                        }
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
    /// Opens the problem screen for a problem the student typed (the list owns the navigation path).
    var onOwnProblem: (Problem) -> Void = { _ in }
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var account: StudentAccount
    @State private var problems: [Problem] = []
    @State private var notice: String?
    @State private var showOwnProblemSheet = false
    /// Set by Start inside the sheet; the page opens once the sheet has gone, so one push is not fighting a sheet that is closing.
    @State private var pendingOwnProblem: Problem?

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
            Button {
                showOwnProblemSheet = true
            } label: {
                OwnProblemRow()
            }
            .accessibilityIdentifier("ownProblemRow")
            ForEach(problems) { problem in
                NavigationLink(value: CourseRoute.problem(course: course, problem: problem)) {
                    VStack(alignment: .leading, spacing: 4) {
                        MathLine.text(problem.promptPlain, size: problem.promptPlain.count > 100 ? 19 : 22)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(problem.promptPlain)
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
        .sheet(isPresented: $showOwnProblemSheet, onDismiss: openPendingOwnProblem) {
            OwnProblemSheet(courseTitle: course.title) { statement in
                pendingOwnProblem = Problem.own(courseSlug: course.slug, text: statement)
                env.log.record("own_problem_started", ["course": course.slug, "chars": statement.count])
            }
        }
    }

    private func openPendingOwnProblem() {
        guard let problem = pendingOwnProblem else {
            env.log.record("own_problem_cancelled", ["course": course.slug])
            return
        }
        pendingOwnProblem = nil
        onOwnProblem(problem)
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

/// The first row of a course's list: type your own problem.
private struct OwnProblemRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("My own problem")
                    .font(.system(size: 22, design: .serif))
                Text("Type a problem from your homework and I'll check your work as you write.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One text field for the statement of the student's own problem. Start stays off while nothing is typed; the field stops at the
/// 500 characters the server accepts, and says how many are left.
struct OwnProblemSheet: View {
    let courseTitle: String
    /// Called with the cleaned statement when Start is tapped, just before the sheet closes.
    let onStart: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var statement: String? { OwnProblemText.cleaned(typed) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Type the problem", text: $typed, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($fieldFocused)
                        .font(.system(size: 22))
                        .accessibilityIdentifier("ownProblemField")
                        .onChange(of: typed) { _, now in
                            let capped = OwnProblemText.capped(now)
                            if capped != now { typed = capped }
                        }
                } header: {
                    Text(courseTitle)
                } footer: {
                    Text("\(typed.utf16.count) of \(OwnProblemText.maxLength) characters. There is no answer key for a problem you type, so the tutor works it out as you go and may miss things.")
                        .accessibilityIdentifier("ownProblemCount")
                }
            }
            .navigationTitle("My own problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("ownProblemCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        guard let statement else { return }
                        onStart(statement)
                        dismiss()
                    }
                    .disabled(statement == nil)
                    .accessibilityIdentifier("ownProblemStartButton")
                }
            }
        }
        .onAppear { fieldFocused = true }
    }
}

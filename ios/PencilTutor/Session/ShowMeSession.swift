import Foundation

/// "Show me how" for one problem page: asks the server for the worked solution of the problem on the page, keeps the state the side
/// panel draws, and makes "Try one like it" (the existing practice action) when the student wants another problem.
///
/// What it promises (docs/show-me-plan.md, Revision 3):
///  - The steps are shown only when the server returned them: a stored solution (bank, practice) or one it checked (own problem).
///    A solution the check did not accept is `notChecked`: the panel says so and offers Try again. There is no unchecked fallback.
///  - A solution already fetched for this page is shown again without asking again.
///  - It never speaks and never touches the live voice: it reports the outcome, and `TutorSession` decides what the voice does.
///  - Logs hold labels, counts and ids. Never the statement, the steps or the answer.
@MainActor
final class ShowMeSession: ObservableObject {
    enum Phase: Equatable {
        case closed
        case loading
        case shown(TeachSolution)
        /// The server could not check what it wrote for a typed problem.
        case notChecked
        case failed(String)
    }

    /// "Try one like it" under the solution.
    enum Next: Equatable {
        case idle
        case preparing
        case notChecked
        case failed(String)
    }

    /// Where the request came from: the button, or the live voice (the page reader answered `show_me`).
    enum Source: String {
        case button
        case voice
    }

    enum Outcome: Equatable {
        case shown(TeachSolution)
        case notChecked
        case failed(String)
        /// The screen was left while the request was in flight.
        case stopped
    }

    static let likeItConcept = "problems like this one"

    @Published private(set) var phase: Phase = .closed
    @Published private(set) var next: Next = .idle

    /// The page becomes this practice problem. Set by the screen; called once, when the new problem is ready.
    var onPractice: ((Problem) -> Void)?

    private let problem: Problem
    private let courseSlug: String?
    private let sessionID: String
    private let env: AppEnvironment
    private let now: () -> Date
    private var solution: TeachSolution?
    private var inFlight: Task<Outcome, Never>?
    private var practiceTask: Task<Void, Never>?
    private var stopped = false

    init(problem: Problem, courseSlug: String?, sessionID: String, env: AppEnvironment, now: @escaping () -> Date = { Date() }) {
        self.problem = problem
        self.courseSlug = courseSlug
        self.sessionID = sessionID
        self.env = env
        self.now = now
    }

    var isOpen: Bool { phase != .closed }

    /// Opens the panel and returns once the steps are on it (or why they are not). A second call while one is loading waits for the
    /// same answer; a solution already fetched is shown again at once.
    @discardableResult
    func open(source: Source) async -> Outcome {
        if let solution {
            phase = .shown(solution)
            env.log.record("show_me_reopened", ["source": source.rawValue, "problem_id": problem.id])
            return .shown(solution)
        }
        if let running = inFlight {
            phase = .loading
            env.log.record("show_me_joined", ["source": source.rawValue, "problem_id": problem.id])
            return await running.value
        }
        let task = Task { await self.fetch(source: source) }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    func close() {
        guard phase != .closed else { return }
        env.log.record("show_me_closed", ["was": Self.label(phase), "problem_id": problem.id])
        phase = .closed
    }

    func stop() {
        stopped = true
        inFlight?.cancel()
        practiceTask?.cancel()
    }

    private func fetch(source: Source) async -> Outcome {
        if let block = env.account.block {
            phase = .failed(block.message)
            env.log.record("show_me_blocked", ["why": block.logLabel, "source": source.rawValue])
            return .failed(block.message)
        }
        guard let course = courseSlug ?? problem.ownCourseSlug else {
            let message = "I can't show this one right now."
            phase = .failed(message)
            env.log.record("show_me_failed", ["detail": "no_course_for_problem", "source": source.rawValue, "problem_id": problem.id])
            return .failed(message)
        }
        phase = .loading
        let begun = now()
        env.log.record("show_me_requested", ["source": source.rawValue, "problem_id": problem.id, "kind": problem.kindLabel])
        let request = TeachSolveRequest(
            sessionId: sessionID, course: course, problemId: problem.id,
            problemText: problem.problemTextForServer, problemRef: problem.problemRef
        )
        do {
            let response = try await env.client.teachSolve(request)
            guard !stopped, !Task.isCancelled else { return .stopped }
            let latency = milliseconds(since: begun)
            guard let found = response.solution, !found.steps.isEmpty,
                  !found.finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                phase = .notChecked
                env.log.record("show_me_not_checked", [
                    "source": source.rawValue, "reason": response.reason ?? "no_solution", "latency_ms": latency,
                    "model": response.model ?? "?", "request_id": response.requestId ?? "?", "problem_id": problem.id
                ])
                return .notChecked
            }
            solution = found
            phase = .shown(found)
            env.log.record("show_me_shown", [
                "source": source.rawValue, "steps": found.steps.count, "latency_ms": latency, "stored": response.model == "stored",
                "model": response.model ?? "?", "request_id": response.requestId ?? "?", "problem_id": problem.id
            ])
            return .shown(found)
        } catch {
            guard !stopped, !Task.isCancelled else { return .stopped }
            let (student, detail) = TutorError.describe(error)
            phase = .failed(student)
            env.log.record("show_me_failed", [
                "source": source.rawValue, "detail": detail, "latency_ms": milliseconds(since: begun), "problem_id": problem.id
            ])
            return .failed(student)
        }
    }

    // MARK: - Try one like it

    /// Asks for a checked problem like the one just shown (the `practice` action, with no example: what was shown is already stored
    /// or checked) and hands it to the screen, which swaps the page to it.
    func tryOneLikeIt() {
        guard case .shown(let shown) = phase, next != .preparing else { return }
        if let block = env.account.block {
            next = .failed(block.message)
            env.log.record("like_it_blocked", ["why": block.logLabel])
            return
        }
        guard let course = courseSlug ?? problem.ownCourseSlug else {
            next = .failed("I can't make one right now.")
            env.log.record("like_it_failed", ["detail": "no_course_for_problem", "problem_id": problem.id])
            return
        }
        next = .preparing
        let begun = now()
        env.log.record("like_it_requested", ["problem_id": problem.id, "steps": shown.steps.count])
        let request = TeachPracticeRequest(
            sessionId: sessionID, course: course, concept: Self.likeItConcept,
            lessonText: Self.lessonText(statement: problem.promptPlain, solution: shown), example: nil
        )
        practiceTask?.cancel()
        practiceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.env.client.teachPractice(request)
                guard !self.stopped, !Task.isCancelled else { return }
                let latency = self.milliseconds(since: begun)
                guard let made = response.problem, let ref = response.problemRef, !ref.isEmpty,
                      !made.promptPlain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.next = .notChecked
                    self.env.log.record("like_it_not_checked", ["reason": response.reason ?? "no_problem", "latency_ms": latency])
                    return
                }
                self.next = .idle
                self.env.log.record("like_it_ready", [
                    "latency_ms": latency, "prompt_chars": made.promptPlain.count,
                    "model": response.model ?? "?", "request_id": response.requestId ?? "?"
                ])
                self.onPractice?(Problem.practice(courseSlug: course, promptPlain: made.promptPlain, ref: ref))
            } catch {
                guard !self.stopped, !Task.isCancelled else { return }
                let (student, detail) = TutorError.describe(error)
                self.next = .failed(student)
                self.env.log.record("like_it_failed", ["detail": detail, "latency_ms": self.milliseconds(since: begun)])
            }
        }
    }

    /// What the practice generator is given in place of a lesson: the statement it must differ from, then the shown steps.
    static func lessonText(statement: String, solution: TeachSolution) -> String {
        var lines = [
            "The student was just shown how to solve the problem below. Write a different problem of the same kind, with different numbers and a different final answer.",
            statement
        ]
        for (index, step) in solution.steps.enumerated() { lines.append("\(index + 1). \(step)") }
        lines.append("Answer: \(solution.finalAnswer)")
        return LessonText.fit(lines)
    }

    private static func label(_ phase: Phase) -> String {
        switch phase {
        case .closed: return "closed"
        case .loading: return "loading"
        case .shown: return "shown"
        case .notChecked: return "not_checked"
        case .failed: return "failed"
        }
    }

    private func milliseconds(since date: Date) -> Int { Int(now().timeIntervalSince(date) * 1000) }
}

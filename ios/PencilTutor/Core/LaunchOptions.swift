import Foundation

/// Launch arguments. Used by UI tests only; a normal launch has none of them.
enum LaunchOptions {
    /// `--scripted-client`: use the in-process scripted tutor and the two fixed test problems.
    static var scriptedClient: Bool { ProcessInfo.processInfo.arguments.contains("--scripted-client") }

    /// `--any-input`: let a finger draw (UI tests cannot use a Pencil). Normal use is Pencil only.
    static var anyInput: Bool { ProcessInfo.processInfo.arguments.contains("--any-input") }

    /// `--open-problem <id>`: open that problem as soon as the list appears. For the device smoke test
    /// (`xcrun devicectl ... process launch ... --open-problem u3-01`), where nobody is tapping.
    static var openProblemID: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--open-problem"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// The small status line UI tests read. Only visible in scripted runs.
    static var showTestStatus: Bool { scriptedClient }
}

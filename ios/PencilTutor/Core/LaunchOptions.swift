import Foundation

/// Launch arguments. Used by UI tests only; a normal launch has none of them.
enum LaunchOptions {
    /// `--scripted-client`: use the in-process scripted tutor and the two fixed test problems.
    static var scriptedClient: Bool { ProcessInfo.processInfo.arguments.contains("--scripted-client") }

    /// `--any-input`: let a finger draw (UI tests cannot use a Pencil). Normal use is Pencil only.
    static var anyInput: Bool { ProcessInfo.processInfo.arguments.contains("--any-input") }

    /// The small status line UI tests read. Only visible in scripted runs.
    static var showTestStatus: Bool { scriptedClient }
}

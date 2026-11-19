import Foundation

/// Launch arguments. Used by UI tests only; a normal launch has none of them.
enum LaunchOptions {
    /// `--scripted-client`: use the in-process scripted tutor and the two fixed test problems.
    static var scriptedClient: Bool { ProcessInfo.processInfo.arguments.contains("--scripted-client") }

    /// `--scripted-needs-code`: with `--scripted-client`, start on the code screen instead of signed in, and let "Start free" work
    /// against the scripted server (it hands out a fixed code). Without it a scripted run never shows the code screen.
    static var scriptedNeedsCode: Bool { scriptedClient && ProcessInfo.processInfo.arguments.contains("--scripted-needs-code") }

    /// `--memory-on`: the scripted tutor offers the opt-in memory (otherwise it says nothing about it, like an older server).
    static var memoryOn: Bool { ProcessInfo.processInfo.arguments.contains("--memory-on") }

    /// `--memory-agreed`: Debug builds only. The scripted tutor starts with an agreement already on record (for screenshots of
    /// the record screen). In Release builds this is always false.
    static var memoryAgreed: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--memory-agreed")
        #else
        return false
        #endif
    }

    /// `--show-memory-record`: Debug builds only. In a scripted run, open "What the tutor remembers" by itself once the list
    /// appears (for screenshots). In Release builds this is always false.
    static var showMemoryRecord: Bool {
        #if DEBUG
        return scriptedClient && ProcessInfo.processInfo.arguments.contains("--show-memory-record")
        #else
        return false
        #endif
    }

    /// `--offer-memory`: in a scripted run, let the consent screen appear by itself once (it never does otherwise).
    static var offerMemory: Bool { ProcessInfo.processInfo.arguments.contains("--offer-memory") }

    /// `--any-input`: let a finger draw (UI tests cannot use a Pencil). Normal use is Pencil only.
    static var anyInput: Bool { ProcessInfo.processInfo.arguments.contains("--any-input") }

    /// `--open-problem <id>`: open that problem as soon as the list appears. For the device smoke test
    /// (`xcrun devicectl ... process launch ... --open-problem u3-01`), where nobody is tapping.
    static var openProblemID: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--open-problem"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `--student-code XXXXXXXX`: Debug builds only. Keeps that code in the Keychain so a device smoke test needs no typing.
    /// In Release builds this is always nil, so a code can never be supplied this way outside a test build.
    static var seededStudentCode: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--student-code"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }

    /// `--replay-ink <file>`: Debug builds only. Writes the ink script's strokes onto the page at their own pace (`InkReplay`),
    /// so handwriting can be tested end to end with nobody holding a Pencil. The file is an absolute path, a file in the app's
    /// Documents folder, or a JSON file in the bundle. In Release builds this is always nil, like `seededStudentCode`.
    static var replayInkFile: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--replay-ink"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }

    /// `--replay-settle <seconds>`: Debug builds only. How long a replay waits after the last stroke for the tutor to answer
    /// before it takes its screenshot (default 20).
    static var replaySettleSeconds: Double {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--replay-settle"), arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]) else { return 20 }
        return seconds
        #else
        return 20
        #endif
    }

    /// `--silent`: Debug builds only. The whole voice path still runs (the speech request, the speech log lines with sizes and
    /// latency) but every sound is played at volume 0, and live voice is not opened. For replay runs at night. In Release builds
    /// this is always false, so a student can never end up with a muted tutor by a launch argument.
    static var silent: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--silent")
        #else
        return false
        #endif
    }

    /// The small status line UI tests read. Only visible in scripted runs.
    static var showTestStatus: Bool { scriptedClient }
}

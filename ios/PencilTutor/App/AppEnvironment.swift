import Foundation

/// Everything the screens share: problems, the tutor client, the student's account, settings, speech and the session log.
@MainActor
final class AppEnvironment: ObservableObject {
    let log: SessionLog
    let settings: TutorSettings
    let speech: SpeechOutput
    /// Every reply passes through the metering wrapper, so the account always knows the latest allowance.
    let client: TutorClient
    /// The student's code, plan and allowance.
    let account: StudentAccount
    /// Makes the live voice connection. Nil when there is no server to relay it (scripted UI tests, unconfigured builds).
    /// Even with a server, live voice only opens when the student's plan says `live: true`.
    let makeLiveTransport: (@MainActor () -> LiveTransport)?
    /// Why live voice is off for this build, as a log label (nil when the build can do it).
    let liveOffReason: String?
    let problems: [Problem]
    /// Plain-words notice for the problem list when something is wrong (nil when all is well).
    let notice: String?

    init() {
        let log = SessionLog()
        self.log = log
        self.settings = TutorSettings(useStartingDefaultsOnly: LaunchOptions.scriptedClient)

        let holder = StudentCodeHolder()
        let account: StudentAccount
        let speech: SpeechOutput
        var launchesWithCode = false

        if LaunchOptions.scriptedClient {
            // UI tests: no network and no code screen; speech uses the device voice only.
            let scripted = ScriptedTutorClient()
            account = StudentAccount(store: InMemoryStudentCodeStore(), holder: holder, log: log, fetchMe: { try await scripted.me() })
            account.startScripted(allowance: ScriptedTutorClient.allowance, plan: PlanInfo(live: false, capMinutes: 480))
            self.client = MeteredTutorClient(inner: scripted, account: account)
            self.makeLiveTransport = nil
            self.liveOffReason = "scripted_client"
            speech = SpeechOutput(log: log, remote: nil, deviceOnlyReason: "scripted_client")
            log.record("app_launch", ["mode": "scripted"])
        } else {
            let config = AppConfig.load()
            let store = KeychainStudentCodeStore()
            #if DEBUG
            Self.seedCodeFromLaunchArgument(into: store, log: log)
            #endif
            if let url = config.serverURL {
                let http = HTTPTutorClient(baseURL: url, codeHolder: holder, log: log)
                account = StudentAccount(store: store, holder: holder, log: log, fetchMe: { try await http.me() })
                self.client = MeteredTutorClient(inner: http, account: account)
                self.makeLiveTransport = { LiveWebRTCTransport() }
                self.liveOffReason = nil
                speech = SpeechOutput(log: log, remote: SpeechOutput.Remote(baseURL: url, codeHolder: holder))
                launchesWithCode = account.phase == .ready
                log.record("app_launch", [
                    "mode": "live", "server_host": url.host ?? "?",
                    "code_hash": holder.current.map(StudentCode.shortHash) ?? "none"
                ])
            } else {
                // No server address in this build: nothing to sign in to, but the student can still write.
                let reason = config.missingReason ?? "unknown"
                let unconfigured = UnconfiguredTutorClient(reason: reason)
                account = StudentAccount(store: InMemoryStudentCodeStore(), holder: holder, log: log, fetchMe: { try await unconfigured.me() })
                account.startWithoutServer()
                self.client = unconfigured
                self.makeLiveTransport = nil
                self.liveOffReason = "server_not_configured"
                speech = SpeechOutput(log: log, remote: nil, deviceOnlyReason: "server_not_configured")
                log.record("app_launch", ["mode": "unconfigured", "reason": reason])
            }
        }
        self.account = account
        self.speech = speech

        // The allowance lines ("you have about 40 minutes left") are said by the tutor's voice; a refusal that comes back
        // from the speech request goes to the account like any other.
        account.announce = { [weak speech] notice in speech?.speakNotice(notice) }
        speech.onServerError = { [weak account] error in account?.handle(serverError: error) }

        // Scripted runs use the same real, bundled problem bank; the UI tests open u3-04 (planted) and u3-01 (clean).
        var loadedProblems: [Problem] = []
        var notice: String?
        do {
            loadedProblems = try ProblemBank.loadBundled()
            log.record("problems_loaded", ["count": loadedProblems.count])
        } catch {
            let (student, detail) = TutorError.describe(error)
            notice = student
            log.record("error", ["where": "problem_bank", "detail": detail])
        }
        self.problems = loadedProblems
        self.notice = notice

        // A stored code is checked right away: it learns the plan and wakes the database before the first problem opens.
        if launchesWithCode {
            Task { @MainActor in await account.refresh(reason: "launch") }
        }
    }

    #if DEBUG
    /// `--student-code XXXXXXXX` (Debug builds only): keeps that code in the Keychain so a device smoke test needs no typing.
    private static func seedCodeFromLaunchArgument(into store: StudentCodeStoring, log: SessionLog) {
        guard let typed = LaunchOptions.seededStudentCode else { return }
        let code = StudentCode.normalize(typed)
        guard StudentCode.isValid(code) else {
            log.record("student_code_seed_refused", ["reason": StudentCode.problem(with: code) ?? "invalid"])
            return
        }
        do {
            try store.save(code)
            log.record("student_code_seeded", ["code_hash": StudentCode.shortHash(code), "from": "launch_argument"])
        } catch {
            log.record("student_code_seed_failed", ["code_hash": StudentCode.shortHash(code), "detail": String(describing: error)])
        }
    }
    #endif
}

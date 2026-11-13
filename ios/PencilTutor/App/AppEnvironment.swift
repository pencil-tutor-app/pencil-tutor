import Foundation

/// Everything the screens share: problems, the tutor client, settings, speech and the session log.
final class AppEnvironment: ObservableObject {
    let log: SessionLog
    let settings: TutorSettings
    let speech: SpeechOutput
    let client: TutorClient
    let problems: [Problem]
    /// Plain-words notice for the problem list when something is wrong (nil when all is well).
    let notice: String?

    init() {
        let log = SessionLog()
        self.log = log
        self.settings = TutorSettings(useStartingDefaultsOnly: LaunchOptions.scriptedClient)

        var loadedProblems: [Problem] = []
        var notice: String?
        if LaunchOptions.scriptedClient {
            // UI tests: no network, so speech uses the device voice only.
            self.client = ScriptedTutorClient()
            self.speech = SpeechOutput(log: log, remote: nil, deviceOnlyReason: "scripted_client")
            log.record("app_launch", ["mode": "scripted"])
        } else {
            let config = AppConfig.load()
            if let url = config.serverURL, let token = config.accessToken {
                self.client = HTTPTutorClient(baseURL: url, token: token, log: log)
                self.speech = SpeechOutput(log: log, remote: SpeechOutput.Remote(baseURL: url, token: token))
                log.record("app_launch", ["mode": "live", "server_host": url.host ?? "?"])
            } else {
                let reason = config.missingReason ?? "unknown"
                self.client = UnconfiguredTutorClient(reason: reason)
                self.speech = SpeechOutput(log: log, remote: nil, deviceOnlyReason: "server_not_configured")
                log.record("app_launch", ["mode": "unconfigured", "reason": reason])
            }
        }
        // Scripted runs use the same real, bundled problem bank; the UI tests open u3-04 (planted) and u3-01 (clean).
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
    }
}

import AVFoundation
import Foundation

/// Speaks hints, answers and allowance notices in the tutor's voice.
///
/// Normal path: `POST /api/speak` streams raw PCM (signed 16-bit little-endian, 24 kHz, mono). The server speaks it with
/// ElevenLabs and falls back to OpenAI on its own; either way the app gets the same format and plays it as it arrives
/// (`StreamingSpeechPlayer`), so the first sound comes before the sentence has finished generating. The on-device voice is
/// the last fallback: the server fails, sends no audio within 4 seconds, the text is over 600 characters, or the app has
/// no server (scripted UI tests, unconfigured builds). It prefers the best installed English voice.
///
/// The same `speak` / `stop` API as before. Everything here runs on the main actor.
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    struct Remote {
        let baseURL: URL
        /// The student's code, read on every request.
        let codeHolder: StudentCodeHolder
    }

    /// No first audio byte within this long and the device voice speaks instead (also the stall limit mid-stream).
    static let firstAudioDeadline: TimeInterval = 4
    /// The server rejects longer text with 422, so longer text goes straight to the device voice.
    static let serverMaxChars = 600
    /// Bytes gathered before they are handed to the player (about 50 ms of audio).
    private static let flushBytes = PCMFormat.bytes(forMilliseconds: 50)

    /// What is being spoken right now, for the log. Labels, sizes and times only, never the text.
    private struct Playback {
        var purpose: String
        var chars: Int
        var source: String   // "server" or "device"
        var bytes: Int
        var requestMs: Int
        var firstAudioMs: Int?
        var provider: String?
        var fallbackHeader: String?
        var startedAt: Date
    }

    /// One thing to say. `serverText` is nil for the allowance notices, which the server composes itself.
    private struct Utterance {
        let purpose: String
        let serverText: String?
        let fallbackText: String
        var chars: Int { fallbackText.count }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let log: SessionLog
    private let remote: Remote?
    /// Why the server path is off, when it is (logged with every device-voice line).
    private let deviceOnlyReason: String
    private let session: URLSession

    private var player: StreamingSpeechPlayer?
    private var fetchTask: Task<Void, Never>?
    /// Bumped by every `speak` and `stop`; a result that belongs to an older number is dropped.
    private var generation = 0
    private var active: (purpose: String, chars: Int)?
    private var playback: Playback?
    private var deviceVoice: AVSpeechSynthesisVoice?
    private var deviceVoiceChosen = false
    /// Characters sent to the server for speech during this app run (ElevenLabs bills per character). Counts only.
    private(set) var charsSentThisRun = 0

    /// A refusal about the code or the hours came back from /api/speak. Wired to `StudentAccount.handle(serverError:)`.
    @MainActor var onServerError: ((TutorError) -> Void)?

    /// True while the student is recording or about to. Nothing plays then, and anything playing is cut off, so the tutor
    /// never talks over the student's question.
    @MainActor var microphoneBusy = false {
        didSet {
            guard microphoneBusy, !oldValue else { return }
            stop(reason: "microphone_busy")
        }
    }

    /// `remote` nil means device voice only; `deviceOnlyReason` then says why (a label for the log).
    init(log: SessionLog, remote: Remote? = nil, deviceOnlyReason: String = "no_server") {
        self.log = log
        self.remote = remote
        self.deviceOnlyReason = deviceOnlyReason
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        // "Request" timeout is the quiet time between bytes: the first byte must come within 4 s, and a stall mid-stream
        // is also cut at 4 s. The resource timeout is the longest a single utterance may take.
        configuration.timeoutIntervalForRequest = Self.firstAudioDeadline
        configuration.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: configuration)
        super.init()
        synthesizer.delegate = self
        if LaunchOptions.mutesSound {
            log.record("voice_muted_for_test", ["why": "--silent launch argument", "paths": "server_audio,device_voice,live_skipped"])
        }
    }

    // MARK: - Public API

    @MainActor
    func speak(_ text: String, purpose: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.record("speech_skipped", ["purpose": purpose, "reason": "empty text"])
            return
        }
        begin(Utterance(purpose: purpose, serverText: trimmed, fallbackText: trimmed))
    }

    /// An allowance line. The server composes and speaks the sentence; the device voice says `notice.fallbackText` if it can't.
    @MainActor
    func speakNotice(_ notice: SpokenNotice) {
        begin(Utterance(purpose: notice.purpose, serverText: nil, fallbackText: notice.fallbackText))
    }

    @MainActor
    func stop() {
        stop(reason: "stopped by app")
    }

    /// Stops what is being said (or fetched, or queued behind the request) only if it has this purpose. A hint the student
    /// dismissed must not go on talking, but an answer or an allowance notice that happens to be playing must. True if it stopped.
    @MainActor
    @discardableResult
    func stopIfSpeaking(purpose: String, reason: String) -> Bool {
        guard active?.purpose == purpose else { return false }
        cancelActive(reason: reason)
        return true
    }

    /// The purpose of what is being said right now, nil when quiet. For the log and tests.
    @MainActor
    var speakingPurpose: String? { active?.purpose }

    // MARK: - Starting and stopping

    @MainActor
    private func begin(_ utterance: Utterance) {
        guard !microphoneBusy else {
            log.record("speech_skipped", ["purpose": utterance.purpose, "chars": utterance.chars, "reason": "microphone_busy"])
            return
        }
        cancelActive(reason: "replaced_by_new_speech")
        generation += 1
        let mine = generation
        active = (utterance.purpose, utterance.chars)

        guard let remote else {
            speakOnDevice(utterance, requestMs: 0, fallbackReason: nil, deviceOnly: deviceOnlyReason)
            return
        }
        if utterance.serverText != nil, utterance.chars > Self.serverMaxChars {
            fallBack(utterance, reason: "text_over_\(Self.serverMaxChars)_chars", requestMs: 0)
            return
        }
        guard let code = remote.codeHolder.current else {
            fallBack(utterance, reason: "no_student_code", requestMs: 0)
            return
        }
        charsSentThisRun += utterance.chars
        fetchTask = Task { @MainActor [weak self] in
            await self?.stream(utterance, remote: remote, code: code, mine: mine)
        }
    }

    @MainActor
    private func stop(reason: String) {
        cancelActive(reason: reason)
    }

    /// Cancels the request, the player and the synthesizer. Logs once if something was in progress.
    @MainActor
    private func cancelActive(reason: String) {
        let wasActive = active
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        playback = nil
        active = nil
        if let wasActive {
            generation += 1
            log.record("speech_stopped", ["purpose": wasActive.purpose, "chars": wasActive.chars, "reason": reason])
        }
    }

    // MARK: - Server audio

    private enum Failure: Error {
        case timedOutBeforeAudio
        case stalled
        case offline
        case http(status: Int, name: String?)
        case wrongFormat(String)
        case emptyAudio
        case engine(String)
    }

    private static func reasonLabel(for failure: Failure) -> String {
        switch failure {
        case .timedOutBeforeAudio: return "no_first_audio_within_\(Int(firstAudioDeadline))s"
        case .stalled: return "stream_stalled_over_\(Int(firstAudioDeadline))s"
        case .offline: return "offline"
        case .http(let status, let name): return name.map { "http_\(status):\($0)" } ?? "http_\(status)"
        case .wrongFormat(let seen): return "unexpected_audio_format:\(seen)"
        case .emptyAudio: return "empty_audio"
        case .engine(let label): return "audio_engine:\(label)"
        }
    }

    @MainActor
    private func stream(_ utterance: Utterance, remote: Remote, code: String, mine: Int) async {
        let started = Date()
        func elapsedMs() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        var request = URLRequest(url: remote.baseURL.appendingPathComponent("api/speak"), timeoutInterval: Self.firstAudioDeadline)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONEncoder().encode(SpeakRequest(sessionId: log.sessionID, text: utterance.serverText, purpose: utterance.purpose))
        } catch {
            fallBack(utterance, reason: "request_not_encoded", requestMs: 0)
            return
        }

        activateAudioSession(purpose: utterance.purpose)
        guard let newPlayer = StreamingSpeechPlayer() else {
            fallBack(utterance, reason: Self.reasonLabel(for: .engine("player_not_created")), requestMs: 0)
            return
        }
        var chunker = PCMChunker()
        var audioStarted = false
        newPlayer.onPlaybackStarted = { [weak self] in
            guard let self, mine == self.generation else { return }
            audioStarted = true
            self.playback?.startedAt = Date()
            self.log.record("speech_started", [
                "purpose": utterance.purpose, "chars": utterance.chars, "source": "server",
                "latency_ms": elapsedMs(), "first_audio_ms": self.playback?.firstAudioMs ?? -1,
                "provider": self.playback?.provider ?? "?", "chars_sent_this_run": self.charsSentThisRun
            ])
        }
        newPlayer.onFinished = { [weak self] in
            guard let self, mine == self.generation else { return }
            self.finishedSpeaking(ok: true, reasonIfNot: "")
        }
        newPlayer.onEngineProblem = { [weak self] label in
            guard let self, mine == self.generation else { return }
            self.log.record("speech_engine_problem", ["purpose": utterance.purpose, "label": label])
            let fatal = ["engine_start_failed", "engine_restart_failed", "buffer_not_created"].contains(label)
            guard fatal else { return }
            if audioStarted {
                self.finishedSpeaking(ok: false, reasonIfNot: label)
            } else {
                self.fetchTask?.cancel()
                self.player = nil
                self.fallBack(utterance, reason: Self.reasonLabel(for: .engine(label)), requestMs: elapsedMs())
            }
        }
        player = newPlayer
        playback = Playback(purpose: utterance.purpose, chars: utterance.chars, source: "server", bytes: 0,
                            requestMs: 0, firstAudioMs: nil, provider: nil, fallbackHeader: nil, startedAt: started)

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard mine == generation, !Task.isCancelled else { return }
            try await Self.checkHeaders(response, bytes: bytes) { [weak self] header in
                self?.playback?.provider = header.provider
                self?.playback?.fallbackHeader = header.fallbackReason
            } onServerError: { [weak self] error in
                self?.onServerError?(error)
            }

            var totalBytes = 0
            try await Self.pump(bytes, flushBytes: Self.flushBytes) { [weak self] chunk in
                guard let self, mine == self.generation, !Task.isCancelled else { return false }
                if self.playback?.firstAudioMs == nil {
                    let ms = elapsedMs()
                    self.playback?.firstAudioMs = ms
                    self.log.record("speech_first_audio", [
                        "purpose": utterance.purpose, "first_audio_ms": ms,
                        "provider": self.playback?.provider ?? "?", "fallback": self.playback?.fallbackHeader ?? "none"
                    ])
                }
                totalBytes += chunk.count
                self.playback?.bytes = totalBytes
                let whole = chunker.push(chunk)
                if !whole.isEmpty { newPlayer.append(whole) }
                return true
            }
            guard mine == generation, !Task.isCancelled else { return }
            if chunker.finish() > 0 { log.record("speech_odd_byte_dropped", ["purpose": utterance.purpose]) }
            guard totalBytes > 0 else { throw Failure.emptyAudio }
            playback?.requestMs = elapsedMs()
            newPlayer.endInput()
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            let failure = Self.classify(error, audioReceived: playback?.firstAudioMs != nil)
            if audioStarted {
                // Sound is already coming out: let what is buffered finish, and do not repeat the line in another voice.
                log.record("speech_stream_cut", [
                    "purpose": utterance.purpose, "reason": Self.reasonLabel(for: failure),
                    "bytes": playback?.bytes ?? 0, "next": "buffered audio plays out, no fallback voice"
                ])
                newPlayer.endInput()
            } else {
                newPlayer.stop()
                player = nil
                fallBack(utterance, reason: Self.reasonLabel(for: failure), requestMs: elapsedMs())
            }
        }
    }

    private struct ReplyHeaders {
        let provider: String?
        let fallbackReason: String?
    }

    /// Checks status and format. Throws a `Failure` for anything but a PCM stream from the server.
    private static func checkHeaders(
        _ response: URLResponse, bytes: URLSession.AsyncBytes,
        onHeaders: @MainActor (ReplyHeaders) -> Void, onServerError: @MainActor (TutorError) -> Void
    ) async throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.wrongFormat("not_http") }
        guard (200..<300).contains(http.statusCode) else {
            // Errors are small JSON; read a few KB to learn which refusal it is.
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 4096 { break }
            }
            let decoded = try? JSONDecoder().decode(ServerErrorBody.self, from: body)
            let tutorError = HTTPTutorClient.error(status: http.statusCode, body: decoded)
            await onServerError(tutorError)
            throw Failure.http(status: http.statusCode, name: decoded?.error)
        }
        let format = http.value(forHTTPHeaderField: "x-audio-format") ?? "none"
        guard format == PCMFormat.wireName else { throw Failure.wrongFormat(format) }
        await onHeaders(ReplyHeaders(
            provider: http.value(forHTTPHeaderField: "x-voice-provider"),
            fallbackReason: http.value(forHTTPHeaderField: "x-voice-fallback")
        ))
    }

    /// Reads the byte stream and hands it on in chunks of about 50 ms. Return false from `onChunk` to stop early.
    private static func pump(_ bytes: URLSession.AsyncBytes, flushBytes: Int, onChunk: @MainActor (Data) -> Bool) async throws {
        var pending = Data()
        pending.reserveCapacity(flushBytes)
        for try await byte in bytes {
            pending.append(byte)
            if pending.count >= flushBytes {
                let chunk = pending
                pending = Data()
                pending.reserveCapacity(flushBytes)
                if await !onChunk(chunk) { return }
            }
        }
        if !pending.isEmpty { _ = await onChunk(pending) }
    }

    private static func classify(_ error: Error, audioReceived: Bool) -> Failure {
        if let failure = error as? Failure { return failure }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut { return audioReceived ? .stalled : .timedOutBeforeAudio }
            return .offline
        }
        return .offline
    }

    // MARK: - Device voice (fallback)

    @MainActor
    private func fallBack(_ utterance: Utterance, reason: String, requestMs: Int) {
        log.record("speech_fallback", [
            "purpose": utterance.purpose, "chars": utterance.chars, "reason": reason, "latency_ms": requestMs, "to": "device_voice"
        ])
        speakOnDevice(utterance, requestMs: requestMs, fallbackReason: reason, deviceOnly: nil)
    }

    @MainActor
    private func speakOnDevice(_ utterance: Utterance, requestMs: Int, fallbackReason: String?, deviceOnly: String?) {
        activateAudioSession(purpose: utterance.purpose)
        let speech = AVSpeechUtterance(string: utterance.fallbackText)
        speech.voice = bestDeviceVoice()
        speech.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        if LaunchOptions.mutesSound { speech.volume = 0 }      // `--silent`: spoken to nobody
        playback = Playback(purpose: utterance.purpose, chars: utterance.chars, source: "device", bytes: 0,
                            requestMs: requestMs, firstAudioMs: nil, provider: nil, fallbackHeader: nil, startedAt: Date())
        active = (utterance.purpose, utterance.chars)
        synthesizer.speak(speech)
        var fields: [String: Any] = ["purpose": utterance.purpose, "chars": utterance.chars, "source": "device", "latency_ms": requestMs]
        if let fallbackReason { fields["reason"] = fallbackReason }
        if let deviceOnly { fields["reason"] = deviceOnly }
        log.record("speech_started", fields)
    }

    /// Best installed English voice: premium, then enhanced, then default; North American English first among equals.
    /// Novelty voices are skipped. Chosen once and logged once.
    @MainActor
    private func bestDeviceVoice() -> AVSpeechSynthesisVoice? {
        if deviceVoiceChosen { return deviceVoice }
        deviceVoiceChosen = true
        let english = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            let regionBonus = (voice.language == "en-US" || voice.language == "en-CA") ? 1 : 0
            return voice.quality.rawValue * 10 + regionBonus
        }
        deviceVoice = english.max { rank($0) < rank($1) }
            ?? AVSpeechSynthesisVoice(language: "en-CA") ?? AVSpeechSynthesisVoice(language: "en-US")
        log.record("speech_voice_chosen", [
            "voices_considered": english.count,
            "quality": Self.qualityLabel(deviceVoice?.quality),
            "language": deviceVoice?.language ?? "none"
        ])
        return deviceVoice
    }

    private static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality?) -> String {
        switch quality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        case .default: return "default"
        default: return "unknown"
        }
    }

    // MARK: - Audio session

    @MainActor
    private func activateAudioSession(purpose: String) {
        if LaunchOptions.mutesSound { return }       // `--silent`: do not even duck whatever else the iPad is playing
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            // Speech can still work with the previous session; say so, do not stay quiet about it.
            log.record("speech_audio_session_failed", ["purpose": purpose, "detail": String(describing: error)])
        }
    }

    // MARK: - Device voice delegate (called on arbitrary queues; hop to the main actor)

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // A cancelled utterance reports didCancel, and stop() already cleared `playback`.
            guard self.playback?.source == "device" else { return }
            self.finishedSpeaking(ok: true, reasonIfNot: "")
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Always caused by stop() or a newer speak(), both of which log their own reason.
    }

    @MainActor
    private func finishedSpeaking(ok: Bool, reasonIfNot: String) {
        guard let done = playback else { return }
        var fields: [String: Any] = [
            "purpose": done.purpose, "chars": done.chars, "source": done.source, "bytes": done.bytes,
            "played_ms": Int(Date().timeIntervalSince(done.startedAt) * 1000), "latency_ms": done.requestMs,
            "chars_sent_this_run": charsSentThisRun
        ]
        if let firstAudio = done.firstAudioMs { fields["first_audio_ms"] = firstAudio }
        if let provider = done.provider { fields["provider"] = provider }
        if let fallback = done.fallbackHeader { fields["server_fallback"] = fallback }
        if !ok { fields["reason"] = reasonIfNot }
        log.record(ok ? "speech_finished" : "speech_failed", fields)
        playback = nil
        active = nil
        player = nil
    }
}

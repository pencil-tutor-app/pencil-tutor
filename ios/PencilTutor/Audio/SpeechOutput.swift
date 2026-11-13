import AVFoundation
import Foundation

/// Speaks hints and answers.
///
/// Normal path: fetch natural-sounding audio from our own server (`POST /api/speak`, OpenAI text-to-speech)
/// and play it with `AVAudioPlayer`. The on-device voice was judged unacceptable after first real use
/// (2026-11-13), so it is now only the fallback: when the server fails, answers slowly (over 4 s), the text is
/// too long, or the app has no server (scripted UI tests, unconfigured builds). Fallback prefers the best
/// installed English voice (premium, then enhanced, then default).
///
/// The same `speak` / `stop` API as before. Everything here runs on the main actor.
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    struct Remote {
        let baseURL: URL
        let token: String
    }

    /// Past this, the server is not worth waiting for and the device voice speaks instead.
    static let serverDeadline: TimeInterval = 4
    /// The server rejects longer text with 422, so longer text goes straight to the device voice.
    static let serverMaxChars = 600
    private static let cacheLimit = 20

    /// What is being spoken right now, for the log. Labels, sizes and times only, never the text.
    private struct Playback {
        let purpose: String
        let chars: Int
        let source: String   // "server", "cache" or "device"
        let bytes: Int
        let requestMs: Int
        let startedAt: Date
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let log: SessionLog
    private let remote: Remote?
    /// Why the server path is off, when it is (logged with every device-voice line).
    private let deviceOnlyReason: String
    private let session: URLSession

    private var player: AVAudioPlayer?
    private var fetchTask: Task<Void, Never>?
    /// Bumped by every `speak` and `stop`; a result that belongs to an older number is dropped.
    private var generation = 0
    private var active: (purpose: String, chars: Int)?
    private var playback: Playback?
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private var deviceVoice: AVSpeechSynthesisVoice?
    private var deviceVoiceChosen = false

    /// True while the hold-to-talk button is down or the microphone is recording. Nothing plays then, and
    /// anything playing is cut off, so the tutor never talks over the student's question.
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
        // Total time for the whole request, not just idle time: this is the 4 s rule.
        configuration.timeoutIntervalForRequest = Self.serverDeadline
        configuration.timeoutIntervalForResource = Self.serverDeadline
        self.session = URLSession(configuration: configuration)
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    @MainActor
    func speak(_ text: String, purpose: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.record("speech_skipped", ["purpose": purpose, "reason": "empty text"])
            return
        }
        guard !microphoneBusy else {
            log.record("speech_skipped", ["purpose": purpose, "chars": trimmed.count, "reason": "microphone_busy"])
            return
        }
        cancelActive(reason: "replaced_by_new_speech")
        generation += 1
        let mine = generation
        active = (purpose, trimmed.count)

        if let cached = cache[trimmed] {
            play(cached, purpose: purpose, chars: trimmed.count, source: "cache", requestMs: 0, text: trimmed)
            return
        }
        guard let remote else {
            speakOnDevice(trimmed, purpose: purpose, requestMs: 0, fallbackReason: nil, deviceOnly: deviceOnlyReason)
            return
        }
        guard trimmed.count <= Self.serverMaxChars else {
            fallBack(trimmed, purpose: purpose, reason: "text_over_\(Self.serverMaxChars)_chars", requestMs: 0)
            return
        }

        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let audio = try await self.fetchAudio(trimmed, purpose: purpose, remote: remote)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                guard mine == self.generation, !Task.isCancelled else { return }
                self.remember(audio, for: trimmed)
                self.play(audio, purpose: purpose, chars: trimmed.count, source: "server", requestMs: ms, text: trimmed)
            } catch {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                // A cancelled request is stop() or a newer speak(); those already logged why.
                guard mine == self.generation, !Task.isCancelled else { return }
                self.fallBack(trimmed, purpose: purpose, reason: Self.reasonLabel(for: error), requestMs: ms)
            }
        }
    }

    @MainActor
    func stop() {
        stop(reason: "stopped by app")
    }

    // MARK: - Stopping

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
        if let player, player.isPlaying { player.stop() }
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

    private enum FetchFailure: Error {
        case timedOut
        case offline
        case http(Int)
        case notAudio
        case emptyAudio
    }

    private static func reasonLabel(for error: Error) -> String {
        switch error {
        case FetchFailure.timedOut: return "timeout_over_\(Int(serverDeadline))s"
        case FetchFailure.offline: return "offline"
        case FetchFailure.http(let status): return "http_\(status)"
        case FetchFailure.notAudio: return "reply_not_audio"
        case FetchFailure.emptyAudio: return "empty_audio"
        default: return "request_failed"
        }
    }

    private func fetchAudio(_ text: String, purpose: String, remote: Remote) async throws -> Data {
        var request = URLRequest(url: remote.baseURL.appendingPathComponent("api/speak"), timeoutInterval: Self.serverDeadline)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(remote.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(SpeakRequest(sessionId: log.sessionID, text: text, purpose: purpose))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? FetchFailure.timedOut : FetchFailure.offline
        }
        guard let http = response as? HTTPURLResponse else { throw FetchFailure.notAudio }
        guard (200..<300).contains(http.statusCode) else { throw FetchFailure.http(http.statusCode) }
        guard (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("audio/") else { throw FetchFailure.notAudio }
        guard !data.isEmpty else { throw FetchFailure.emptyAudio }
        return data
    }

    private func remember(_ audio: Data, for text: String) {
        if cache[text] == nil { cacheOrder.append(text) }
        cache[text] = audio
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    // MARK: - Playback

    @MainActor
    private func play(_ audio: Data, purpose: String, chars: Int, source: String, requestMs: Int, text: String) {
        guard !microphoneBusy else {
            active = nil
            log.record("speech_skipped", ["purpose": purpose, "chars": chars, "reason": "microphone_busy"])
            return
        }
        activateAudioSession(purpose: purpose)
        do {
            let newPlayer = try AVAudioPlayer(data: audio, fileTypeHint: AVFileType.mp3.rawValue)
            newPlayer.delegate = self
            guard newPlayer.prepareToPlay(), newPlayer.play() else {
                throw FetchFailure.emptyAudio
            }
            player = newPlayer
            playback = Playback(purpose: purpose, chars: chars, source: source, bytes: audio.count, requestMs: requestMs, startedAt: Date())
            log.record("speech_started", [
                "purpose": purpose, "chars": chars, "source": source, "bytes": audio.count, "latency_ms": requestMs,
                "seconds": (newPlayer.duration * 10).rounded() / 10
            ])
        } catch {
            // The bytes arrived but would not play. Drop a bad cache entry so it is not replayed, then use the device voice.
            cache.removeValue(forKey: text)
            cacheOrder.removeAll { $0 == text }
            fallBack(text, purpose: purpose, reason: "audio_would_not_play", requestMs: requestMs)
        }
    }

    // MARK: - Device voice (fallback)

    @MainActor
    private func fallBack(_ text: String, purpose: String, reason: String, requestMs: Int) {
        log.record("speech_fallback", [
            "purpose": purpose, "chars": text.count, "reason": reason, "latency_ms": requestMs, "to": "device_voice"
        ])
        speakOnDevice(text, purpose: purpose, requestMs: requestMs, fallbackReason: reason, deviceOnly: nil)
    }

    @MainActor
    private func speakOnDevice(_ text: String, purpose: String, requestMs: Int, fallbackReason: String?, deviceOnly: String?) {
        activateAudioSession(purpose: purpose)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestDeviceVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        playback = Playback(purpose: purpose, chars: text.count, source: "device", bytes: 0, requestMs: requestMs, startedAt: Date())
        active = (purpose, text.count)
        synthesizer.speak(utterance)
        var fields: [String: Any] = ["purpose": purpose, "chars": text.count, "source": "device", "latency_ms": requestMs]
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
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            // Speech can still work with the previous session; say so, do not stay quiet about it.
            log.record("speech_audio_session_failed", ["purpose": purpose, "detail": String(describing: error)])
        }
    }

    // MARK: - Delegates (called on arbitrary queues; hop to the main actor)

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === finished else { return }
            self.finishedSpeaking(ok: flag, reasonIfNot: "player_reported_failure")
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === failed else { return }
            self.finishedSpeaking(ok: false, reasonIfNot: "decode_error")
        }
    }

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
            "played_ms": Int(Date().timeIntervalSince(done.startedAt) * 1000), "latency_ms": done.requestMs
        ]
        if !ok { fields["reason"] = reasonIfNot }
        log.record(ok ? "speech_finished" : "speech_failed", fields)
        playback = nil
        active = nil
        player = nil
    }
}

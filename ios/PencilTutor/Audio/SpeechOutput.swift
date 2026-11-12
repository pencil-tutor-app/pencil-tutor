import AVFoundation
import Foundation

/// Speaks hints and answers with the device's own voice (no server speech, plan amendment 3).
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let log: SessionLog

    init(log: SessionLog) {
        self.log = log
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, purpose: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.record("speech_skipped", ["purpose": purpose, "reason": "empty text"])
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            // Speech can still work with the previous session; say so, do not stay quiet about it.
            log.record("speech_audio_session_failed", ["purpose": purpose, "detail": String(describing: error)])
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-CA") ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
        log.record("speech_started", ["purpose": purpose, "chars": trimmed.count])
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            log.record("speech_stopped", ["reason": "stopped by app"])
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        log.record("speech_finished", ["chars": utterance.speechString.count])
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        log.record("speech_cancelled", ["chars": utterance.speechString.count])
    }
}

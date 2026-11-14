import AVFoundation
import Foundation

/// Records the student's question as a small m4a file between two taps of the microphone button.
final class AudioRecorder {
    struct Recording {
        let url: URL
        let duration: TimeInterval
    }

    /// Anything shorter than this is treated as an accidental tap pair.
    static let minimumSeconds: TimeInterval = 0.6
    /// Recording stops and sends by itself at this length, so a forgotten second tap never records for ever.
    static let maximumSeconds: TimeInterval = 30

    private var recorder: AVAudioRecorder?

    func ensurePermission() async -> Bool {
        await Self.requestPermission()
    }

    /// Also used by the live voice session, which owns the microphone while it is open.
    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    func start() throws {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            throw TutorError.recordingFailed(detail: "audio session: \(error)")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            guard newRecorder.record() else {
                throw TutorError.recordingFailed(detail: "AVAudioRecorder.record() returned false")
            }
            recorder = newRecorder
        } catch let error as TutorError {
            throw error
        } catch {
            throw TutorError.recordingFailed(detail: "\(error)")
        }
    }

    /// Stops recording and returns the file, or nil if nothing was recording.
    func stop() -> Recording? {
        guard let active = recorder else { return nil }
        let duration = active.currentTime
        active.stop()
        recorder = nil
        return Recording(url: active.url, duration: duration)
    }
}

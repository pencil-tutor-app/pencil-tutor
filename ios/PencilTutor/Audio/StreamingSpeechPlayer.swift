import AVFoundation
import Foundation

/// Plays raw PCM (signed 16-bit little-endian, 24 kHz, mono) while it is still arriving.
///
/// One instance per utterance. `append` takes whole samples (see `PCMChunker`); playback begins once about 150 ms is
/// buffered (see `PrebufferGate`), or when the stream ends if the utterance is shorter than that. When the last scheduled
/// buffer has been played the `onFinished` callback fires. Everything runs on the main actor; AVFoundation's completion
/// callbacks hop back to it.
@MainActor
final class StreamingSpeechPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var gate = PrebufferGate()
    private var tally = PlaybackTally()
    private var held: [AVAudioPCMBuffer] = []
    private var configObserver: NSObjectProtocol?

    private(set) var isPlaying = false
    private(set) var isStopped = false
    private(set) var scheduledBytes = 0

    /// Fires once, when the first sound is sent to the speaker.
    var onPlaybackStarted: (() -> Void)?
    /// Fires once, when the last buffer has been played.
    var onFinished: (() -> Void)?
    /// The audio engine could not start or restart. The string is a short label for the log.
    var onEngineProblem: ((String) -> Void)?

    /// Nil when the audio format cannot be created (should not happen on a real device).
    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(PCMFormat.sampleRate), channels: 1, interleaved: false
        ) else { return nil }
        self.format = format
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if LaunchOptions.silent {
            engine.mainMixerNode.outputVolume = 0      // `--silent`: everything still plays, at volume 0
            node.volume = 0
        }
        // Prepared now, while the network request is still going, so starting later is quick.
        engine.prepare()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Whole 16-bit samples only (even byte count).
    func append(_ pcm: Data) {
        guard !isStopped, pcm.count >= 2 else { return }
        let samples = PCM16.floats(from: pcm)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            onEngineProblem?("buffer_not_created")
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        scheduledBytes += pcm.count
        if isPlaying {
            schedule(buffer)
        } else {
            held.append(buffer)
            if gate.add(bytes: pcm.count) { startPlayback() }
        }
    }

    /// No more audio is coming. Starts a short utterance that never reached the prebuffer size.
    func endInput() {
        guard !isStopped else { return }
        if !isPlaying, gate.streamEnded() { startPlayback() }
        if tally.endInput() { finish() }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        teardown()
    }

    // MARK: - Private

    private func startPlayback() {
        do {
            try engine.start()
        } catch {
            onEngineProblem?("engine_start_failed")
            stop()
            return
        }
        node.play()
        isPlaying = true
        let buffers = held
        held = []
        buffers.forEach(schedule)
        onPlaybackStarted?()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        tally.didSchedule()
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed() }
        }
    }

    private func bufferPlayed() {
        guard !isStopped else { return }
        if tally.didComplete() { finish() }
    }

    private func finish() {
        guard !isStopped else { return }
        isStopped = true
        teardown()
        onFinished?()
    }

    private func teardown() {
        node.stop()
        engine.stop()
        held = []
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    /// A route change (headphones, Bluetooth) can stop the engine mid-sentence. Try once to carry on.
    private func engineConfigurationChanged() {
        guard !isStopped, isPlaying, !engine.isRunning else { return }
        do {
            try engine.start()
            node.play()
            onEngineProblem?("engine_restarted_after_route_change")
        } catch {
            onEngineProblem?("engine_restart_failed")
            stop()
        }
    }
}

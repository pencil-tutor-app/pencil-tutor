import Foundation

// The pure parts of streaming playback. /api/speak sends raw PCM: signed 16-bit little-endian, 24000 Hz, mono, no header
// (server contract 2026-11-14). Network chunks can end in the middle of a 16-bit sample, and playback should start after a
// small prebuffer so the first audio is fast without stuttering. Neither needs AVFoundation, so both are unit-tested.

enum PCMFormat {
    static let sampleRate = 24_000
    static let bytesPerSample = 2
    /// The value of the `x-audio-format` header the app accepts.
    static let wireName = "pcm_s16le_24000"

    static func bytes(forMilliseconds ms: Int) -> Int {
        sampleRate * bytesPerSample * ms / 1000
    }

    static func seconds(forBytes count: Int) -> Double {
        Double(count) / Double(sampleRate * bytesPerSample)
    }
}

/// Cuts a byte stream into whole 16-bit samples. A trailing odd byte is carried to the next chunk.
struct PCMChunker {
    private var carry: UInt8?
    private(set) var totalBytesIn = 0

    /// Returns the bytes that complete whole samples (always an even count, possibly empty).
    mutating func push(_ data: Data) -> Data {
        totalBytesIn += data.count
        var joined = Data()
        if let carry { joined.append(carry) }
        joined.append(data)
        carry = nil
        if joined.count % 2 == 1 {
            carry = joined.removeLast()
        }
        return joined
    }

    /// At the end of the stream: how many bytes could not form a sample and were dropped (0 or 1).
    mutating func finish() -> Int {
        defer { carry = nil }
        return carry == nil ? 0 : 1
    }
}

/// Holds audio back until about 150 ms is buffered, then lets playback start, exactly once. A very short utterance that
/// never reaches the threshold starts when the stream ends.
struct PrebufferGate {
    static let startingMilliseconds = 150

    let thresholdBytes: Int
    private(set) var started = false
    private(set) var bufferedBytes = 0

    init(thresholdBytes: Int = PCMFormat.bytes(forMilliseconds: PrebufferGate.startingMilliseconds)) {
        self.thresholdBytes = thresholdBytes
    }

    /// True exactly once: when enough audio has piled up to start playing.
    mutating func add(bytes: Int) -> Bool {
        bufferedBytes += bytes
        guard !started, bufferedBytes >= thresholdBytes else { return false }
        started = true
        return true
    }

    /// True if the stream ended before the threshold and there is something to play.
    mutating func streamEnded() -> Bool {
        guard !started, bufferedBytes > 0 else { return false }
        started = true
        return true
    }
}

/// Knows when the last scheduled buffer has been played: input has ended and every scheduled buffer completed.
struct PlaybackTally {
    private(set) var scheduled = 0
    private(set) var completed = 0
    private(set) var inputEnded = false

    mutating func didSchedule() { scheduled += 1 }

    /// Returns true when this completion was the last one.
    mutating func didComplete() -> Bool {
        completed += 1
        return isDone
    }

    /// Returns true if everything already played by the time input ended.
    mutating func endInput() -> Bool {
        inputEnded = true
        return isDone
    }

    var isDone: Bool { inputEnded && completed >= scheduled }
}

enum PCM16 {
    /// Little-endian signed 16-bit samples to Float32 in -1...1. An odd trailing byte is ignored.
    static func floats(from data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1])
                let sample = Int16(bitPattern: low | (high << 8))
                out[index] = Float(sample) / 32768
            }
        }
        return out
    }
}

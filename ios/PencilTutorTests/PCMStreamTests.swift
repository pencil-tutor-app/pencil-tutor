import XCTest
@testable import PencilTutor

final class PCMStreamTests: XCTestCase {
    func testFormatNumbers() {
        XCTAssertEqual(PCMFormat.bytes(forMilliseconds: 150), 7_200, "24000 samples/s x 2 bytes x 0.15 s")
        XCTAssertEqual(PCMFormat.bytes(forMilliseconds: 50), 2_400)
        XCTAssertEqual(PCMFormat.seconds(forBytes: 48_000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PCMFormat.wireName, "pcm_s16le_24000")
    }

    // MARK: - Whole samples only

    func testChunkerCarriesAnOddByteToTheNextChunk() {
        var chunker = PCMChunker()
        let first = chunker.push(Data([1, 2, 3]))
        XCTAssertEqual(Array(first), [1, 2])
        let second = chunker.push(Data([4, 5]))
        XCTAssertEqual(Array(second), [3, 4], "the carried byte leads the next chunk")
        XCTAssertEqual(chunker.finish(), 1, "byte 5 never completed a sample")
        XCTAssertEqual(chunker.totalBytesIn, 5)
    }

    func testChunkerKeepsEveryByteInOrder() {
        var chunker = PCMChunker()
        var out = Data()
        let source = (0..<100).map { UInt8($0) }
        var index = 0
        let sizes = [1, 3, 7, 2, 11, 5, 13, 1, 17, 9, 31]   // deliberately awkward sizes
        for size in sizes where index < source.count {
            let end = min(source.count, index + size)
            out.append(chunker.push(Data(source[index..<end])))
            index = end
        }
        out.append(chunker.push(Data(source[index...])))
        let dropped = chunker.finish()
        XCTAssertEqual(out.count % 2, 0, "only whole samples come out")
        XCTAssertEqual(out.count + dropped, 100)
        XCTAssertEqual(Array(out), Array(source.prefix(out.count)), "order preserved")
    }

    func testChunkerHandlesEmptyAndEvenChunks() {
        var chunker = PCMChunker()
        XCTAssertEqual(chunker.push(Data()).count, 0)
        XCTAssertEqual(Array(chunker.push(Data([9, 8]))), [9, 8])
        XCTAssertEqual(chunker.finish(), 0)
    }

    // MARK: - Prebuffer

    func testPlaybackStartsOnceWhenAboutAHundredFiftyMillisecondsIsBuffered() {
        var gate = PrebufferGate()
        XCTAssertEqual(gate.thresholdBytes, 7_200)
        XCTAssertFalse(gate.add(bytes: 2_400))
        XCTAssertFalse(gate.add(bytes: 2_400))
        XCTAssertTrue(gate.add(bytes: 2_400), "7,200 reached")
        XCTAssertFalse(gate.add(bytes: 2_400), "already started: exactly once")
        XCTAssertFalse(gate.streamEnded(), "nothing left to start")
    }

    func testAShortUtteranceStartsWhenTheStreamEnds() {
        var gate = PrebufferGate()
        XCTAssertFalse(gate.add(bytes: 3_000))
        XCTAssertTrue(gate.streamEnded())
        XCTAssertFalse(gate.streamEnded(), "once only")
    }

    func testAnEmptyStreamStartsNothing() {
        var gate = PrebufferGate()
        XCTAssertFalse(gate.streamEnded())
    }

    // MARK: - Knowing when the last buffer has played

    func testTallyFinishesWhenInputEndedAndEveryBufferPlayed() {
        var tally = PlaybackTally()
        tally.didSchedule(); tally.didSchedule(); tally.didSchedule()
        XCTAssertFalse(tally.didComplete())
        XCTAssertFalse(tally.didComplete())
        XCTAssertFalse(tally.endInput(), "one buffer is still playing")
        XCTAssertTrue(tally.didComplete(), "the last one finished after input ended")
    }

    func testTallyFinishesAtOnceIfEverythingPlayedBeforeInputEnded() {
        var tally = PlaybackTally()
        tally.didSchedule()
        XCTAssertFalse(tally.didComplete(), "input has not ended: more audio may come")
        XCTAssertTrue(tally.endInput())
    }

    // MARK: - Samples

    func testSamplesBecomeFloatsBetweenMinusOneAndOne() {
        let samples = PCM16.floats(from: Data([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00, 0x00, 0x40]))
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], -1.0, accuracy: 0.0001, "0x8000 is the most negative sample")
        XCTAssertEqual(samples[1], 32767.0 / 32768.0, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0, accuracy: 0.0001)
        XCTAssertEqual(samples[3], 0.5, accuracy: 0.0001, "0x4000 little-endian")
    }

    func testAnOddTrailingByteIsIgnored() {
        XCTAssertEqual(PCM16.floats(from: Data([0, 0, 7])).count, 1)
        XCTAssertEqual(PCM16.floats(from: Data()).count, 0)
    }
}

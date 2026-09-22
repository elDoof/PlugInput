import Testing

@testable import AudioCore

/// Non-interleaved scratch channels, so the tests can drive the pointer API the audio threads
/// use rather than a convenience wrapper that only the tests would exercise.
private final class Channels {
    let channelCount: Int
    let frames: Int
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    init(channelCount: Int, frames: Int) {
        self.channelCount = channelCount
        self.frames = frames
        pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        for channel in 0..<channelCount {
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            storage.initialize(repeating: 0, count: frames)
            pointers[channel] = storage
        }
    }

    deinit {
        for channel in 0..<channelCount {
            pointers[channel].deinitialize(count: frames)
            pointers[channel].deallocate()
        }
        pointers.deallocate()
    }

    func set(_ channel: Int, _ values: [Float]) {
        for (index, value) in values.enumerated() { pointers[channel][index] = value }
    }

    func values(_ channel: Int, count: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: pointers[channel], count: count))
    }
}

@Suite("Input ring buffer")
struct InputRingBufferTests {
    @Test("reads back the frames it was given in order")
    func readsBackTheFramesItWasGivenInOrder() {
        // Arrange
        let ring = InputRingBuffer(channelCount: 1, capacityFrames: 16)
        let source = Channels(channelCount: 1, frames: 4)
        source.set(0, [1, 2, 3, 4])
        let destination = Channels(channelCount: 1, frames: 4)

        // Act
        ring.write(from: source.pointers, frames: 4)
        let read = ring.read(into: destination.pointers, frames: 4)

        // Assert
        #expect(read == 4)
        #expect(destination.values(0, count: 4) == [1, 2, 3, 4])
    }

    @Test("keeps channels separate")
    func keepsChannelsSeparate() {
        // Arrange
        let ring = InputRingBuffer(channelCount: 2, capacityFrames: 16)
        let source = Channels(channelCount: 2, frames: 3)
        source.set(0, [1, 2, 3])
        source.set(1, [-1, -2, -3])
        let destination = Channels(channelCount: 2, frames: 3)

        // Act
        ring.write(from: source.pointers, frames: 3)
        ring.read(into: destination.pointers, frames: 3)

        // Assert
        #expect(destination.values(0, count: 3) == [1, 2, 3])
        #expect(destination.values(1, count: 3) == [-1, -2, -3])
    }

    @Test("wraps around the end of the buffer")
    func wrapsAroundTheEndOfTheBuffer() {
        // Arrange — drain most of a small ring so the next write straddles the end.
        let ring = InputRingBuffer(channelCount: 1, capacityFrames: 4)
        let first = Channels(channelCount: 1, frames: 3)
        first.set(0, [1, 2, 3])
        let drain = Channels(channelCount: 1, frames: 3)
        ring.write(from: first.pointers, frames: 3)
        ring.read(into: drain.pointers, frames: 3)

        let second = Channels(channelCount: 1, frames: 3)
        second.set(0, [7, 8, 9])
        let destination = Channels(channelCount: 1, frames: 3)

        // Act
        ring.write(from: second.pointers, frames: 3)
        let read = ring.read(into: destination.pointers, frames: 3)

        // Assert
        #expect(read == 3)
        #expect(destination.values(0, count: 3) == [7, 8, 9])
    }

    @Test("zero fills the shortfall when fewer frames are buffered than requested")
    func zeroFillsTheShortfallWhenFewerFramesAreBufferedThanRequested() {
        // Arrange
        let ring = InputRingBuffer(channelCount: 1, capacityFrames: 16)
        let source = Channels(channelCount: 1, frames: 2)
        source.set(0, [5, 6])
        let destination = Channels(channelCount: 1, frames: 4)
        destination.set(0, [9, 9, 9, 9])

        // Act
        ring.write(from: source.pointers, frames: 2)
        let read = ring.read(into: destination.pointers, frames: 4)

        // Assert — the real frames, then silence, never stale audio.
        #expect(read == 2)
        #expect(destination.values(0, count: 4) == [5, 6, 0, 0])
        #expect(ring.counts.starved == 2)
    }

    @Test("drops the oldest frames when capacity is exceeded")
    func dropsTheOldestFramesWhenCapacityIsExceeded() {
        // Arrange
        let ring = InputRingBuffer(channelCount: 1, capacityFrames: 4)
        let source = Channels(channelCount: 1, frames: 4)
        source.set(0, [1, 2, 3, 4])
        let more = Channels(channelCount: 1, frames: 2)
        more.set(0, [5, 6])
        let destination = Channels(channelCount: 1, frames: 4)

        // Act — six frames into a four-frame ring.
        ring.write(from: source.pointers, frames: 4)
        ring.write(from: more.pointers, frames: 2)
        ring.read(into: destination.pointers, frames: 4)

        // Assert — latency stays bounded by discarding the oldest, not the newest.
        #expect(destination.values(0, count: 4) == [3, 4, 5, 6])
        #expect(ring.counts.dropped == 2)
    }

    @Test("keeps only the newest frames when one write exceeds the whole capacity")
    func keepsOnlyTheNewestFramesWhenOneWriteExceedsTheWholeCapacity() {
        // Arrange
        let ring = InputRingBuffer(channelCount: 1, capacityFrames: 3)
        let source = Channels(channelCount: 1, frames: 5)
        source.set(0, [1, 2, 3, 4, 5])
        let destination = Channels(channelCount: 1, frames: 3)

        // Act
        ring.write(from: source.pointers, frames: 5)
        ring.read(into: destination.pointers, frames: 3)

        // Assert
        #expect(destination.values(0, count: 3) == [3, 4, 5])
        #expect(ring.counts.dropped == 2)
        #expect(ring.counts.written == 5)
    }

    @Test("reports how many frames are available to read")
    func reportsHowManyFramesAreAvailableToRead() {
        // Arrange
        let ring = InputRingBuffer(channelCount: 1, capacityFrames: 8)
        let source = Channels(channelCount: 1, frames: 5)

        // Act
        ring.write(from: source.pointers, frames: 5)

        // Assert
        #expect(ring.availableFrames == 5)
    }

    @Test("reset discards buffered audio")
    func resetDiscardsBufferedAudio() {
        // Arrange
        let ring = InputRingBuffer(channelCount: 1, capacityFrames: 8)
        let source = Channels(channelCount: 1, frames: 4)
        source.set(0, [1, 2, 3, 4])
        ring.write(from: source.pointers, frames: 4)
        let destination = Channels(channelCount: 1, frames: 4)

        // Act
        ring.reset()
        let read = ring.read(into: destination.pointers, frames: 4)

        // Assert
        #expect(ring.availableFrames == 0)
        #expect(read == 0)
        #expect(destination.values(0, count: 4) == [0, 0, 0, 0])
    }

    @Test("ignores an empty write")
    func ignoresAnEmptyWrite() {
        // Arrange
        let ring = InputRingBuffer(channelCount: 1, capacityFrames: 8)
        let source = Channels(channelCount: 1, frames: 1)

        // Act
        ring.write(from: source.pointers, frames: 0)

        // Assert
        #expect(ring.availableFrames == 0)
    }
}

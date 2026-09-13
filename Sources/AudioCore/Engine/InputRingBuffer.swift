import Foundation
import os

/// Carries microphone frames from the input tap to the render thread.
///
/// This exists because **`AVAudioEngine`'s input node captures audio it will not deliver
/// downstream** (gotcha #36). Measured on macOS 26.6.2: a tap on the input node reported a
/// 0.35 peak while the device the graph fed read exact digital silence from a separate
/// process, and a tone pushed into that same mixer at that same moment read -14.0 dBFS. The
/// tap works and the render path works; only `engine.connect(inputNode, to:)` carries nothing.
/// So the tap becomes the capture path and an `AVAudioSourceNode` becomes the chain's head,
/// with this buffer between them.
///
/// Frames are stored interleaved, and both sides are non-interleaved float — which is what
/// AVFAudio hands a tap and what it asks a source node to fill — so the copies are per-sample
/// rather than `memcpy`. At a 512-frame buffer that is a few thousand float writes per cycle,
/// against the tens of thousands the plugin chain downstream is about to do.
///
/// **Two policies, both deliberate, because a ring between two audio threads can only fail in
/// two directions.** A write with no room drops the *oldest* frames, so latency stays bounded
/// rather than growing without limit if the producer ever outruns the consumer. A read with
/// too little buffered fills the shortfall with zeros and reports how many frames were real,
/// so a starved render is a short gap rather than stale audio repeated. Both are counted, so
/// the engine can say which one is happening instead of the user hearing "it glitches".
///
/// `@unchecked Sendable` on the same terms as `PeakLevel`: the invariant is held by the lock,
/// not by the compiler. The lock is `OSAllocatedUnfairLock` rather than `NSLock` because both
/// callers are audio threads — it is the one lock on this platform that donates priority, so a
/// lower-priority producer cannot leave the render thread waiting on it.
public final class InputRingBuffer: @unchecked Sendable {
    /// How many frames of audio were discarded because the producer outran the consumer.
    public struct Counts: Equatable, Sendable {
        public let written: Int
        public let read: Int
        public let dropped: Int
        public let starved: Int
    }

    public let channelCount: Int
    public let capacityFrames: Int

    private let lock = OSAllocatedUnfairLock()
    private let storage: UnsafeMutablePointer<Float>
    private var writeCursor = 0
    private var readCursor = 0
    private var fillFrames = 0
    private var writtenFrames = 0
    private var readFrames = 0
    private var droppedFrames = 0
    private var starvedFrames = 0

    public init(channelCount: Int, capacityFrames: Int) {
        precondition(channelCount > 0, "a ring buffer needs at least one channel")
        precondition(capacityFrames > 0, "a ring buffer needs a non-zero capacity")
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        storage = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * capacityFrames)
        storage.initialize(repeating: 0, count: channelCount * capacityFrames)
    }

    deinit {
        storage.deinitialize(count: channelCount * capacityFrames)
        storage.deallocate()
    }

    /// Frames currently readable.
    public var availableFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return fillFrames
    }

    /// Frames dropped and zero-filled so far, for diagnostics.
    public var counts: Counts {
        lock.lock()
        defer { lock.unlock() }
        return Counts(
            written: writtenFrames,
            read: readFrames,
            dropped: droppedFrames,
            starved: starvedFrames
        )
    }

    public func reset() {
        lock.lock()
        writeCursor = 0
        readCursor = 0
        fillFrames = 0
        writtenFrames = 0
        readFrames = 0
        droppedFrames = 0
        starvedFrames = 0
        lock.unlock()
    }

    /// Writes non-interleaved frames from the input tap. Realtime-safe: no allocation.
    ///
    /// `source` must carry at least `channelCount` channel pointers, each with `frames`
    /// samples. Channels beyond this buffer's `channelCount` are ignored; a `frames` larger
    /// than the whole capacity keeps only the newest `capacityFrames`, since nothing older
    /// could survive the write anyway.
    public func write(from source: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        guard frames > 0 else { return }
        let keep = min(frames, capacityFrames)
        let skip = frames - keep

        lock.lock()
        defer { lock.unlock() }

        var written = 0
        while written < keep {
            let slot = (writeCursor + written) % capacityFrames
            let run = min(keep - written, capacityFrames - slot)
            for channel in 0..<channelCount {
                let input = source[channel] + skip + written
                let base = storage + slot * channelCount + channel
                for frame in 0..<run {
                    base[frame * channelCount] = input[frame]
                }
            }
            written += run
        }

        writeCursor = (writeCursor + keep) % capacityFrames
        fillFrames += keep
        writtenFrames += keep
        if fillFrames > capacityFrames {
            let overrun = fillFrames - capacityFrames
            readCursor = (readCursor + overrun) % capacityFrames
            fillFrames = capacityFrames
            droppedFrames += overrun
        }
    }

    /// Fills `destination` with buffered frames, zeroing any shortfall.
    ///
    /// Returns how many of the requested frames were real audio. Realtime-safe: no allocation.
    @discardableResult
    public func read(into destination: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }

        lock.lock()
        let usable = min(fillFrames, frames)

        var read = 0
        while read < usable {
            let slot = (readCursor + read) % capacityFrames
            let run = min(usable - read, capacityFrames - slot)
            for channel in 0..<channelCount {
                let base = storage + slot * channelCount + channel
                let output = destination[channel] + read
                for frame in 0..<run {
                    output[frame] = base[frame * channelCount]
                }
            }
            read += run
        }

        readCursor = (readCursor + usable) % capacityFrames
        fillFrames -= usable
        readFrames += usable
        starvedFrames += frames - usable
        lock.unlock()

        if usable < frames {
            for channel in 0..<channelCount {
                (destination[channel] + usable).update(repeating: 0, count: frames - usable)
            }
        }
        return usable
    }
}

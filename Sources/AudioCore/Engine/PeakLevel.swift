import Foundation

/// A single peak value shared between AVFAudio's realtime tap and the UI.
///
/// This type exists to be capturable by the input tap *without* capturing the engine
/// controller. The tap is invoked on `RealtimeMessenger.mServiceQueue`, so a closure that
/// touches `@MainActor` state trips Swift's executor check and takes the process down with
/// `EXC_BREAKPOINT` on the very first audio buffer — a failure that only appears once real
/// audio starts flowing, which is why it outlived every build-and-launch check.
///
/// `@unchecked Sendable` because the invariant is held by the lock rather than by the
/// compiler: every access to `value` goes through it.
public final class PeakLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    public init() {}

    /// Most recent peak, 0...1.
    public var current: Float {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func record(_ peak: Float) {
        lock.lock()
        value = peak
        lock.unlock()
    }

    public func reset() {
        record(0)
    }
}

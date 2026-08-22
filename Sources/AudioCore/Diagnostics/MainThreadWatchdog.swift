import Foundation

/// Notices when the main thread stops answering, and says so in the log.
///
/// This exists because the app's remaining stability complaint is a **freeze that has never
/// reproduced here**. A frozen menu bar app is uniquely undiagnosable from the user's side: there
/// is no window to show an error in, the log line that would explain it is never written because
/// the thread that would write it is the stuck one, and the only way out is Activity Monitor —
/// which leaves no record at all. `sample $(pgrep PlugInput)` is the right tool and is documented,
/// but it requires somebody to be at a terminal *during* the freeze.
///
/// So the app watches itself. A timer on a private queue pings the main queue and measures how
/// long the ping takes to come back; anything past the threshold is written to the unified log at
/// error level, with the duration. That does not name the blocking frame, but it timestamps the
/// stall — and the engine transcript around that timestamp says what the app was doing, which is
/// the part nobody currently has.
///
/// **It reports; it never intervenes.** There is no safe way to interrupt whatever is blocking
/// the main thread — it is generally inside third-party plugin code — and a watchdog that tried
/// would turn a freeze into a crash.
public final class MainThreadWatchdog: @unchecked Sendable {
    /// Long enough that ordinary work never trips it, short enough to catch a stall the user
    /// would call a freeze. Plugin windows draw vendor code on the main thread, and a heavy
    /// interface opening is allowed to take a moment.
    public static let defaultThresholdSeconds: Double = 2

    /// Four polls inside the threshold, so the reported duration is close to the real one.
    private static let pollIntervalSeconds: Double = 0.5

    private let queue = DispatchQueue(label: "com.pluginput.watchdog", qos: .utility)
    private let clock = ContinuousClock()

    /// Everything below is touched from both `queue` and the main queue.
    private let lock = NSLock()
    private var lastResponse: ContinuousClock.Instant
    private var isPingOutstanding = false
    private var detector: MainThreadStallDetector
    private var timer: (any DispatchSourceTimer)?

    public init(thresholdSeconds: Double = defaultThresholdSeconds) {
        detector = MainThreadStallDetector(thresholdSeconds: thresholdSeconds)
        lastResponse = clock.now
    }

    /// Idempotent. Safe to call before the main run loop is up: the first ping simply lands late,
    /// and a launch that takes a moment is not reported as a stall because `lastResponse` starts
    /// at construction rather than at zero.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }

        lastResponse = clock.now
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + Self.pollIntervalSeconds,
            repeating: Self.pollIntervalSeconds
        )
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    deinit {
        timer?.cancel()
    }

    private func poll() {
        lock.lock()
        let elapsed = Self.seconds(from: lastResponse, to: clock.now)
        let (next, report) = detector.observing(unresponsiveFor: elapsed)
        detector = next
        let shouldPing = !isPingOutstanding
        if shouldPing { isPingOutstanding = true }
        lock.unlock()

        // Logged outside the lock: `Logger` takes its own, and nesting two is how a diagnostic
        // becomes the thing it was meant to diagnose.
        switch report {
        case let .began(seconds):
            EngineLog.logger.error(
                "main thread unresponsive for \(seconds, format: .fixed(precision: 1), privacy: .public)s — the app is frozen from here; the lines above say what it was doing"
            )
        case let .ended(longest):
            EngineLog.logger.error(
                "main thread responding again after \(longest, format: .fixed(precision: 1), privacy: .public)s"
            )
        case nil:
            break
        }

        // One ping in flight at a time. Queueing a fresh one every poll would pile up a backlog
        // during a stall, and the main thread would then spend its first moments back draining
        // pings instead of doing the work the user is waiting for.
        guard shouldPing else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            lock.lock()
            lastResponse = clock.now
            isPingOutstanding = false
            lock.unlock()
        }
    }

    /// Seconds between two instants, rounded to a tenth — the precision the log line can use.
    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let elapsed = end - start
        let raw = Double(elapsed.components.seconds)
            + (Double(elapsed.components.attoseconds) / 1e18)
        return (raw * 10).rounded() / 10
    }
}

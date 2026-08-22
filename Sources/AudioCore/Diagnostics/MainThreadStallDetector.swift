import Foundation

/// Decides when a run of main-thread unresponsiveness is worth reporting, and when it has ended.
///
/// Split out from `MainThreadWatchdog` so the decision is testable without threads or timing.
/// The watchdog around it is a timer and a lock; everything that could be *wrong* about a stall
/// report — reporting one twice, missing the recovery, reporting the wrong duration — lives here
/// and is covered by tests.
///
/// Immutable, like the rest of the model layer: `observing` returns the next detector rather than
/// mutating this one.
public struct MainThreadStallDetector: Equatable, Sendable {
    public enum Report: Equatable, Sendable {
        /// The main thread has now been unresponsive for at least `thresholdSeconds`. Reported
        /// once per stall, at the moment it crosses, not on every poll — a stall that lasts a
        /// minute must not write a hundred identical lines over the transcript that explains it.
        case began(seconds: Double)
        /// The main thread answered again. Carries the **longest** unresponsiveness observed
        /// during the stall, which is the number worth keeping: the poll that notices the
        /// recovery sees a near-zero value, and reporting that would understate every stall.
        case ended(longestSeconds: Double)
    }

    public let thresholdSeconds: Double
    private let isStalled: Bool
    private let longestSeconds: Double

    public init(thresholdSeconds: Double) {
        self.init(thresholdSeconds: thresholdSeconds, isStalled: false, longestSeconds: 0)
    }

    private init(thresholdSeconds: Double, isStalled: Bool, longestSeconds: Double) {
        self.thresholdSeconds = thresholdSeconds
        self.isStalled = isStalled
        self.longestSeconds = longestSeconds
    }

    /// Folds in one observation of how long the main thread has been unresponsive.
    ///
    /// The caller polls; this says what — if anything — to write down.
    public func observing(unresponsiveFor seconds: Double) -> (detector: Self, report: Report?) {
        let hasCrossed = seconds >= thresholdSeconds

        switch (isStalled, hasCrossed) {
        case (false, true):
            return (next(isStalled: true, longestSeconds: seconds), .began(seconds: seconds))

        case (true, true):
            // Still stalled. Track the worst reading and stay quiet until it clears.
            return (next(isStalled: true, longestSeconds: max(longestSeconds, seconds)), nil)

        case (true, false):
            return (next(isStalled: false, longestSeconds: 0), .ended(longestSeconds: longestSeconds))

        case (false, false):
            return (self, nil)
        }
    }

    private func next(isStalled: Bool, longestSeconds: Double) -> Self {
        Self(thresholdSeconds: thresholdSeconds, isStalled: isStalled, longestSeconds: longestSeconds)
    }
}

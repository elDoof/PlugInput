import Foundation

/// Decides when a run of main-thread unresponsiveness is worth reporting, and when it has ended.
///
/// Split out from `MainThreadWatchdog` so the decision is testable without threads or timing.
/// The watchdog around it is a timer and a lock; everything that could be *wrong* about a stall
/// report — reporting one twice, missing the recovery, reporting the wrong duration, or reporting
/// a stall that never happened — lives here and is covered by tests.
///
/// Immutable, like the rest of the model layer: `observing` returns the next detector rather than
/// mutating this one.
///
/// ## Why a poll needs to say how late it is
///
/// A process that was not *running* is indistinguishable, from the main thread's silence alone,
/// from a main thread that was not *answering*. On 2026-09-14 this app logged four freezes of up
/// to 17 minutes against a perfectly healthy process: the Mac had been asleep, and the first poll
/// after each wake measured the whole gap and blamed the main thread for it. The tell was in the
/// transcript — each stall was followed by its own recovery **half a second later**, because the
/// main thread answered the very first ping it was actually asked.
///
/// So a poll reports two numbers, not one: how long the main thread has been silent, and how long
/// since the poller itself last ran. When those are both large they describe the same gap and
/// nothing can be concluded. When the poller kept its cadence and only the main thread went quiet,
/// that is a real stall.
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
        /// The whole process stopped being scheduled — system sleep, App Nap, a debugger pause.
        /// Not a stall, and deliberately not silent: it explains a gap in the transcript that
        /// would otherwise look like the app having done nothing for a quarter of an hour.
        case suspended(gapSeconds: Double)
    }

    /// How far past its schedule a poll may drift and still be trusted. A utility-QoS timer under
    /// load slips by a little; a suspended process misses its slot by everything. The real
    /// readings that motivated this were 285s to 1014s against a 0.5s interval, so the boundary is
    /// nowhere near delicate — this only has to separate "late" from "was not running".
    private static let suspensionFactor: Double = 4

    public let thresholdSeconds: Double
    public let pollIntervalSeconds: Double
    private let isStalled: Bool
    private let longestSeconds: Double

    public init(thresholdSeconds: Double, pollIntervalSeconds: Double) {
        self.init(
            thresholdSeconds: thresholdSeconds,
            pollIntervalSeconds: pollIntervalSeconds,
            isStalled: false,
            longestSeconds: 0
        )
    }

    private init(
        thresholdSeconds: Double,
        pollIntervalSeconds: Double,
        isStalled: Bool,
        longestSeconds: Double
    ) {
        self.thresholdSeconds = thresholdSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.isStalled = isStalled
        self.longestSeconds = longestSeconds
    }

    /// The longest a poll may take to come round again before the process is presumed suspended.
    public var maxHealthyPollGapSeconds: Double {
        pollIntervalSeconds * Self.suspensionFactor
    }

    /// Folds in one observation: how long the main thread has been unresponsive, and how long
    /// since this poller last ran.
    ///
    /// The caller polls; this says what — if anything — to write down.
    public func observing(
        unresponsiveFor seconds: Double,
        sincePreviousPoll pollGap: Double
    ) -> (detector: Self, report: Report?) {
        // Checked before anything else: if the poller was not running, its reading of the main
        // thread is not evidence about the main thread. Any stall in progress is abandoned rather
        // than closed, because its true duration was never observed.
        guard pollGap <= maxHealthyPollGapSeconds else {
            return (next(isStalled: false, longestSeconds: 0), .suspended(gapSeconds: pollGap))
        }

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
        Self(
            thresholdSeconds: thresholdSeconds,
            pollIntervalSeconds: pollIntervalSeconds,
            isStalled: isStalled,
            longestSeconds: longestSeconds
        )
    }
}

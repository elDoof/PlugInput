import Testing

@testable import AudioCore

/// The watchdog around this is a timer and a lock. Everything that could be *wrong* about a stall
/// report lives here: reporting the same stall repeatedly would bury the transcript that explains
/// it, missing the recovery would leave the log claiming a freeze that ended minutes ago, and
/// reporting the duration seen at recovery — which is near zero, since the main thread has just
/// answered — would understate every stall to nothing.
///
/// The fourth way it can be wrong was found in the field on 2026-09-14 and is the reason
/// `sincePreviousPoll` exists: **a process that was not running looks exactly like a main thread
/// that was not answering.** Four "freezes" of up to 17 minutes were reported against a perfectly
/// healthy app. See `suspensionIsNotAStall`.
@Suite("Main thread stall detection")
struct MainThreadStallDetectorTests {
    private let threshold: Double = 2
    private let pollInterval: Double = 0.5

    private func detector() -> MainThreadStallDetector {
        MainThreadStallDetector(thresholdSeconds: threshold, pollIntervalSeconds: pollInterval)
    }

    /// A poll that arrived on schedule — the normal case, where the process is running and only
    /// the main thread's answer is in question.
    private func onSchedule(
        _ subject: MainThreadStallDetector,
        unresponsiveFor seconds: Double
    ) -> (detector: MainThreadStallDetector, report: MainThreadStallDetector.Report?) {
        subject.observing(unresponsiveFor: seconds, sincePreviousPoll: pollInterval)
    }

    @Test("says nothing while the main thread is answering")
    func quietWhenResponsive() {
        // Arrange
        var subject = detector()

        // Act
        var reports: [MainThreadStallDetector.Report?] = []
        for seconds in [0.0, 0.5, 1.0, 1.9] {
            let (next, report) = onSchedule(subject, unresponsiveFor: seconds)
            subject = next
            reports.append(report)
        }

        // Assert
        #expect(reports.allSatisfy { $0 == nil })
    }

    @Test("reports the stall on the poll that crosses the threshold")
    func reportsOnCrossing() {
        // Arrange
        let subject = detector()

        // Act
        let (_, report) = onSchedule(subject, unresponsiveFor: 2.0)

        // Assert — the boundary itself counts as a stall, not just past it.
        #expect(report == .began(seconds: 2.0))
    }

    @Test("reports a continuing stall exactly once")
    func reportsOncePerStall() {
        // Arrange
        var subject = detector()

        // Act
        let (afterFirst, first) = onSchedule(subject, unresponsiveFor: 2.5)
        subject = afterFirst
        var laterReports: [MainThreadStallDetector.Report?] = []
        for seconds in [3.0, 8.0, 40.0] {
            let (next, report) = onSchedule(subject, unresponsiveFor: seconds)
            subject = next
            laterReports.append(report)
        }

        // Assert
        #expect(first == .began(seconds: 2.5))
        #expect(laterReports.allSatisfy { $0 == nil })
    }

    @Test("reports recovery with the longest unresponsiveness seen, not the last")
    func recoveryCarriesThePeak() {
        // Arrange — a stall that peaks at 40s and is noticed as recovered at 0.1s.
        var subject = detector()
        for seconds in [2.5, 40.0, 12.0] {
            subject = onSchedule(subject, unresponsiveFor: seconds).detector
        }

        // Act
        let (_, report) = onSchedule(subject, unresponsiveFor: 0.1)

        // Assert — 40, not 12 and certainly not 0.1.
        #expect(report == .ended(longestSeconds: 40.0))
    }

    @Test("a second stall is reported after the first has cleared")
    func stallsAreReportedIndependently() {
        // Arrange
        var subject = detector()
        subject = onSchedule(subject, unresponsiveFor: 3.0).detector
        subject = onSchedule(subject, unresponsiveFor: 0.0).detector

        // Act
        let (_, report) = onSchedule(subject, unresponsiveFor: 5.0)

        // Assert
        #expect(report == .began(seconds: 5.0))
    }

    @Test("recovery is reported once, not on every quiet poll that follows")
    func recoveryReportedOnce() {
        // Arrange
        var subject = detector()
        subject = onSchedule(subject, unresponsiveFor: 3.0).detector

        // Act
        let (afterRecovery, recovery) = onSchedule(subject, unresponsiveFor: 0.0)
        subject = afterRecovery
        let (_, afterwards) = onSchedule(subject, unresponsiveFor: 0.0)

        // Assert
        #expect(recovery == .ended(longestSeconds: 3.0))
        #expect(afterwards == nil)
    }

    // MARK: - Suspension, which is not a stall

    @Test("a gap in the poller's own cadence is suspension, not a seventeen-minute freeze")
    func suspensionIsNotAStall() {
        // Arrange — the real reading from 2026-09-14 11:26:25. The main thread appeared
        // unresponsive for 1014.2s, but the poller had not run for 1014.2s either: the whole
        // process was suspended, so nothing at all is known about the main thread.
        let subject = detector()

        // Act
        let (_, report) = subject.observing(unresponsiveFor: 1014.2, sincePreviousPoll: 1014.2)

        // Assert
        #expect(report == .suspended(gapSeconds: 1014.2))
    }

    @Test("a real stall is still reported when the poller keeps its cadence")
    func genuineStallSurvivesTheSuspensionCheck() {
        // Arrange — the control for the test above. A main thread blocked for 1014s while the
        // watchdog queue keeps ticking every 0.5s is a genuine freeze and must still be reported,
        // or the fix for the false positives would have silenced the real thing.
        let subject = detector()

        // Act
        let (_, report) = subject.observing(unresponsiveFor: 1014.2, sincePreviousPoll: 0.5)

        // Assert
        #expect(report == .began(seconds: 1014.2))
    }

    @Test("a poller that is merely a little late is not called suspension")
    func mildLatenessIsStillAStall() {
        // Arrange — a utility-QoS timer under load can slip. Slipping is not suspension.
        let subject = detector()

        // Act
        let (_, report) = subject.observing(unresponsiveFor: 3.0, sincePreviousPoll: 0.9)

        // Assert
        #expect(report == .began(seconds: 3.0))
    }

    @Test("suspension abandons an in-progress stall rather than inventing its recovery")
    func suspensionClearsAnOpenStall() {
        // Arrange — a genuine stall is under way when the machine is put to sleep.
        var subject = detector()
        subject = subject.observing(unresponsiveFor: 3.0, sincePreviousPoll: 0.5).detector

        // Act
        let (afterGap, duringGap) = subject.observing(unresponsiveFor: 600.0, sincePreviousPoll: 600.0)
        subject = afterGap
        let (_, afterwards) = subject.observing(unresponsiveFor: 0.0, sincePreviousPoll: 0.5)

        // Assert — the gap is reported as suspension, and the abandoned stall does not then
        // surface as a phantom `.ended` carrying a duration nobody observed.
        #expect(duringGap == .suspended(gapSeconds: 600.0))
        #expect(afterwards == nil)
    }
}

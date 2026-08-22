import Testing

@testable import AudioCore

/// The watchdog around this is a timer and a lock. Everything that could be *wrong* about a stall
/// report lives here: reporting the same stall repeatedly would bury the transcript that explains
/// it, missing the recovery would leave the log claiming a freeze that ended minutes ago, and
/// reporting the duration seen at recovery — which is near zero, since the main thread has just
/// answered — would understate every stall to nothing.
@Suite("Main thread stall detection")
struct MainThreadStallDetectorTests {
    private let threshold: Double = 2

    private func detector() -> MainThreadStallDetector {
        MainThreadStallDetector(thresholdSeconds: threshold)
    }

    @Test("says nothing while the main thread is answering")
    func quietWhenResponsive() {
        // Arrange
        var subject = detector()

        // Act
        var reports: [MainThreadStallDetector.Report?] = []
        for seconds in [0.0, 0.5, 1.0, 1.9] {
            let (next, report) = subject.observing(unresponsiveFor: seconds)
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
        let (_, report) = subject.observing(unresponsiveFor: 2.0)

        // Assert — the boundary itself counts as a stall, not just past it.
        #expect(report == .began(seconds: 2.0))
    }

    @Test("reports a continuing stall exactly once")
    func reportsOncePerStall() {
        // Arrange
        var subject = detector()

        // Act
        let (afterFirst, first) = subject.observing(unresponsiveFor: 2.5)
        subject = afterFirst
        var laterReports: [MainThreadStallDetector.Report?] = []
        for seconds in [3.0, 8.0, 40.0] {
            let (next, report) = subject.observing(unresponsiveFor: seconds)
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
            subject = subject.observing(unresponsiveFor: seconds).detector
        }

        // Act
        let (_, report) = subject.observing(unresponsiveFor: 0.1)

        // Assert — 40, not 12 and certainly not 0.1.
        #expect(report == .ended(longestSeconds: 40.0))
    }

    @Test("a second stall is reported after the first has cleared")
    func stallsAreReportedIndependently() {
        // Arrange
        var subject = detector()
        subject = subject.observing(unresponsiveFor: 3.0).detector
        subject = subject.observing(unresponsiveFor: 0.0).detector

        // Act
        let (_, report) = subject.observing(unresponsiveFor: 5.0)

        // Assert
        #expect(report == .began(seconds: 5.0))
    }

    @Test("recovery is reported once, not on every quiet poll that follows")
    func recoveryReportedOnce() {
        // Arrange
        var subject = detector()
        subject = subject.observing(unresponsiveFor: 3.0).detector

        // Act
        let (afterRecovery, recovery) = subject.observing(unresponsiveFor: 0.0)
        subject = afterRecovery
        let (_, afterwards) = subject.observing(unresponsiveFor: 0.0)

        // Assert
        #expect(recovery == .ended(longestSeconds: 3.0))
        #expect(afterwards == nil)
    }
}

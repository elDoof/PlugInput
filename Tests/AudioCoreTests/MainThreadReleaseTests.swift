import Foundation
import Testing

@testable import AudioCore

/// Records which thread an object's `deinit` ran on.
///
/// The whole failure this guards against is invisible from the object's own side: the release
/// itself succeeds on any thread, and only the vendor code inside `dealloc` objects. So the
/// thread is the only thing there is to assert on.
private final class ReleaseProbe {
    private let report: @Sendable (Bool) -> Void

    init(report: @escaping @Sendable (Bool) -> Void) {
        self.report = report
    }

    deinit {
        report(Thread.isMainThread)
    }
}

/// Where a `deinit` landed, written from one thread and read from another.
private final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func record(wasMain: Bool) {
        lock.lock()
        value = wasMain
        lock.unlock()
    }

    /// Read synchronously — `NSLock` is unavailable from an async context, and the wait below
    /// is a poll rather than a blocking acquire for exactly that reason.
    private var current: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// The recorded value, or `nil` if nothing was released within `timeout`.
    func awaitValue(timeout: TimeInterval = 2) async -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current { return current }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return current
    }
}

/// Letting go of a hosted Audio Unit runs the vendor's teardown, and vendors close windows in
/// there. A release on the engine queue is therefore an AppKit call on the engine queue, which
/// aborts the process — confirmed from a crash report whose faulting thread was
/// `com.pluginput.engine` inside `stopOnQueue`, releasing the chain's units.
///
/// The control test is the load-bearing half. Asserting "released on the main thread" proves
/// nothing unless the same probe demonstrably reports a background thread when the hop is
/// missing — otherwise a probe that always answered `true` would look like a passing fix.
@Suite("Releasing on the main thread")
struct MainThreadReleaseTests {
    @Test("hands the last reference to the main thread, whatever thread let go")
    func releasesOnMainThread() async {
        // Arrange
        let recorder = ThreadRecorder()
        let background = DispatchQueue(label: "test.release.background")

        // Act — let go from a queue that is definitively not the main one.
        await withCheckedContinuation { continuation in
            background.async {
                var probes = [ReleaseProbe { recorder.record(wasMain: $0) }]
                releaseOnMainThread(&probes)
                #expect(probes.isEmpty, "the caller's references must be dropped here")
                continuation.resume()
            }
        }

        // Assert
        #expect(await recorder.awaitValue() == true)
    }

    @Test("control: the same probe reports a background thread when nothing hops")
    func withoutTheHopItReleasesOnTheBackgroundThread() async {
        // Arrange
        let recorder = ThreadRecorder()
        let background = DispatchQueue(label: "test.release.control")

        // Act — identical, except the array is simply allowed to go out of scope.
        await withCheckedContinuation { continuation in
            background.async {
                var probes = [ReleaseProbe { recorder.record(wasMain: $0) }]
                probes = []
                _ = probes
                continuation.resume()
            }
        }

        // Assert
        #expect(await recorder.awaitValue() == false)
    }

    @Test("an empty array schedules nothing")
    func emptyArrayIsANoOp() {
        // Arrange
        var empty: [ReleaseProbe] = []

        // Act
        releaseOnMainThread(&empty)

        // Assert
        #expect(empty.isEmpty)
    }
}

import Foundation

/// Carries references across a queue hop for the sole purpose of letting go of them there.
///
/// `@unchecked Sendable` because the whole point is that nothing else touches these objects
/// again: they are handed over once, never read, and released when the box dies.
private struct ReleaseBox<T: AnyObject>: @unchecked Sendable {
    let objects: [T]
}

/// Empties `objects`, arranging for their **last** release to happen on the main thread.
///
/// Letting go of the final reference to an object is not a bookkeeping detail — it runs that
/// object's `dealloc`, on whatever thread happened to let go. For a hosted Audio Unit that means
/// `AudioComponentInstanceDispose` and then the vendor's own teardown, and vendors tear down
/// their *interface* in there. iZotope's Nectar 4 calls `-[NSWindow close]`; AppKit off the main
/// thread traps with "Must only be used from the main thread" and the process aborts. JUCE
/// plugins have the same expectation by a different name — their teardown wants the message
/// thread, which on macOS is the main thread.
///
/// So: any queue that holds the only remaining reference to third-party audio code has to hand
/// it back before dropping it. The caller's array is cleared here rather than by the caller, so
/// there is no window in which both this box and the caller hold one and the ordering is left to
/// chance.
///
/// **At process exit the main queue never drains again**, so objects handed over during
/// termination are never disposed at all. That is the intended outcome, not a leak worth
/// fixing: the OS reclaims the memory, and a vendor's exit-time teardown is the thing that has
/// been taking this app down on quit.
func releaseOnMainThread<T: AnyObject>(_ objects: inout [T]) {
    guard !objects.isEmpty else { return }

    let box = ReleaseBox(objects: objects)
    objects = []
    DispatchQueue.main.async { withExtendedLifetime(box) {} }
}

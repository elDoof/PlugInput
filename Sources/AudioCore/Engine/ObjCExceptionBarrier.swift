import Foundation
import ObjCExceptionBridge

/// An Objective-C exception raised by AVFoundation, caught and turned into a Swift error.
///
/// `label` names the graph step that raised, because the exception's own text rarely does.
/// "required condition is false: nullptr == Tap()" says what the runtime objected to; only the
/// label says which of six `connect`/`attach`/`installTap` calls it came from.
public enum ObjCExceptionError: Error, CustomStringConvertible {
    case raised(label: String, name: String, reason: String)

    public var description: String {
        switch self {
        case let .raised(label, name, reason):
            return "\(label) raised \(name): \(reason)"
        }
    }
}

/// Runs a graph mutation, converting an Objective-C exception into a thrown Swift error.
///
/// **A caught exception means the graph is in an undefined state.** This is a reporting
/// mechanism, never a resume mechanism: every caller must tear the engine down rather than
/// carry on, because `AVAudioEngine` raised part-way through mutating itself and nothing
/// promises what it left behind. `startOnQueue`'s existing `catch` already does exactly that —
/// `stopOnQueue()`, publish `.failed`, rethrow — which is why this drops in without new error
/// handling at the call sites.
///
/// A Swift error thrown by `body` passes through **unchanged**. That matters for
/// `engine.start()`, whose `-10875 IsFormatSampleRateAndChannelCountValid` text is how gotcha
/// #19 was diagnosed; wrapping it would have cost that diagnosis.
///
/// See `PIObjCExceptionBridge.h` for what this does not catch.
func withGraphBarrier<T>(_ label: String, _ body: () throws -> T) throws -> T {
    var outcome: Result<T, any Error>?
    var raised: NSError?

    let completed = PIRunCatchingNSException({ outcome = Result(catching: body) }, &raised)

    guard completed else {
        let name = raised?.userInfo[PIObjCExceptionNameKey] as? String ?? "NSException"
        let reason = raised?.localizedDescription ?? "no reason given"
        // Logged here rather than at the call sites, so the label and full reason reach the
        // unified log no matter what a caller decides to do with the error.
        EngineLog.logger.error(
            """
            graph barrier caught \(name, privacy: .public) while \(label, privacy: .public): \
            \(reason, privacy: .public) — tearing the engine down
            """
        )
        throw ObjCExceptionError.raised(label: label, name: name, reason: reason)
    }

    guard let outcome else {
        // Unreachable: the block is non-escaping and always runs. Handled rather than
        // force-unwrapped because this file exists to stop the process dying on surprises.
        throw ObjCExceptionError.raised(label: label, name: "NSException", reason: "block did not run")
    }
    return try outcome.get()
}

/// The same barrier for teardown, which cannot throw.
///
/// `stopOnQueue` runs from `willTerminate`, and the aggregate has to be destroyed before the
/// process exits whatever else went wrong — an orphan outlives it and sits in the user's audio
/// settings (gotcha #7). So a raise while detaching a node must not prevent the destroy that
/// follows it. `withGraphBarrier` has already logged by the time this swallows anything.
func ignoringObjCException(_ label: String, _ body: () -> Void) {
    try? withGraphBarrier(label, body)
}

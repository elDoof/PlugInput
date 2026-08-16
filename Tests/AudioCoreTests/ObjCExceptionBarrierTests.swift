import AVFoundation
import Foundation
import Testing

@testable import AudioCore

/// The barrier is one of the few parts of the engine that is genuinely unit-testable, and it is
/// worth testing hard: everything it guards fails by *aborting the process*, so a barrier that
/// silently stopped catching would look exactly like a barrier that was never needed.
///
/// The distinction the middle tests draw is the load-bearing one. An Objective-C exception must
/// become an `ObjCExceptionError`; a Swift error thrown by the body must arrive at the caller
/// **unchanged**. `engine.start()` sits inside a barrier and throws real `AVAudioEngine` errors
/// whose text is how gotcha #19 was diagnosed — wrapping those would have cost that diagnosis.
@Suite("Objective-C exception barrier")
struct ObjCExceptionBarrierTests {
    @Test("returns the body's value when nothing is raised")
    func returnsValue() throws {
        // Arrange
        let expected = 42

        // Act
        let result = try withGraphBarrier("computing") { expected }

        // Assert
        #expect(result == expected)
    }

    @Test("converts a raised NSException into a Swift error carrying its name and reason")
    func convertsRaisedException() throws {
        // Arrange
        let raiser: () throws -> Void = {
            NSException(name: .invalidArgumentException, reason: "nullptr == Tap()", userInfo: nil)
                .raise()
        }

        // Act — the point of the whole exercise: a raise arrives as a *catchable* error.
        let error = #expect(throws: ObjCExceptionError.self) {
            try withGraphBarrier("installing input tap", raiser)
        }

        // Assert
        guard case let .raised(label, name, reason) = try #require(error) else { return }
        #expect(label == "installing input tap")
        #expect(name == NSExceptionName.invalidArgumentException.rawValue)
        #expect(reason == "nullptr == Tap()")
    }

    @Test("names the failing step in the error's description")
    func describesLabel() {
        // Arrange
        let error = ObjCExceptionError.raised(
            label: "attaching effect",
            name: "NSInternalInconsistencyException",
            reason: "required condition is false"
        )

        // Act
        let text = "\(error)"

        // Assert — this string is what lands in the menu bar, so it has to read as a sentence.
        #expect(text.contains("attaching effect"))
        #expect(text.contains("NSInternalInconsistencyException"))
        #expect(text.contains("required condition is false"))
    }

    @Test("passes a Swift error through unchanged instead of wrapping it")
    func passesSwiftErrorThrough() throws {
        // Arrange
        let original = AudioCoreError.message("input device is not part of the aggregate")

        // Act
        let thrown = #expect(throws: AudioCoreError.self) {
            try withGraphBarrier("applying channel map") { throw original }
        }

        // Assert — an AudioCoreError, not an ObjCExceptionError, and the text is untouched.
        #expect("\(try #require(thrown))" == "\(original)")
    }

    @Test("the ignoring variant swallows a raise and lets later work run")
    func ignoringVariantContinues() {
        // Arrange — mirrors `stopOnQueue`, where the aggregate must still be destroyed
        // (gotcha #7) even if node teardown misbehaves.
        var didReachTeardown = false

        // Act
        ignoringObjCException("removing input tap") {
            NSException(name: .internalInconsistencyException, reason: "boom", userInfo: nil).raise()
        }
        didReachTeardown = true

        // Assert
        #expect(didReachTeardown)
    }

    @Test("the ignoring variant runs the body's side effects when nothing is raised")
    func ignoringVariantRunsBody() {
        // Arrange
        var didRun = false

        // Act
        ignoringObjCException("stopping engine") { didRun = true }

        // Assert
        #expect(didRun)
    }

    /// The synthetic tests above prove the mechanism; this one proves it against the exception
    /// that actually killed the app. Installing a second tap on an occupied bus is gotcha #14
    /// verbatim — `required condition is false: nullptr == Tap()` — and it needs no microphone
    /// permission, because the raise happens while configuring the node rather than while audio
    /// flows. Uses a mixer node rather than `engine.inputNode`: reaching for the input node makes
    /// `AVAudioEngine` build a capture chain, which in a test bundle with no TCC grant is exactly
    /// the kind of environment-dependent behaviour that produces a flaky test.
    @Test("catches the real AVAudioEngine double-tap exception")
    func catchesRealDoubleTapException() throws {
        // Arrange
        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        let format = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
        defer { mixer.removeTap(onBus: 0) }

        // Act — without the barrier this line aborts the process rather than throwing.
        let error = #expect(throws: ObjCExceptionError.self) {
            try withGraphBarrier("installing input tap") {
                mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
            }
        }

        // Assert
        guard case let .raised(_, _, reason) = try #require(error) else { return }
        #expect(reason.contains("Tap()"))
    }
}

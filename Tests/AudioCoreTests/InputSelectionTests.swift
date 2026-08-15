import CoreAudio
import Testing

@testable import AudioCore

/// Regression cover for a silent-input failure that reproduces on any Mac where another app
/// has been pointed at the virtual device — which is the entire point of this app.
///
/// The virtual device is deliberately absent from the selectable inputs (choosing it would feed
/// the processed signal back into itself). The system default input is *not* filtered that way,
/// so once Zoom or Discord sets BlackHole as the default microphone, the old fallback resolved
/// to a UID that no selectable device carries. `start()` then refused with "No input device
/// selected" and the app captured nothing.
private func device(uid: String, name: String, inputChannels: Int) -> AudioDevice {
    AudioDevice(id: 0, uid: uid, name: name, inputChannels: inputChannels, outputChannels: 0)
}

private let mic = device(uid: "mic", name: "Built-in Mic", inputChannels: 1)
private let interface = device(uid: "if", name: "Interface", inputChannels: 2)

@Suite("Input selection")
struct InputSelectionTests {
    @Test("keeps the saved device when it is still available")
    func keepsSavedDevice() {
        // Arrange
        let available = [mic, interface]

        // Act
        let resolved = InputSelection.resolve(saved: "if", available: available, systemDefault: "mic")

        // Assert — a saved choice outranks the system default; the user picked it on purpose.
        #expect(resolved == "if")
    }

    @Test("falls back to the system default when nothing is saved")
    func fallsBackToSystemDefault() {
        let resolved = InputSelection.resolve(saved: nil, available: [mic, interface], systemDefault: "if")

        #expect(resolved == "if")
    }

    @Test("ignores a system default that is not selectable")
    func ignoresUnselectableSystemDefault() {
        // Arrange — BlackHole is the system default microphone but is filtered out of the
        // selectable inputs, so it must never be resolved to.
        let available = [mic, interface]

        // Act
        let resolved = InputSelection.resolve(saved: nil, available: available, systemDefault: "bh")

        // Assert — falls through to a real device rather than naming one that cannot be used.
        #expect(resolved == "mic")
    }

    @Test("ignores a saved device that has been unplugged")
    func ignoresMissingSavedDevice() {
        let resolved = InputSelection.resolve(saved: "gone", available: [mic], systemDefault: nil)

        #expect(resolved == "mic")
    }

    @Test("prefers the system default over the first device when the saved one is gone")
    func unpluggedSavedDeviceFallsBackToDefault() {
        let resolved = InputSelection.resolve(saved: "gone", available: [mic, interface], systemDefault: "if")

        #expect(resolved == "if")
    }

    @Test("resolves to nothing when no input device exists at all")
    func noDevicesResolvesToNil() {
        let resolved = InputSelection.resolve(saved: "mic", available: [], systemDefault: "mic")

        #expect(resolved == nil)
    }

    @Test("never returns a uid absent from the available list")
    func resultIsAlwaysSelectable() {
        // The invariant the caller depends on: whatever comes back can be found in the list
        // `start()` searches, for every combination of stale saved value and stray default.
        let available = [mic, interface]
        let candidates: [String?] = [nil, "mic", "if", "bh", "gone"]

        for saved in candidates {
            for systemDefault in candidates {
                let resolved = InputSelection.resolve(
                    saved: saved,
                    available: available,
                    systemDefault: systemDefault
                )
                #expect(available.contains { $0.uid == resolved })
            }
        }
    }
}

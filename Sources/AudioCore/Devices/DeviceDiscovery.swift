import CoreAudio
import Foundation

/// One consistent answer to "what audio devices are there right now".
public struct AudioEnvironment: Sendable {
    /// The loopback the processed signal is written to — the PlugInput HAL driver.
    public let loopback: AudioDevice?
    /// Where the user hears themselves; the system's current default output.
    public let monitor: AudioDevice?
    /// Inputs worth offering, with everything self-referential already removed.
    public let inputs: [AudioDevice]
    /// The system default input, as a *hint* for `InputSelection` — frequently the loopback.
    public let systemDefaultInputUID: String?

    public static let empty = AudioEnvironment(
        loopback: nil,
        monitor: nil,
        inputs: [],
        systemDefaultInputUID: nil
    )
}

/// Gathers the whole device picture in one pass, off the main thread.
///
/// Two reasons this is not just inline `DeviceEnumerator` calls. First, every one of them is a
/// synchronous round trip to `coreaudiod`, and running a dozen of them on the main actor each
/// time a menu opened made the interface hitch — the same class of mistake as gotcha #12, in a
/// milder form. Second, the exclusion rule below has to be applied in exactly one place.
public enum DeviceDiscovery {
    /// Blocking. **Call this off the main thread.**
    public static func scan() throws -> AudioEnvironment {
        let all = try DeviceEnumerator.allDevices()
        // Matched by UID, never by name: the engine's aggregate is *also* called "PlugInput",
        // and a private aggregate is invisible to other processes but plainly visible to the one
        // that created it — so a name match here could pick our own aggregate as the loopback.
        let loopback = all.first { $0.uid == VirtualMicrophone.driverUID && $0.hasOutput }

        // Never offer anything that carries our own output back to us. The loopback is the
        // obvious one; the engine's aggregate is the subtle one, because it *wraps* that
        // loopback and so looks like an ordinary 2-channel input. Selecting either would route
        // the processed signal into its own input.
        let excluded = Set([loopback?.uid, VirtualMicrophone.aggregateUID].compactMap { $0 })

        return AudioEnvironment(
            loopback: loopback,
            monitor: try? DeviceEnumerator.defaultOutputDevice(),
            inputs: all.filter { $0.hasInput && !excluded.contains($0.uid) },
            systemDefaultInputUID: (try? DeviceEnumerator.defaultInputDevice())?.uid
        )
    }
}

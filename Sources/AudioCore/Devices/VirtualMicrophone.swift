import Foundation

/// The identity other apps select in order to hear the processed signal.
///
/// The name comes from a CoreAudio HAL driver that PlugInput installs: a renamed build of
/// BlackHole, whose device name is the compile-time constant `kDevice_Name` rather than
/// anything settable at runtime. `make-driver.sh` builds it. That is what puts "PlugInput" in
/// Zoom's microphone list instead of "BlackHole 2ch".
///
/// Three earlier routes to the same goal failed, and each one is worth knowing about because
/// each looks like it should work:
///
/// 1. **Rename the installed BlackHole.** Dead end twice over: `kAudioObjectPropertyName`
///    reports `settable = false`, and macOS keeps no user-level name override for HAL devices —
///    `com.apple.audio.SystemSettings.plist` stores only aggregate definitions, which is exactly
///    why Audio MIDI Setup can rename an aggregate but not BlackHole.
/// 2. **Wrap the loopback in a second, public aggregate.** Creates cleanly, reports the right
///    2 in / 2 out, and delivers **exact digital silence** — BlackHole read −34.6 dBFS while the
///    wrapper read −120.0 dBFS at the same moment. CoreAudio will not relay a subdevice's
///    loopback into a second aggregate while the first one holds it. See gotcha #17.
/// 3. **Reorder the engine's own aggregate** to lead with the loopback, and publish that. The
///    channel-map write is accepted *and reads back correctly*, then zeroes the output hardware
///    format and `engine.start()` fails with −10875. See gotcha #19.
///
/// The driver route sidesteps all three: the name is baked into the device itself, so no
/// aggregate has to be published, and the microphone exists whether or not the engine is
/// running — which the aggregate route could never offer.
public enum VirtualMicrophone {
    /// What the user looks for in another app's microphone menu.
    public static let deviceName = "PlugInput"

    /// The HAL driver's device UID, which BlackHole derives as
    /// `kDriver_Name + "%ich" + "_UID"` — so a 2-channel build named "PlugInput" reports
    /// `PlugInput2ch_UID`.
    ///
    /// The loopback is matched on this rather than on its name, and that is load-bearing: the
    /// engine's aggregate is *also* called "PlugInput". A private aggregate is invisible to
    /// other processes but plainly visible to the one that created it, so a name match run from
    /// inside this app could resolve to our own aggregate and quietly route the processed signal
    /// back into its own input.
    public static let driverUID = "PlugInput2ch_UID"

    /// The engine's private aggregate UID. Shared so that `DeviceDiscovery` can exclude the
    /// aggregate from our own input picker by identity rather than by name — selecting it as our
    /// source would feed the processed signal straight back into itself.
    public static let aggregateUID = "com.pluginput.aggregate"
}

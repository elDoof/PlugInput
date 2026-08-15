import Foundation

/// The identity the engine's aggregate is published under, for other apps to select.
///
/// Other apps should not be told to pick "BlackHole 2ch" — that names someone else's driver and
/// says nothing about what is being selected. Two routes to a better name were tried:
///
/// 1. **Rename BlackHole.** Dead end: `kAudioObjectPropertyName` reports `settable = false` on
///    it, and rewriting the installed driver needs sudo and breaks every app already pointed
///    at it.
/// 2. **Wrap BlackHole in a second, public aggregate.** Creates cleanly, reports the right
///    2 in / 2 out, and delivers **exact digital silence** — BlackHole read −34.6 dBFS while
///    the wrapper read −120.0 dBFS at the same moment. CoreAudio will not relay a subdevice's
///    loopback into a second aggregate while the first one holds it. See gotcha #17.
///
/// What works is the third: publish the engine's own aggregate — the one that already holds
/// BlackHole — under this name, with the virtual device ordered first so its loopback lands on
/// input channels 0–1. That costs nothing extra at runtime, because the aggregate exists
/// anyway. The one visible consequence is that the device appears only while the engine is
/// running, since that is exactly when the aggregate exists.
public enum VirtualMicrophone {
    /// What the user looks for in another app's microphone menu.
    public static let deviceName = "PlugInput"

    /// The aggregate's UID. Shared so that `DeviceDiscovery` can exclude this device from our
    /// own input picker by identity rather than by name — selecting it as our source would
    /// feed the processed signal straight back into itself.
    public static let deviceUID = "com.pluginput.aggregate"
}

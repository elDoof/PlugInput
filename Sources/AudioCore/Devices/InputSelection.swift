import Foundation

/// Decides which input device the engine should capture from.
///
/// The one invariant: the result is always a device the caller can actually find in
/// `available`, or `nil` because there are no inputs at all. Nothing else in the app checks
/// that, so a UID naming a device outside the list surfaces only as `start()` refusing with
/// "No input device selected" — a silence with no obvious cause.
///
/// That is not hypothetical. `available` deliberately excludes the virtual device, because
/// capturing from it would feed the processed signal back into itself. The *system default
/// input* carries no such exclusion, and PlugInput exists to make other apps treat BlackHole
/// as a microphone — so the moment one of them makes it the default, the plain
/// "saved ?? systemDefault" fallback resolves to the single device that cannot be used.
///
/// Preference order: the user's saved choice, then the system default, then whatever is
/// present — each one only if it is genuinely selectable.
public enum InputSelection {
    public static func resolve(
        saved: String?,
        available: [AudioDevice],
        systemDefault: String?
    ) -> String? {
        for candidate in [saved, systemDefault] {
            if let candidate, available.contains(where: { $0.uid == candidate }) {
                return candidate
            }
        }
        return available.first?.uid
    }
}

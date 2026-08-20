import Foundation

/// Turns a linear peak into something a person can read.
///
/// The engine reports amplitude 0...1, but that is a poor thing to draw: speech at a healthy
/// −18 dBFS is an amplitude of 0.13, so a linear bar sits near the left edge and looks broken.
/// A dB scale puts normal speech in the middle of the meter, which is where a user expects it.
public enum AudioLevel {
    /// Bottom of the meter. −60 dBFS is quiet-room noise; anything below is not worth drawing.
    public static let floorDecibels: Double = -60

    public static func decibels(fromAmplitude amplitude: Float) -> Double {
        guard amplitude > 0 else { return floorDecibels }

        let decibels = 20 * log10(Double(amplitude))
        return max(decibels, floorDecibels)
    }

    /// 0...1 across `floorDecibels`...0 dBFS, for a progress bar.
    ///
    /// Clamped at both ends. The floor was already handled by `decibels`, but nothing capped the
    /// top: a plugin with makeup gain can hand back an amplitude above 1.0, which produced a
    /// fraction above 1.0 and a meter bar drawn outside its own container. Callers should not
    /// each have to remember `min(_:1)` — one of the two already did, and the other did not.
    public static func meterFraction(fromAmplitude amplitude: Float) -> Double {
        let decibels = decibels(fromAmplitude: amplitude)
        return min((decibels - floorDecibels) / -floorDecibels, 1)
    }
}

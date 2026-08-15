import AVFoundation
import Foundation

/// Captures and restores a plugin's own settings.
///
/// `auAudioUnit.fullState` is a plist dictionary the plugin defines and only the plugin
/// understands — it holds the vendor's opaque archive alongside the component triple. It is
/// therefore stored as-is (binary plist) rather than reinterpreted, and is only ever handed
/// back to the same plugin that produced it.
public enum PluginState {
    /// `nil` when the plugin exposes no state, which is legal and not an error.
    public static func capture(from unit: AVAudioUnit) throws -> Data? {
        guard let state = unit.auAudioUnit.fullState else { return nil }
        return try encode(state)
    }

    public static func apply(_ data: Data, to unit: AVAudioUnit) throws {
        unit.auAudioUnit.fullState = try decode(data)
    }

    static func encode(_ state: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let state = object as? [String: Any] else {
            throw AudioCoreError.message("saved plugin state is not a dictionary")
        }
        return state
    }
}

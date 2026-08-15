import Foundation

/// Everything worth remembering between launches, as one immutable value.
///
/// The point of this type is the coupling it enforces: `pluginState` is a blob only the plugin
/// that produced it can read, so it may never outlive or be separated from `plugin`. Both
/// updaters below drop the state whenever the plugin changes — see gotcha #8: plugins load
/// in-process, and feeding one vendor's archive to another's plugin takes the whole app down.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let inputUID: String?
    public let plugin: PluginDescriptor?
    /// Binary plist of `auAudioUnit.fullState`, encoded by `PluginState`.
    public let pluginState: Data?
    /// Whether the engine was running when this was written, so the next launch can resume.
    public let isRunning: Bool
    /// Whether the processed signal is also sent to the speakers/headphones. Off is how a user
    /// on speakers avoids their own output being picked back up by the microphone.
    public let isMonitorEnabled: Bool

    public static let empty = SessionSnapshot(
        inputUID: nil,
        plugin: nil,
        pluginState: nil,
        isRunning: false
    )

    public init(
        inputUID: String?,
        plugin: PluginDescriptor?,
        pluginState: Data?,
        isRunning: Bool,
        isMonitorEnabled: Bool = true
    ) {
        self.inputUID = inputUID
        self.plugin = plugin
        // An orphaned state blob has nothing to be applied to; refuse to hold one.
        self.pluginState = plugin == nil ? nil : pluginState
        self.isRunning = isRunning
        self.isMonitorEnabled = isMonitorEnabled
    }

    /// Hand-written so that a session file saved before `isMonitorEnabled` existed still loads.
    ///
    /// Synthesised `Codable` treats a missing key for a non-optional property as a decoding
    /// *failure*, and `AppModel` responds to a failed load by discarding the whole session —
    /// so adding a field to this struct would silently wipe the user's saved plugin and device.
    /// Defaulting to `true` also matches the behaviour those old files were written under.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputUID: try container.decodeIfPresent(String.self, forKey: .inputUID),
            plugin: try container.decodeIfPresent(PluginDescriptor.self, forKey: .plugin),
            pluginState: try container.decodeIfPresent(Data.self, forKey: .pluginState),
            isRunning: try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false,
            isMonitorEnabled: try container.decodeIfPresent(Bool.self, forKey: .isMonitorEnabled) ?? true
        )
    }

    public func settingInput(_ uid: String?) -> Self {
        Self(
            inputUID: uid,
            plugin: plugin,
            pluginState: pluginState,
            isRunning: isRunning,
            isMonitorEnabled: isMonitorEnabled
        )
    }

    /// Selecting a plugin keeps the saved state only when it is the *same* plugin.
    public func settingPlugin(_ plugin: PluginDescriptor?) -> Self {
        let keptState = plugin == self.plugin ? pluginState : nil
        return Self(
            inputUID: inputUID,
            plugin: plugin,
            pluginState: keptState,
            isRunning: isRunning,
            isMonitorEnabled: isMonitorEnabled
        )
    }

    public func settingPluginState(_ state: Data?) -> Self {
        Self(
            inputUID: inputUID,
            plugin: plugin,
            pluginState: state,
            isRunning: isRunning,
            isMonitorEnabled: isMonitorEnabled
        )
    }

    public func settingRunning(_ isRunning: Bool) -> Self {
        Self(
            inputUID: inputUID,
            plugin: plugin,
            pluginState: pluginState,
            isRunning: isRunning,
            isMonitorEnabled: isMonitorEnabled
        )
    }

    public func settingMonitorEnabled(_ isMonitorEnabled: Bool) -> Self {
        Self(
            inputUID: inputUID,
            plugin: plugin,
            pluginState: pluginState,
            isRunning: isRunning,
            isMonitorEnabled: isMonitorEnabled
        )
    }
}

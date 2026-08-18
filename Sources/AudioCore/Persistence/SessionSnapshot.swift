import Foundation

/// Everything worth remembering between launches, as one immutable value.
///
/// The coupling this type used to enforce by hand — a `pluginState` blob may never outlive or be
/// separated from the `plugin` that produced it, because feeding one vendor's archive to
/// another's plugin takes the whole app down (gotcha #8) — now lives inside `PluginChain`, where
/// it is structural: a slot's plugin never changes, so its state cannot drift onto a different
/// one. That is why growing one effect slot into an ordered chain did not grow this type's
/// invariants with it.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let inputUID: String?
    /// The ordered effect chain, each slot carrying its own settings and bypass.
    public let chain: PluginChain
    /// Whether the engine was running when this was written, so the next launch can resume.
    public let isRunning: Bool
    /// Whether the processed signal is also sent to the speakers/headphones. Off is how a user
    /// on speakers avoids their own output being picked back up by the microphone.
    public let isMonitorEnabled: Bool

    public static let empty = SessionSnapshot(
        inputUID: nil,
        chain: .empty,
        isRunning: false
    )

    public init(
        inputUID: String?,
        chain: PluginChain,
        isRunning: Bool,
        isMonitorEnabled: Bool = true
    ) {
        self.inputUID = inputUID
        self.chain = chain
        self.isRunning = isRunning
        self.isMonitorEnabled = isMonitorEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case inputUID, chain, isRunning, isMonitorEnabled
    }

    /// The single-slot format's keys. Read, never written.
    private enum LegacyCodingKeys: String, CodingKey {
        case plugin, pluginState
    }

    /// Hand-written so that older session files still load, and load with their contents intact.
    ///
    /// This is load-bearing twice over. Synthesised `Codable` treats a missing key for a
    /// non-optional property as a decoding *failure*, and `AppModel` answers a failed load by
    /// discarding the whole session — so a file written before `isMonitorEnabled`, or before
    /// `chain`, would silently wipe the user's saved setup on the next launch.
    ///
    /// And a file from the single-slot era carries `plugin` + `pluginState` rather than `chain`.
    /// Those become a one-slot chain, dial positions and all, rather than being dropped — the
    /// whole point of persisting a plugin's settings is that upgrading the app does not cost
    /// them. Both older shapes are covered by tests.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.init(
            inputUID: try container.decodeIfPresent(String.self, forKey: .inputUID),
            chain: try Self.decodeChain(from: decoder, container: container),
            isRunning: try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false,
            isMonitorEnabled: try container.decodeIfPresent(Bool.self, forKey: .isMonitorEnabled) ?? true
        )
    }

    private static func decodeChain(
        from decoder: any Decoder,
        container: KeyedDecodingContainer<CodingKeys>
    ) throws -> PluginChain {
        if let chain = try container.decodeIfPresent(PluginChain.self, forKey: .chain) {
            return chain
        }

        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        guard let plugin = try legacy.decodeIfPresent(PluginDescriptor.self, forKey: .plugin) else {
            return .empty
        }
        let state = try legacy.decodeIfPresent(Data.self, forKey: .pluginState)
        return PluginChain(slots: [PluginSlot(plugin: plugin, state: state)])
    }

    public func settingInput(_ uid: String?) -> Self {
        Self(inputUID: uid, chain: chain, isRunning: isRunning, isMonitorEnabled: isMonitorEnabled)
    }

    public func settingChain(_ chain: PluginChain) -> Self {
        Self(inputUID: inputUID, chain: chain, isRunning: isRunning, isMonitorEnabled: isMonitorEnabled)
    }

    public func settingRunning(_ isRunning: Bool) -> Self {
        Self(inputUID: inputUID, chain: chain, isRunning: isRunning, isMonitorEnabled: isMonitorEnabled)
    }

    public func settingMonitorEnabled(_ isMonitorEnabled: Bool) -> Self {
        Self(inputUID: inputUID, chain: chain, isRunning: isRunning, isMonitorEnabled: isMonitorEnabled)
    }
}

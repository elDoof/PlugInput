import Foundation

/// One position in the chain: a plugin, its saved settings, and whether it is bypassed.
///
/// The `id` is the slot's, not the plugin's. Two slots may hold the same `PluginDescriptor` —
/// a second instance of one EQ is a legitimate thing to want — and identifying a slot by its
/// contents would make those two indistinguishable. Identifying by *index* would be worse: the
/// index changes under every reorder, so a window or a state write aimed at index 1 would follow
/// the position rather than the plugin.
public struct PluginSlot: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let plugin: PluginDescriptor
    /// Binary plist of `auAudioUnit.fullState`, encoded by `PluginState`.
    public let state: Data?
    /// Live-switchable, unlike everything else here: bypass maps onto
    /// `auAudioUnit.shouldBypassEffect`, so toggling it needs no graph rebuild.
    public let isBypassed: Bool

    public init(id: UUID = UUID(), plugin: PluginDescriptor, state: Data? = nil, isBypassed: Bool = false) {
        self.id = id
        self.plugin = plugin
        self.state = state
        self.isBypassed = isBypassed
    }

    func with(state: Data?) -> Self {
        Self(id: id, plugin: plugin, state: state, isBypassed: isBypassed)
    }

    func with(isBypassed: Bool) -> Self {
        Self(id: id, plugin: plugin, state: state, isBypassed: isBypassed)
    }
}

/// An ordered chain of effects, as one immutable value.
///
/// Every operation returns a new chain; none mutates. That is what lets `AppModel` treat a chain
/// edit as "compute the next value, persist it, rebuild the graph" rather than as a sequence of
/// in-place changes that a failed rebuild would leave half-applied.
///
/// The invariant that mattered most in the single-slot design — a state blob must never outlive
/// or be separated from the plugin that produced it, because feeding one vendor's archive to
/// another's plugin takes the whole app down (gotcha #8) — is *structural* here. A slot's plugin
/// never changes; you remove the slot and add another. So there is no "drop the state when the
/// plugin changes" rule to maintain, and reordering carries each slot's settings with it for
/// free.
public struct PluginChain: Codable, Equatable, Sendable {
    public let slots: [PluginSlot]

    /// Plugins load in-process (gotcha #8), and each one adds latency and crash surface to a
    /// path that has to stay live under a voice. A cap keeps a runaway chain from making the app
    /// unusable in a way that looks like a bug; eight is well past any sane vocal chain.
    public static let maximumSlots = 8

    public static let empty = PluginChain(slots: [])

    public init(slots: [PluginSlot]) {
        self.slots = Array(slots.prefix(Self.maximumSlots))
    }

    public var isEmpty: Bool { slots.isEmpty }
    public var isFull: Bool { slots.count >= Self.maximumSlots }

    public func slot(_ id: UUID) -> PluginSlot? {
        slots.first { $0.id == id }
    }

    /// Appends, so the chain reads top-to-bottom in signal order. Refuses past the cap rather
    /// than trimming from the other end — silently dropping the user's first plugin to make room
    /// for their ninth would be a worse answer than declining.
    public func adding(_ plugin: PluginDescriptor) -> Self {
        guard !isFull else { return self }
        return Self(slots: slots + [PluginSlot(plugin: plugin)])
    }

    public func removing(_ id: UUID) -> Self {
        Self(slots: slots.filter { $0.id != id })
    }

    /// Moves a slot by `offset` positions. Out-of-range moves return the chain unchanged rather
    /// than trapping: the UI disables the buttons at the ends, but the type must not depend on
    /// the UI getting that right.
    public func moving(_ id: UUID, by offset: Int) -> Self {
        guard let from = slots.firstIndex(where: { $0.id == id }) else { return self }
        let to = from + offset
        guard offset != 0, to >= 0, to < slots.count else { return self }

        var reordered = slots
        let slot = reordered.remove(at: from)
        reordered.insert(slot, at: to)
        return Self(slots: reordered)
    }

    public func settingBypass(_ isBypassed: Bool, for id: UUID) -> Self {
        updating(id) { $0.with(isBypassed: isBypassed) }
    }

    public func settingState(_ state: Data?, for id: UUID) -> Self {
        updating(id) { $0.with(state: state) }
    }

    /// Folds a whole set of captured states in at once — one write per autosave rather than one
    /// per plugin, which keeps `session.json` internally consistent even mid-chain.
    public func settingStates(_ states: [UUID: Data]) -> Self {
        Self(slots: slots.map { slot in
            states[slot.id].map { slot.with(state: $0) } ?? slot
        })
    }

    private func updating(_ id: UUID, _ transform: (PluginSlot) -> PluginSlot) -> Self {
        Self(slots: slots.map { $0.id == id ? transform($0) : $0 })
    }
}

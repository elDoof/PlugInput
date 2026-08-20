import CoreAudio
import Foundation

/// Where each subdevice's channels land inside the aggregate's flattened channel list.
///
/// An aggregate concatenates its subdevices' channels in subdevice-list order, so these
/// offsets are what the output channel map is built from. The spike checks the assumption
/// by comparing `totalOutputChannels` against the count CoreAudio actually reports.
struct AggregateChannelLayout {
    let inputOffsets: [String: Int]
    let outputOffsets: [String: Int]
    let totalInputChannels: Int
    let totalOutputChannels: Int

    init(orderedSubDevices: [AudioDevice]) {
        var inputOffsets: [String: Int] = [:]
        var outputOffsets: [String: Int] = [:]
        var inputCursor = 0
        var outputCursor = 0

        for device in orderedSubDevices {
            inputOffsets[device.uid] = inputCursor
            outputOffsets[device.uid] = outputCursor
            inputCursor += device.inputChannels
            outputCursor += device.outputChannels
        }

        self.inputOffsets = inputOffsets
        self.outputOffsets = outputOffsets
        self.totalInputChannels = inputCursor
        self.totalOutputChannels = outputCursor
    }
}

/// Tracks every live aggregate so exit paths can tear them down.
///
/// `atexit` handlers and signal sources run outside the main actor, so they cannot reach a
/// main-actor-isolated `AggregateDevice`. Holding the raw IDs here keeps cleanup reachable
/// from any context — which matters because an orphaned aggregate outlives the process and
/// lingers in the user's audio settings.
enum AggregateRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var liveIDs: Set<AudioObjectID> = []

    static func register(_ id: AudioObjectID) {
        lock.lock()
        defer { lock.unlock() }
        liveIDs.insert(id)
    }

    static func destroy(_ id: AudioObjectID) {
        lock.lock()
        let wasLive = liveIDs.remove(id) != nil
        lock.unlock()
        guard wasLive else { return }
        destroyUntracked(id)
    }

    /// Drops an ID from tracking without destroying it — for one already destroyed by other
    /// means, so later teardown does not try again on an ID CoreAudio may have reused.
    static func forget(_ id: AudioObjectID) {
        lock.lock()
        defer { lock.unlock() }
        liveIDs.remove(id)
    }

    static func destroyAll() {
        lock.lock()
        let ids = liveIDs
        liveIDs.removeAll()
        lock.unlock()
        ids.forEach(destroyUntracked)
    }

    private static func destroyUntracked(_ id: AudioObjectID) {
        let status = AudioHardwareDestroyAggregateDevice(id)
        if status != noErr {
            // Through the unified log, not stderr. This came across from the spike with the rest
            // of the file, and stderr from a Finder-launched `.app` goes nowhere — so the one
            // failure the user most needs a record of (an orphaned aggregate, gotcha #7, which
            // then blocks every future start per gotcha #20) was the one leaving no trace.
            EngineLog.logger.error(
                "could not destroy aggregate \(id, privacy: .public): OSStatus \(status, privacy: .public)"
            )
        }
    }
}

/// A private aggregate device owned by this process.
///
/// `kAudioAggregateDeviceIsPrivateKey` keeps it out of the user's device list — it never
/// shows up in Audio MIDI Setup or the menu bar. Its subdevices stay ordinary system
/// devices, which is what should let other apps keep reading the loopback while we drive it.
final class AggregateDevice {
    let id: AudioObjectID
    let uid: String
    let subDevices: [AudioDevice]
    let layout: AggregateChannelLayout

    private var isDestroyed = false

    init(
        uid: String,
        name: String,
        subDevices: [AudioDevice],
        clockSourceUID: String,
        isPrivate: Bool = true
    ) throws {
        precondition(!subDevices.isEmpty, "an aggregate needs at least one subdevice")

        let subDeviceEntries: [[String: Any]] = subDevices.map { device in
            [
                kAudioSubDeviceUIDKey as String: device.uid,
                // Drift-correct everything except the clock master; correcting the master
                // would fight the very clock we chose to follow.
                kAudioSubDeviceDriftCompensationKey as String: device.uid == clockSourceUID ? 0 : 1,
            ]
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceNameKey as String: name,
            kAudioAggregateDeviceIsPrivateKey as String: isPrivate ? 1 : 0,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: clockSourceUID,
            kAudioAggregateDeviceSubDeviceListKey as String: subDeviceEntries,
        ]

        // Reclaim a stale aggregate carrying this UID before asking for a new one.
        //
        // Load-bearing regardless of visibility. An aggregate outlives a process that exits
        // without running its teardown — a crash, a force quit, `killall` — and CoreAudio then
        // refuses to create another with the same UID, failing **every subsequent start** with
        // `OSStatus 1852797029 ('nope')`. Without this the app is bricked until the user finds
        // and deletes the device by hand, which is not something a user can be expected to know
        // how to do. (This was first hit while the device was briefly public, which is why the
        // note here used to say it only mattered then. It applies to the private one too.)
        Self.destroyStale(uid: uid)

        var createdID = AudioObjectID(0)
        try checkStatus(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdID),
            "AudioHardwareCreateAggregateDevice"
        )
        guard createdID != AudioObjectID(0) else {
            throw CoreAudioError.status(-1, context: "aggregate device created with id 0")
        }

        self.id = createdID
        self.uid = uid
        self.subDevices = subDevices
        self.layout = AggregateChannelLayout(orderedSubDevices: subDevices)
        AggregateRegistry.register(createdID)
    }

    /// Destroys any device already published under `uid`, so a leftover cannot block creation.
    ///
    /// Best-effort by design: if the lookup or the destroy fails, `init` continues and lets
    /// `AudioHardwareCreateAggregateDevice` report the real error rather than masking it.
    private static func destroyStale(uid: String) {
        guard let existing = try? DeviceEnumerator.device(uid: uid) else { return }

        // Confirm it really is an aggregate before destroying it. Nothing else should ever
        // claim our UID, so this should always pass — but "should" is doing a lot of work in a
        // call that hands a device ID to `AudioHardwareDestroyAggregateDevice`, and the cost of
        // being wrong is destroying a device belonging to something else. Cheap insurance.
        let transport = try? propertyValue(
            existing.id,
            address(kAudioDevicePropertyTransportType),
            initial: UInt32(0)
        )
        guard transport == kAudioDeviceTransportTypeAggregate else {
            EngineLog.logger.error(
                """
                device holding \(uid, privacy: .public) is not an aggregate \
                (transport \(transport ?? 0, privacy: .public)) — leaving it alone
                """
            )
            return
        }

        let status = AudioHardwareDestroyAggregateDevice(existing.id)
        AggregateRegistry.forget(existing.id)
        EngineLog.logger.info(
            """
            reclaimed stale aggregate \(uid, privacy: .public) \
            (id \(existing.id, privacy: .public)): OSStatus \(status, privacy: .public)
            """
        )
    }

    /// Channel counts as CoreAudio actually reports them, for cross-checking `layout`.
    func reportedChannelCounts() throws -> (input: Int, output: Int) {
        (
            input: try channelCount(id, scope: kAudioObjectPropertyScopeInput),
            output: try channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    /// Idempotent — safe to call from a signal handler and again from `deinit`.
    /// Leaving an orphaned aggregate behind is the classic failure mode for this kind of
    /// app, so every exit path must reach this or `AggregateRegistry.destroyAll()`.
    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        AggregateRegistry.destroy(id)
    }

    deinit { destroy() }
}

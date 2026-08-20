import Foundation
import Testing

@testable import AudioCore

/// Persistence is the part of task #6 that *is* pure: snapshot transitions, plist encoding of a
/// plugin's `fullState`, and reading a file back. Instantiating a real Audio Unit and asking it
/// for its state is hardware- and vendor-dependent and stays out of here.

private let compressor = PluginDescriptor(
    name: "Compressor",
    manufacturer: "Vendor A",
    componentType: 1_635_083_896,
    componentSubType: 2,
    componentManufacturer: 3
)

private let reverb = PluginDescriptor(
    name: "Reverb",
    manufacturer: "Vendor B",
    componentType: 1_635_083_896,
    componentSubType: 9,
    componentManufacturer: 4
)

@Suite("Monitor toggle persistence")
struct MonitorToggleTests {
    @Test("monitoring is on by default")
    func defaultsToEnabled() {
        #expect(SessionSnapshot.empty.isMonitorEnabled)
    }

    @Test("toggling the monitor leaves every other field alone")
    func togglingIsNarrow() {
        // Arrange
        let original = SessionSnapshot.empty
            .settingInput("mic-uid")
            .settingChain(PluginChain.empty.adding(compressor))
            .settingRunning(true)

        // Act
        let muted = original.settingMonitorEnabled(false)

        // Assert — immutability, and no collateral damage to the chain or its settings.
        #expect(original.isMonitorEnabled)
        #expect(muted.isMonitorEnabled == false)
        #expect(muted.inputUID == "mic-uid")
        #expect(muted.chain.slots.map(\.plugin) == [compressor])
        #expect(muted.isRunning)
    }

    @Test("a session file written before the toggle existed still loads, monitoring enabled")
    func legacyFileDecodesWithMonitoringOn() throws {
        // Arrange — exactly the shape already on disk in ~/Library/Application Support:
        // no isMonitorEnabled key at all. A non-optional Codable property would make this
        // throw, and the app would report "Saved settings could not be read" on next launch.
        let legacy = Data("""
        {
          "inputUID" : "BuiltInMicrophoneDevice",
          "isRunning" : true,
          "plugin" : {
            "name" : "Compressor",
            "manufacturer" : "Vendor A",
            "componentType" : 1635083896,
            "componentSubType" : 2,
            "componentManufacturer" : 3
          }
        }
        """.utf8)

        // Act
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: legacy)

        // Assert — the saved settings survive, and the absent field takes the safe default.
        #expect(decoded.inputUID == "BuiltInMicrophoneDevice")
        #expect(decoded.chain.slots.map(\.plugin) == [compressor])
        #expect(decoded.isRunning)
        #expect(decoded.isMonitorEnabled)
    }

    @Test("the toggle survives a round trip through JSON")
    func roundTripsThroughJSON() throws {
        let muted = SessionSnapshot.empty.settingMonitorEnabled(false)

        let data = try JSONEncoder().encode(muted)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        #expect(decoded.isMonitorEnabled == false)
    }
}

@Suite("Session snapshot transitions")
struct SessionSnapshotTests {
    @Test("updaters return new values and leave the original untouched")
    func updatersAreImmutable() {
        // Arrange
        let original = SessionSnapshot.empty

        // Act
        let updated = original.settingInput("mic-uid").settingRunning(true)

        // Assert
        #expect(original.inputUID == nil)
        #expect(original.isRunning == false)
        #expect(updated.inputUID == "mic-uid")
        #expect(updated.isRunning)
    }

    @Test("a session file from before the chain existed loads as a one-slot chain")
    func preChainFileMigrates() throws {
        // Arrange — the single-slot format, exactly as written to disk before this change:
        // a `plugin` object and a `pluginState` blob, with no `chain` key at all.
        let legacy = Data("""
        {
          "inputUID" : "BuiltInMicrophoneDevice",
          "isRunning" : true,
          "isMonitorEnabled" : false,
          "plugin" : {
            "name" : "Compressor",
            "manufacturer" : "Vendor A",
            "componentType" : 1635083896,
            "componentSubType" : 2,
            "componentManufacturer" : 3
          },
          "pluginState" : "AQID"
        }
        """.utf8)

        // Act
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: legacy)

        // Assert — the plugin *and* its dial positions survive the upgrade. Dropping the state
        // here would silently reset the user's compressor on the launch after they update.
        #expect(decoded.chain.slots.count == 1)
        #expect(decoded.chain.slots[0].plugin == compressor)
        #expect(decoded.chain.slots[0].state == Data([0x01, 0x02, 0x03]))
        #expect(decoded.chain.slots[0].isBypassed == false)
        #expect(decoded.inputUID == "BuiltInMicrophoneDevice")
        #expect(decoded.isRunning)
        #expect(decoded.isMonitorEnabled == false)
    }

    @Test("a pre-chain file with no plugin loads as an empty chain")
    func preChainFileWithoutPluginMigrates() throws {
        let legacy = Data("""
        { "inputUID" : "mic-uid", "isRunning" : false }
        """.utf8)

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: legacy)

        #expect(decoded.chain.isEmpty)
        #expect(decoded.inputUID == "mic-uid")
    }

    @Test("a chain survives a round trip through JSON with slot identity intact")
    func chainRoundTripsThroughJSON() throws {
        // Arrange — slot ids are what tie a saved slot to its open window and its live unit, so
        // they have to come back the same, not merely equivalent.
        let chain = PluginChain.empty
            .adding(compressor)
            .adding(reverb)
        let saved = SessionSnapshot.empty
            .settingChain(chain.settingBypass(true, for: chain.slots[1].id))

        // Act
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        // Assert
        #expect(decoded == saved)
        #expect(decoded.chain.slots.map(\.id) == chain.slots.map(\.id))
        #expect(decoded.chain.slots[1].isBypassed)
    }

    @Test("replacing the chain leaves every other field alone")
    func settingChainIsNarrow() {
        // Arrange
        let original = SessionSnapshot.empty
            .settingInput("mic-uid")
            .settingRunning(true)
            .settingMonitorEnabled(false)

        // Act
        let updated = original.settingChain(PluginChain.empty.adding(reverb))

        // Assert
        #expect(original.chain.isEmpty)
        #expect(updated.chain.slots.map(\.plugin) == [reverb])
        #expect(updated.inputUID == "mic-uid")
        #expect(updated.isRunning)
        #expect(updated.isMonitorEnabled == false)
    }
}

@Suite("Plugin state encoding")
struct PluginStateTests {
    @Test("a fullState dictionary survives a plist round trip")
    func fullStateRoundTrips() throws {
        // Arrange — shaped like a real `auAudioUnit.fullState`: type/subtype/manufacturer keys
        // plus an opaque vendor blob.
        let state: [String: Any] = [
            "type": 1_635_083_896,
            "subtype": 2,
            "manufacturer": 3,
            "name": "Compressor",
            "data": Data([0xDE, 0xAD, 0xBE, 0xEF]),
            "nested": ["threshold": -18.5],
        ]

        // Act
        let encoded = try PluginState.encode(state)
        let decoded = try PluginState.decode(encoded)

        // Assert
        #expect(decoded["name"] as? String == "Compressor")
        #expect(decoded["subtype"] as? Int == 2)
        #expect(decoded["data"] as? Data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect((decoded["nested"] as? [String: Any])?["threshold"] as? Double == -18.5)
    }

    @Test("decoding garbage throws instead of returning an empty state")
    func decodingGarbageThrows() {
        // Silently returning [:] here would push a blank state into a plugin and read as
        // "my settings were lost" with no explanation.
        #expect(throws: (any Error).self) {
            try PluginState.decode(Data("not a plist".utf8))
        }
    }
}

@Suite("Session store")
struct SessionStoreTests {
    private func temporaryStore() -> SessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PlugInputTests-\(UUID().uuidString)")
        return SessionStore(fileURL: directory.appending(path: "session.json"))
    }

    @Test("a saved snapshot reads back identically")
    func saveThenLoadRoundTrips() throws {
        // Arrange
        let store = temporaryStore()
        let chain = PluginChain.empty.adding(compressor)
        let snapshot = SessionSnapshot.empty
            .settingInput("mic-uid")
            .settingChain(chain.settingState(Data([0x01, 0x02, 0x03]), for: chain.slots[0].id))
            .settingRunning(true)

        // Act
        try store.save(snapshot)
        let loaded = try store.load()

        // Assert
        #expect(loaded == snapshot)

        try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
    }

    @Test("a missing file is a first launch, not an error")
    func missingFileLoadsNil() throws {
        let store = temporaryStore()

        #expect(try store.load() == nil)
    }

    @Test("a corrupt file throws rather than silently resetting the session")
    func corruptFileThrows() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: store.fileURL)

        #expect(throws: (any Error).self) {
            try store.load()
        }

        try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
    }

    @Test("saving creates the containing directory")
    func saveCreatesDirectory() throws {
        let store = temporaryStore()

        try store.save(.empty)

        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
    }
}

/// The input channel is the newest field, and the one most able to break an existing setup.
///
/// It exists because the engine used to capture the input device's *first* channel and only
/// ever that one — right for a built-in microphone, and exact digital silence for anyone whose
/// mic is on input 2 of an interface, with the UI blaming microphone permissions. Two things
/// have to hold: every session file written before the field existed must still load, and a
/// channel must never outlive the device it was chosen on.
@Suite("Input channel persistence")
struct InputChannelTests {
    @Test("the first channel is the default")
    func defaultsToFirstChannel() {
        #expect(SessionSnapshot.empty.inputChannel == 0)
    }

    @Test("a session file written before the field existed loads on channel one")
    func legacyFileDecodesToFirstChannel() throws {
        // Arrange — no inputChannel key at all. A non-optional Codable property would throw
        // here, and AppModel answers a failed load by discarding the whole session, so this is
        // the difference between an upgrade and a wiped setup.
        let legacy = Data("""
        {
          "inputUID" : "BuiltInMicrophoneDevice",
          "isRunning" : true,
          "isMonitorEnabled" : false,
          "chain" : { "slots" : [] }
        }
        """.utf8)

        // Act
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: legacy)

        // Assert — the new field defaults, and nothing else is disturbed by its absence.
        #expect(decoded.inputChannel == 0)
        #expect(decoded.inputUID == "BuiltInMicrophoneDevice")
        #expect(decoded.isRunning)
        #expect(decoded.isMonitorEnabled == false)
    }

    @Test("a chosen channel survives a save and load")
    func roundTrips() throws {
        // Arrange
        let original = SessionSnapshot.empty
            .settingInput("interface-uid")
            .settingInputChannel(2)

        // Act
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        // Assert
        #expect(decoded.inputChannel == 2)
        #expect(decoded.inputUID == "interface-uid")
    }

    @Test("changing the input device resets the channel")
    func changingDeviceResetsChannel() {
        // Arrange — mic on input 3 of an eight-input interface.
        let onInterface = SessionSnapshot.empty
            .settingInput("interface-uid")
            .settingInputChannel(2)

        // Act — the interface is unplugged and the fallback is a mono built-in mic.
        let onBuiltIn = onInterface.settingInput("builtin-uid")

        // Assert — carrying channel 3 across would refuse every start with "channel 3 does not
        // exist", which is a saved setting breaking a device it was never about.
        #expect(onInterface.inputChannel == 2)
        #expect(onBuiltIn.inputChannel == 0)
    }

    @Test("re-selecting the same device keeps the channel")
    func reselectingSameDeviceKeepsChannel() {
        // The reset must key on the device actually changing. `refresh()` re-applies the
        // resolved input on every menu open, and if that counted as a change the user's channel
        // would silently snap back to 1 each time they looked at the menu.
        let original = SessionSnapshot.empty
            .settingInput("interface-uid")
            .settingInputChannel(3)

        let same = original.settingInput("interface-uid")

        #expect(same.inputChannel == 3)
    }

    @Test("setting the channel leaves every other field alone")
    func settingChannelIsNarrow() {
        // Arrange
        let original = SessionSnapshot.empty
            .settingInput("interface-uid")
            .settingChain(PluginChain.empty.adding(compressor))
            .settingRunning(true)
            .settingMonitorEnabled(false)

        // Act
        let updated = original.settingInputChannel(1)

        // Assert — immutability, and no collateral damage to the chain or its settings.
        #expect(original.inputChannel == 0)
        #expect(updated.inputChannel == 1)
        #expect(updated.inputUID == "interface-uid")
        #expect(updated.chain.slots.map(\.plugin) == [compressor])
        #expect(updated.isRunning)
        #expect(updated.isMonitorEnabled == false)
    }
}

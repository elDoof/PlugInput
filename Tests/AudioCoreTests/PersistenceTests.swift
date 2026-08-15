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
            .settingPlugin(compressor)
            .settingRunning(true)

        // Act
        let muted = original.settingMonitorEnabled(false)

        // Assert — immutability, and no collateral damage to the plugin or its state.
        #expect(original.isMonitorEnabled)
        #expect(muted.isMonitorEnabled == false)
        #expect(muted.inputUID == "mic-uid")
        #expect(muted.plugin == compressor)
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
        #expect(decoded.plugin == compressor)
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

    @Test("selecting a different plugin discards the previous plugin's state")
    func switchingPluginDiscardsState() {
        // A state blob is only meaningful to the plugin that produced it. Handing Vendor A's
        // archive to Vendor B's plugin is, in-process, a plausible way to crash the host.
        let saved = SessionSnapshot.empty
            .settingPlugin(compressor)
            .settingPluginState(Data([0x01, 0x02]))

        let switched = saved.settingPlugin(reverb)

        #expect(saved.pluginState != nil)
        #expect(switched.plugin == reverb)
        #expect(switched.pluginState == nil)
    }

    @Test("re-selecting the same plugin keeps its state")
    func reselectingSamePluginKeepsState() {
        let saved = SessionSnapshot.empty
            .settingPlugin(compressor)
            .settingPluginState(Data([0x01]))

        let same = saved.settingPlugin(compressor)

        #expect(same.pluginState == Data([0x01]))
    }

    @Test("clearing the plugin clears its state")
    func clearingPluginClearsState() {
        let saved = SessionSnapshot.empty
            .settingPlugin(compressor)
            .settingPluginState(Data([0x01]))

        let cleared = saved.settingPlugin(nil)

        #expect(cleared.plugin == nil)
        #expect(cleared.pluginState == nil)
    }

    @Test("state cannot be attached without a plugin to own it")
    func stateWithoutPluginIsIgnored() {
        let orphaned = SessionSnapshot.empty.settingPluginState(Data([0x01]))

        #expect(orphaned.pluginState == nil)
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
        let snapshot = SessionSnapshot.empty
            .settingInput("mic-uid")
            .settingPlugin(compressor)
            .settingPluginState(Data([0x01, 0x02, 0x03]))
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

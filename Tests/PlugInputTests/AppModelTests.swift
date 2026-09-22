import AVFoundation
@testable import AudioCore
import Foundation
import Testing
@testable import PlugInput

@MainActor
private final class Loader {
    var pending: [CheckedContinuation<AVAudioUnit, any Error>] = []
    func load(_ descriptor: PluginDescriptor) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ index: Int) { pending[index].resume(returning: AVAudioUnitEQ(numberOfBands: 1)) }
    func fail(_ index: Int) { pending[index].resume(throwing: CocoaError(.fileReadUnknown)) }
    func waitFor(_ count: Int) async {
        while pending.count < count { await Task.yield() }
    }
}

@Suite("App model plugin coordination")
@MainActor
struct AppModelTests {
    private func descriptor(_ name: String) -> PluginDescriptor {
        PluginDescriptor(name: name, manufacturer: "Test", componentType: 1,
                         componentSubType: 1, componentManufacturer: 1)
    }
    private func store() -> SessionStore {
        SessionStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "PlugInputTests-\(UUID()).json"))
    }

    @Test func overlappingAddsPreserveOrderAndEdits() async throws {
        let loader = Loader()
        let store = store()
        defer { try? store.clear() }
        let model = AppModel(store: store, startServices: false, pluginLoader: loader.load)
        let first = Task { await model.addPlugin(descriptor("First")) }
        await loader.waitFor(1)
        let firstID = try #require(model.chain.slots.first?.id)
        let second = Task { await model.addPlugin(descriptor("Second")) }
        await loader.waitFor(2)
        model.setBypass(true, for: firstID)
        loader.finish(1)
        await second.value
        loader.finish(0)
        await first.value
        #expect(model.chain.slots.map(\.plugin.name) == ["First", "Second"])
        #expect(model.loadedUnits.count == 2)
        #expect(model.loadedUnits[firstID]?.auAudioUnit.shouldBypassEffect == true)
        #expect(try store.load()?.chain == model.chain)
    }

    @Test func removalDuringLoadDoesNotResurrectSlot() async throws {
        let loader = Loader()
        let store = store()
        defer { try? store.clear() }
        let model = AppModel(store: store, startServices: false, pluginLoader: loader.load)
        let task = Task { await model.addPlugin(descriptor("Removed")) }
        await loader.waitFor(1)
        await model.removeSlot(try #require(model.chain.slots.first?.id))
        loader.finish(0)
        await task.value
        #expect(model.chain.isEmpty)
        #expect(model.loadedUnits.isEmpty)
    }

    @Test func failedRestorePreservesPresetAndCanRetry() async throws {
        let loader = Loader()
        let store = store()
        defer { try? store.clear() }
        let state = try PropertyListSerialization.data(fromPropertyList: ["test": 1], format: .binary, options: 0)
        let slot = PluginSlot(plugin: descriptor("Saved"), state: state, isBypassed: true)
        let saved = PluginChain(slots: [slot])
        try store.save(SessionSnapshot(inputUID: nil, chain: saved, isRunning: false))
        let model = AppModel(store: store, startServices: false, pluginLoader: loader.load)
        let restore = Task { await model.loadChain(saved) }
        await loader.waitFor(1)
        loader.fail(0)
        await restore.value
        #expect(model.chain == saved)
        #expect(try store.load()?.chain == saved)
        #expect(model.pluginFailures[slot.id] != nil)
        let retry = Task { await model.retryPlugin(slot.id) }
        await loader.waitFor(2)
        loader.finish(1)
        await retry.value
        #expect(model.loadedUnits[slot.id] != nil)
        #expect(model.pluginFailures[slot.id] == nil)
        #expect(model.chain.slot(slot.id)?.state == state)
    }

    @Test func editsDuringRestoreSurviveCompletion() async throws {
        let loader = Loader()
        let store = store()
        defer { try? store.clear() }
        let saved = PluginChain(slots: [PluginSlot(plugin: descriptor("Saved"))])
        try store.save(SessionSnapshot(inputUID: nil, chain: saved, isRunning: false))
        let model = AppModel(store: store, startServices: false, pluginLoader: loader.load)
        let restore = Task { await model.loadChain(saved) }
        await loader.waitFor(1)
        await model.removeSlot(saved.slots[0].id)
        loader.finish(0)
        await restore.value
        #expect(model.chain.isEmpty)
        #expect(try store.load()?.chain.isEmpty == true)
        #expect(model.loadedUnits.isEmpty)
    }
}

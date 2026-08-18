import Foundation
import Testing

@testable import AudioCore

/// The chain is a value, and these tests exist to keep it one.
///
/// Two properties carry the design. Slots are identified by their own id rather than by their
/// plugin, because loading the same EQ twice is legitimate and index-based identity breaks the
/// moment anything is reordered. And a slot's saved state belongs to the slot's own plugin —
/// structurally, since a slot's plugin never changes; you remove and add instead. That is what
/// replaces `SessionSnapshot`'s hand-maintained "drop the state whenever the plugin changes"
/// rule, and it is why growing one slot into a chain did not grow that invariant with it.
private func descriptor(_ name: String, subType: OSType = 1) -> PluginDescriptor {
    PluginDescriptor(
        name: name,
        manufacturer: "FabFilter",
        componentType: 1_635_083_896,
        componentSubType: subType,
        componentManufacturer: 1_097_756_514
    )
}

private let proL = descriptor("Pro-L 2", subType: 1)
private let saturn = descriptor("Saturn 2", subType: 2)
private let timeless = descriptor("Timeless 3", subType: 3)

@Suite("Plugin chain")
struct PluginChainTests {
    @Test("adding appends to the end, so the chain reads in signal order")
    func addingAppends() {
        // Arrange
        let chain = PluginChain.empty

        // Act
        let grown = chain.adding(proL).adding(saturn)

        // Assert
        #expect(grown.slots.map(\.plugin) == [proL, saturn])
    }

    @Test("adding does not mutate the chain it was called on")
    func addingIsImmutable() {
        // Arrange
        let original = PluginChain.empty.adding(proL)

        // Act
        _ = original.adding(saturn)

        // Assert
        #expect(original.slots.count == 1)
    }

    @Test("the same plugin can be added twice, as two independent slots")
    func allowsDuplicatePlugins() {
        // Arrange / Act — two instances of one EQ is a real thing to want.
        let chain = PluginChain.empty.adding(proL).adding(proL)

        // Assert
        #expect(chain.slots.count == 2)
        #expect(chain.slots[0].id != chain.slots[1].id)
    }

    @Test("adding beyond the cap leaves the chain unchanged")
    func refusesToExceedCap() {
        // Arrange — every slot is an in-process plugin adding latency and crash surface.
        var chain = PluginChain.empty
        for index in 0..<PluginChain.maximumSlots {
            chain = chain.adding(descriptor("Effect \(index)", subType: OSType(index)))
        }

        // Act
        let overfull = chain.adding(timeless)

        // Assert
        #expect(chain.isFull)
        #expect(overfull.slots.count == PluginChain.maximumSlots)
        #expect(overfull == chain)
    }

    @Test("removing drops only the named slot")
    func removingDropsOneSlot() {
        // Arrange
        let chain = PluginChain.empty.adding(proL).adding(saturn).adding(timeless)
        let middle = chain.slots[1].id

        // Act
        let shortened = chain.removing(middle)

        // Assert
        #expect(shortened.slots.map(\.plugin) == [proL, timeless])
    }

    @Test("removing an unknown slot leaves the chain unchanged")
    func removingUnknownSlotIsNoOp() {
        // Arrange
        let chain = PluginChain.empty.adding(proL)

        // Act
        let result = chain.removing(UUID())

        // Assert
        #expect(result == chain)
    }

    @Test("moving a slot up swaps it with the one before it")
    func movingUpSwaps() {
        // Arrange
        let chain = PluginChain.empty.adding(proL).adding(saturn)

        // Act
        let reordered = chain.moving(chain.slots[1].id, by: -1)

        // Assert
        #expect(reordered.slots.map(\.plugin) == [saturn, proL])
    }

    @Test("moving a slot down swaps it with the one after it")
    func movingDownSwaps() {
        // Arrange
        let chain = PluginChain.empty.adding(proL).adding(saturn)

        // Act
        let reordered = chain.moving(chain.slots[0].id, by: 1)

        // Assert
        #expect(reordered.slots.map(\.plugin) == [saturn, proL])
    }

    @Test("moving past either end is a no-op rather than an error")
    func movingPastTheEndsIsClamped() {
        // Arrange — the UI disables these buttons, but the type must not depend on that.
        let chain = PluginChain.empty.adding(proL).adding(saturn)

        // Act
        let up = chain.moving(chain.slots[0].id, by: -1)
        let down = chain.moving(chain.slots[1].id, by: 1)

        // Assert
        #expect(up == chain)
        #expect(down == chain)
    }

    @Test("moving carries the slot's state and bypass with it")
    func movingCarriesSlotContents() {
        // Arrange — reordering must not shuffle settings between plugins.
        let chain = PluginChain.empty.adding(proL).adding(saturn)
        let saturnID = chain.slots[1].id
        let dialled = chain
            .settingState(Data([0x01, 0x02]), for: saturnID)
            .settingBypass(true, for: saturnID)

        // Act
        let reordered = dialled.moving(saturnID, by: -1)

        // Assert
        let moved = reordered.slots[0]
        #expect(moved.plugin == saturn)
        #expect(moved.state == Data([0x01, 0x02]))
        #expect(moved.isBypassed)
    }

    @Test("bypass applies to one slot and leaves its neighbours alone")
    func bypassIsPerSlot() {
        // Arrange
        let chain = PluginChain.empty.adding(proL).adding(saturn)

        // Act
        let bypassed = chain.settingBypass(true, for: chain.slots[0].id)

        // Assert
        #expect(bypassed.slots[0].isBypassed)
        #expect(!bypassed.slots[1].isBypassed)
    }

    @Test("a new slot starts active and without saved state")
    func newSlotsStartClean() {
        // Arrange / Act
        let slot = PluginChain.empty.adding(proL).slots[0]

        // Assert
        #expect(!slot.isBypassed)
        #expect(slot.state == nil)
    }

    @Test("state is attached to the slot that owns it")
    func stateBelongsToItsSlot() {
        // Arrange
        let chain = PluginChain.empty.adding(proL).adding(saturn)

        // Act
        let saved = chain.settingState(Data([0xFF]), for: chain.slots[1].id)

        // Assert — a state blob is meaningless to a different plugin (gotcha #8).
        #expect(saved.slots[0].state == nil)
        #expect(saved.slots[1].state == Data([0xFF]))
    }
}

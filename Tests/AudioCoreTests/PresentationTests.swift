import CoreAudioTypes
import Testing

@testable import AudioCore

/// The pure half of the UI work: choosing which of 677 plugins to show, and turning a linear
/// peak into something a person can read. Both are logic, so both are tested here rather than
/// eyeballed in a running app.

private func plugin(_ name: String, by manufacturer: String, subType: OSType) -> PluginDescriptor {
    PluginDescriptor(
        name: name,
        manufacturer: manufacturer,
        componentType: 1_635_083_896,
        componentSubType: subType,
        componentManufacturer: 1
    )
}

private let library = [
    plugin("Pro-C 2", by: "FabFilter", subType: 1),
    plugin("Pro-Q 3", by: "FabFilter", subType: 2),
    plugin("soothe2", by: "oeksound", subType: 3),
    plugin("Ozone 12 Dynamics", by: "iZotope", subType: 4),
]

@Suite("Plugin search")
struct PluginSearchTests {
    @Test("an empty query returns the whole library")
    func emptyQueryReturnsEverything() {
        #expect(PluginSearch.matches(query: "", in: library).count == 4)
        #expect(PluginSearch.matches(query: "   ", in: library).count == 4)
    }

    @Test("matches on plugin name, ignoring case")
    func matchesName() {
        let results = PluginSearch.matches(query: "pro-q", in: library)

        #expect(results.map(\.name) == ["Pro-Q 3"])
    }

    @Test("matches on manufacturer, so a vendor's whole range can be found at once")
    func matchesManufacturer() {
        let results = PluginSearch.matches(query: "fabfilter", in: library)

        #expect(results.count == 2)
    }

    @Test("every whitespace-separated term must match, in any order")
    func allTermsMustMatch() {
        // "izotope dynamics" should find the Ozone module even though the words are apart and
        // reversed relative to the display name.
        #expect(PluginSearch.matches(query: "izotope dynamics", in: library).count == 1)
        #expect(PluginSearch.matches(query: "fabfilter soothe", in: library).isEmpty)
    }

    @Test("a query matching nothing returns nothing rather than everything")
    func noMatches() {
        // Falling back to the full list here would look like the filter silently failing.
        #expect(PluginSearch.matches(query: "zzzz", in: library).isEmpty)
    }
}

@Suite("Audio level")
struct AudioLevelTests {
    @Test("full scale is 0 dBFS and half amplitude is about -6")
    func decibelsFromAmplitude() {
        #expect(AudioLevel.decibels(fromAmplitude: 1.0) == 0)
        #expect(abs(AudioLevel.decibels(fromAmplitude: 0.5) - -6.02) < 0.01)
    }

    @Test("silence reports the floor instead of negative infinity")
    func silenceIsFloored() {
        // -inf would render as garbage in the UI and break any bar drawn from it.
        #expect(AudioLevel.decibels(fromAmplitude: 0) == AudioLevel.floorDecibels)
        #expect(AudioLevel.decibels(fromAmplitude: -0.5) == AudioLevel.floorDecibels)
    }

    @Test("meter fraction spans the floor to full scale")
    func meterFraction() {
        #expect(AudioLevel.meterFraction(fromAmplitude: 1.0) == 1)
        #expect(AudioLevel.meterFraction(fromAmplitude: 0) == 0)

        // −6.02 dBFS on a −60...0 scale is (−6.02 + 60) / 60.
        let half = AudioLevel.meterFraction(fromAmplitude: 0.5)
        #expect(abs(half - 0.8997) < 0.001, "−6 dBFS should sit near the top of a −60 dB scale")
    }
}

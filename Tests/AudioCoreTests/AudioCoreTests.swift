import AVFoundation
import CoreAudio
import Testing

@testable import AudioCore

/// These cover the pieces that are genuinely testable without hardware: channel-offset
/// arithmetic and subdevice ordering. Both are what the channel maps are computed from, and
/// both are easy to get subtly wrong in ways that produce silence rather than a crash.
///
/// The CoreAudio and AVAudioEngine binding code is not meaningfully unit-testable; it is
/// covered by the Phase 0 spike's two-process tone test instead.

private func device(
    id: AudioObjectID,
    uid: String,
    name: String,
    inputChannels: Int,
    outputChannels: Int
) -> AudioDevice {
    AudioDevice(
        id: id,
        uid: uid,
        name: name,
        inputChannels: inputChannels,
        outputChannels: outputChannels
    )
}

private let mic = device(id: 1, uid: "mic", name: "Built-in Mic", inputChannels: 1, outputChannels: 0)
private let blackHole = device(id: 2, uid: "bh", name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2)
private let speakers = device(id: 3, uid: "spk", name: "Speakers", inputChannels: 0, outputChannels: 2)
private let interface = device(id: 4, uid: "if", name: "Interface", inputChannels: 2, outputChannels: 2)

@Suite("Aggregate channel layout")
struct AggregateChannelLayoutTests {
    @Test("offsets accumulate in subdevice order")
    func offsetsFollowSubdeviceOrder() {
        // Arrange
        let ordered = [mic, blackHole, speakers]

        // Act
        let layout = AggregateChannelLayout(orderedSubDevices: ordered)

        // Assert — matches what CoreAudio reported on real hardware in Phase 0: in 3, out 4.
        #expect(layout.totalInputChannels == 3)
        #expect(layout.totalOutputChannels == 4)
        #expect(layout.inputOffsets["mic"] == 0)
        #expect(layout.inputOffsets["bh"] == 1)
        #expect(layout.outputOffsets["bh"] == 0)
        #expect(layout.outputOffsets["spk"] == 2)
    }

    @Test("devices with no channels in a direction do not advance that cursor")
    func zeroChannelDevicesDoNotAdvanceCursor() {
        let layout = AggregateChannelLayout(orderedSubDevices: [mic, speakers])

        // The mic contributes no output channels, so speakers still start at output 0.
        #expect(layout.outputOffsets["mic"] == 0)
        #expect(layout.outputOffsets["spk"] == 0)
        #expect(layout.totalOutputChannels == 2)
    }

    @Test("empty subdevice list yields an empty layout")
    func emptyLayout() {
        let layout = AggregateChannelLayout(orderedSubDevices: [])

        #expect(layout.totalInputChannels == 0)
        #expect(layout.totalOutputChannels == 0)
        #expect(layout.inputOffsets.isEmpty)
    }
}

/// Subdevice order decides every channel-map offset, so it is pinned here.
///
/// The input device leads. Leading with the *virtual* device was tried — it would have let
/// other apps select the aggregate directly as a "PlugInput" microphone, reading the processed
/// signal off input channels 0–1 — and it does not work: `AVAudioEngine`'s input node reports
/// only 2 channels regardless of the aggregate's real 7, so the resulting input channel map
/// indexes out of that range and `engine.start()` fails with
/// `IsFormatSampleRateAndChannelCountValid`. Gotcha #19 has the measurements. These tests
/// therefore pin the working order deliberately, not incidentally.
@Suite("Subdevice ordering")
struct OrderedSubDevicesTests {
    @Test("three distinct devices keep input, virtual, monitor order")
    func threeDistinctDevices() {
        let ordered = AudioEngineController.orderedSubDevices(
            input: mic,
            virtual: blackHole,
            monitor: speakers
        )

        #expect(ordered.map(\.uid) == ["mic", "bh", "spk"])
    }

    @Test("the input device's channel offset is zero for every device combination")
    func inputOffsetIsAlwaysZero() {
        // Load-bearing: an input channel map indexing past the input node's 2-channel view is
        // accepted by CoreAudio, reads back correctly, and then kills the start (gotcha #19).
        // Keeping the input first is what holds its offset inside that range.
        for (input, monitor) in [(mic, speakers), (interface, interface), (interface, speakers)] {
            let ordered = AudioEngineController.orderedSubDevices(
                input: input,
                virtual: blackHole,
                monitor: monitor
            )
            let layout = AggregateChannelLayout(orderedSubDevices: ordered)

            #expect(layout.inputOffsets[input.uid] == 0)
        }
    }

    @Test("monitor identical to input collapses to two subdevices")
    func monitorEqualsInputCollapses() {
        // An interface with its own headphone jack is both the input and the monitor.
        let ordered = AudioEngineController.orderedSubDevices(
            input: interface,
            virtual: blackHole,
            monitor: interface
        )

        #expect(ordered.map(\.uid) == ["if", "bh"])
    }

    @Test("collapsed layout still resolves both output destinations")
    func collapsedLayoutResolvesOutputs() {
        let ordered = AudioEngineController.orderedSubDevices(
            input: interface,
            virtual: blackHole,
            monitor: interface
        )
        let layout = AggregateChannelLayout(orderedSubDevices: ordered)

        // Both the monitor and the virtual device must have an output offset, or the output
        // channel map would silently drop one of the two destinations.
        #expect(layout.outputOffsets["if"] == 0)
        #expect(layout.outputOffsets["bh"] == 2)
        #expect(layout.totalOutputChannels == 4)
    }
}

/// Environment-dependent: asserts against whatever Audio Units are installed on this machine.
/// Kept separate from the pure suites above so a failure here reads as "this Mac has no
/// plugins", not "the logic is broken".
@Suite("Installed plugin discovery")
struct PluginCatalogTests {
    @Test("finds installed AU effects and reports usable names")
    func discoversInstalledEffects() throws {
        let effects = PluginCatalog.installedEffects()

        guard !effects.isEmpty else {
            Issue.record("No Audio Unit effects installed — cannot verify discovery here.")
            return
        }

        // Every entry needs a name and a stable identity, or the picker cannot render or tag it.
        #expect(effects.allSatisfy { !$0.name.isEmpty })
        #expect(Set(effects.map(\.id)).count == effects.count, "descriptor ids must be unique")

        print("discovered \(effects.count) AU effects; first 5:")
        for effect in effects.prefix(5) {
            print("  \(effect.manufacturer) — \(effect.name)")
        }
    }
}

/// The input tap is called by AVFAudio on its own realtime queue, so whatever it writes to
/// must be reachable without touching main-actor state. `PeakLevel` is that box: capturing the
/// controller itself instead traps the process on the first audio buffer.
@Suite("Peak level")
struct PeakLevelTests {
    @Test("reports the most recently recorded peak")
    func reportsLatestPeak() {
        // Arrange
        let peak = PeakLevel()

        // Act
        peak.record(0.25)
        peak.record(0.75)

        // Assert
        #expect(peak.current == 0.75)
    }

    @Test("starts silent and can be reset to silence")
    func resetsToSilence() {
        let peak = PeakLevel()
        #expect(peak.current == 0)

        peak.record(0.5)
        peak.reset()

        #expect(peak.current == 0)
    }

    @Test("concurrent writes from other threads are safe and land")
    func concurrentWritesAreSafe() async {
        let peak = PeakLevel()

        // Stands in for the realtime queue: many writes from off the main actor.
        await withTaskGroup(of: Void.self) { group in
            for index in 1...100 {
                group.addTask { peak.record(Float(index) / 100) }
            }
        }

        #expect(peak.current > 0)
    }
}

/// Regression cover for the crash that killed the app on its first real audio buffer.
///
/// The tap block must be callable from a thread that is not the main actor. Written inline in
/// a method of the `@MainActor` controller it inherits main-actor isolation — capturing
/// nothing from `self` does not help — and Swift's executor check then traps the process.
/// If that regresses, this test does not fail politely: it crashes the test run. That is the
/// alarm, and it is still far better than finding out through a `.ips` file.
@Suite("Input tap isolation")
struct InputTapTests {
    @Test("the tap block runs off the main actor and records the loudest sample")
    func tapBlockRunsOffTheMainActor() throws {
        // Arrange
        let peakLevel = PeakLevel()
        let block = AudioEngineController.peakTap(writingTo: peakLevel)

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.floatChannelData)
        for (frame, value) in [Float(0.1), -0.6, 0.25, 0].enumerated() {
            samples[0][frame] = value
        }

        // Act — synchronously, but on a global queue thread, standing in for
        // RealtimeMessenger.mServiceQueue.
        DispatchQueue.global().sync {
            block(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        }

        // Assert — peak is the largest magnitude, so the negative sample wins.
        #expect(peakLevel.current == 0.6)
    }
}

@Suite("Plugin descriptor identity")
struct PluginDescriptorTests {
    @Test("identity comes from the component triple, not the display name")
    func identityIgnoresName() {
        let a = PluginDescriptor(
            name: "Compressor",
            manufacturer: "Vendor A",
            componentType: 1,
            componentSubType: 2,
            componentManufacturer: 3
        )
        let b = PluginDescriptor(
            name: "Compressor",
            manufacturer: "Vendor B",
            componentType: 9,
            componentSubType: 2,
            componentManufacturer: 3
        )

        // Same display name, different component — must not collide in a Set or a Picker tag.
        #expect(a.id != b.id)
    }
}

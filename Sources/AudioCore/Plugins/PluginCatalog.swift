import AVFoundation
import AudioToolbox
import Foundation

/// One installed Audio Unit effect, as a value.
///
/// Keyed by the `(type, subtype, manufacturer)` triple rather than by name, because names are
/// neither unique nor stable across vendor updates — several vendors ship the same display
/// name in more than one bundle.
/// `Codable` so a chosen plugin survives a relaunch: the persisted form is the component
/// triple, not the display name, for exactly the reason above.
public struct PluginDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let name: String
    public let manufacturer: String
    public let componentType: OSType
    public let componentSubType: OSType
    public let componentManufacturer: OSType

    public var id: String {
        "\(componentType)-\(componentSubType)-\(componentManufacturer)"
    }

    public var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

public enum PluginCatalog {
    /// Effects only. `aufx` covers ordinary effects; `aumf` covers music effects, which some
    /// vendors use for effects that also accept MIDI.
    private static let effectTypes: [OSType] = [
        kAudioUnitType_Effect,
        kAudioUnitType_MusicEffect,
    ]

    /// Every installed AU effect, sorted for stable presentation.
    ///
    /// This covers the user's whole plugin library. Audio Units rather than VST3 is the
    /// settled choice: AU hosting is native to `AVAudioEngine`, `requestViewController` gives
    /// real vendor interfaces for free, and essentially every vendor ships both formats — so
    /// the AU-only restriction costs far less library than it first appears to.
    public static func installedEffects() -> [PluginDescriptor] {
        let manager = AVAudioUnitComponentManager.shared()

        let components = effectTypes.flatMap { type -> [AVAudioUnitComponent] in
            var description = AudioComponentDescription()
            description.componentType = type
            return manager.components(matching: description)
        }

        let descriptors = components.map { component in
            PluginDescriptor(
                name: component.name,
                manufacturer: component.manufacturerName,
                componentType: component.audioComponentDescription.componentType,
                componentSubType: component.audioComponentDescription.componentSubType,
                componentManufacturer: component.audioComponentDescription.componentManufacturer
            )
        }

        // Deduplicate: a component can match more than one of the queries above.
        return Array(Set(descriptors)).sorted { left, right in
            if left.manufacturer != right.manufacturer {
                return left.manufacturer.localizedCaseInsensitiveCompare(right.manufacturer) == .orderedAscending
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    /// Instantiates a plugin for insertion into the engine.
    ///
    /// Loaded **in-process**: `.loadOutOfProcess` only applies to AUv3, and most of a typical
    /// library is AUv2, so a crashing plugin takes the host down with it. That is a deliberate
    /// compatibility tradeoff, not an oversight.
    public static func instantiate(_ descriptor: PluginDescriptor) async throws -> AVAudioUnit {
        try await AVAudioUnit.instantiate(
            with: descriptor.audioComponentDescription,
            options: []
        )
    }
}

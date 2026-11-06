import AVFoundation
import VST3Host

/// One insert effect on an audio track.
public struct AudioEffect: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case audioUnit
        case vst3
    }

    public var id = UUID()
    public var kind: Kind
    public var name: String
    public var manufacturer: String

    // Audio Unit component.
    public var componentType: UInt32 = 0
    public var componentSubType: UInt32 = 0
    public var componentManufacturer: UInt32 = 0

    // VST3 plug-in.
    public var bundlePath: String?
    /// Class ID in the bundle. `nil` means the first audio effect of the bundle.
    public var classID: String?

    public var bypassed = false
    /// `AUAudioUnit.fullState` as a binary property list.
    public var state: Data?

    public init(kind: Kind, name: String, manufacturer: String) {
        self.kind = kind
        self.name = name
        self.manufacturer = manufacturer
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType, componentSubType: componentSubType,
            componentManufacturer: componentManufacturer, componentFlags: 0, componentFlagsMask: 0)
    }

    /// A new effect from a catalog entry, with a new id and no state.
    public func makeInstance() -> AudioEffect {
        var copy = self
        copy.id = UUID()
        copy.state = nil
        copy.bypassed = false
        return copy
    }
}

/// Effects installed on this Mac.
public enum PluginCatalog {
    public static func audioUnits() -> [AudioEffect] {
        var effects: [AudioEffect] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let search = AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0,
                componentFlagsMask: 0)
            for component in AVAudioUnitComponentManager.shared().components(matching: search) {
                let description = component.audioComponentDescription
                var effect = AudioEffect(
                    kind: .audioUnit, name: component.name, manufacturer: component.manufacturerName)
                effect.componentType = description.componentType
                effect.componentSubType = description.componentSubType
                effect.componentManufacturer = description.componentManufacturer
                effects.append(effect)
            }
        }
        return sorted(effects)
    }

    public static let vst3Folders: [URL] = [
        URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3"),
    ]

    /// VST3 effects found in the standard folders. Bundles are not loaded: the classes come from
    /// `moduleinfo.json` when the bundle has one, else the bundle is listed once.
    public static func vst3Plugins(folders: [URL] = vst3Folders) -> [AudioEffect] {
        var effects: [AudioEffect] = []
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.lowercased().hasSuffix(".vst3") {
                let bundle = folder.appendingPathComponent(name)
                effects += vst3Effects(in: bundle)
            }
        }
        return sorted(effects)
    }

    static func vst3Effects(in bundle: URL) -> [AudioEffect] {
        let bundleName = bundle.deletingPathExtension().lastPathComponent
        let infoURL = bundle.appendingPathComponent("Contents/Resources/moduleinfo.json")

        guard let data = try? Data(contentsOf: infoURL),
            let info = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
            let classes = info["Classes"] as? [[String: Any]]
        else {
            var effect = AudioEffect(kind: .vst3, name: bundleName, manufacturer: "")
            effect.bundlePath = bundle.path
            return [effect]
        }

        let factoryVendor = (info["Factory Info"] as? [String: Any])?["Vendor"] as? String ?? ""
        return classes.compactMap { entry in
            guard entry["Category"] as? String == "Audio Module Class",
                let classID = entry["CID"] as? String
            else { return nil }
            // Instruments are not insert effects.
            let subCategories = entry["Sub Categories"] as? [String] ?? []
            if subCategories.contains("Instrument") && !subCategories.contains("Fx") {
                return nil
            }
            var effect = AudioEffect(
                kind: .vst3, name: entry["Name"] as? String ?? bundleName,
                manufacturer: entry["Vendor"] as? String ?? factoryVendor)
            effect.bundlePath = bundle.path
            effect.classID = classID
            return effect
        }
    }

    private static func sorted(_ effects: [AudioEffect]) -> [AudioEffect] {
        effects.sorted {
            ($0.manufacturer.localizedLowercase, $0.name.localizedLowercase)
                < ($1.manufacturer.localizedLowercase, $1.name.localizedLowercase)
        }
    }
}

/// Creates the audio units of effects. A VST3 effect runs inside `VST3AudioUnit`,
/// so the rest of the app handles it like any other audio unit.
/// Moves a value that is not `Sendable` to the main actor and back.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

public enum PluginFactory {
    public static func instantiate(_ effect: AudioEffect) async throws -> AVAudioUnit {
        let unit: AVAudioUnit
        switch effect.kind {
        case .audioUnit:
            unit = try await AVAudioUnit.instantiate(with: effect.componentDescription, options: [])
        case .vst3:
            guard let path = effect.bundlePath else {
                throw EngineError.plugin("The VST3 bundle path is missing.")
            }
            VST3AudioUnit.registerOnce()
            unit = try await AVAudioUnit.instantiate(with: VST3HostComponentDescription, options: .loadInProcess)
            guard unit.auAudioUnit is VST3AudioUnit else {
                throw EngineError.plugin("Cannot create the VST3 host.")
            }
            // The SDK binds the link between the processor and the editor controller to the
            // thread that creates the plug-in, and drops messages sent from other threads.
            // The editor runs on the main thread, so the plug-in must be created there.
            let box = UncheckedBox(unit)
            let classID = effect.classID
            let state = effect.state
            try await MainActor.run {
                guard let host = box.value.auAudioUnit as? VST3AudioUnit else { return }
                try host.loadPlugin(atPath: path, classID: classID)
                restoreState(state, into: box.value)
            }
            return unit
        }
        restoreState(effect.state, into: unit)
        return unit
    }

    public static func captureState(of unit: AVAudioUnit) -> Data? {
        guard let state = unit.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    static func restoreState(_ data: Data?, into unit: AVAudioUnit) {
        guard let data,
            let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        unit.auAudioUnit.fullState = state
    }
}

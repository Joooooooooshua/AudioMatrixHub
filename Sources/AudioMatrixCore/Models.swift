import Foundation
import CoreAudio
import CAudioMatrixRust

public enum AudioBusType: String, Codable, CaseIterable {
    case output = "output"
    case input = "input"

    public var displayName: String {
        switch self {
        case .output: return "Output Plugin Chain"
        case .input:  return "Mic Input Plugin Chain"
        }
    }

    public var graphIndex: Int {
        switch self {
        case .output: return 0
        case .input:  return 1
        }
    }

    public var graphName: String {
        switch self {
        case .output: return "Output_Bus_Master"
        case .input:  return "Input_Bus_Mic"
        }
    }
}

public enum SpeakerSimMode: String, Codable, CaseIterable, Identifiable {
    case off = "off"
    case nearfield = "nearfield"
    case studio = "studio"
    case stage = "stage"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off:       return "Off"
        case .nearfield: return "Nearfield"
        case .studio:    return "Studio"
        case .stage:     return "Stage"
        }
    }

    public var subtitle: String {
        switch self {
        case .off:       return "Standard stereo headphone isolation"
        case .nearfield: return "Tight desktop studio monitors (ITD/ILD crossfeed)"
        case .studio:    return "Acoustic control room monitors with natural early reflections"
        case .stage:     return "Wide concert stage ambience for classical & live music"
        }
    }

    public var defaultCrossfeed: Float {
        switch self {
        case .off:       return 0.0
        case .nearfield: return 0.55
        case .studio:    return 0.60
        case .stage:     return 0.38
        }
    }

    public var defaultRoomAmbience: Float {
        switch self {
        case .off:       return 0.0
        case .nearfield: return 0.22
        case .studio:    return 0.45
        case .stage:     return 0.68
        }
    }
}

public enum EQToneProfile: String, Codable, CaseIterable, Identifiable {
    case off = "off"
    case warm = "warm"
    case clear = "clear"
    case bassBoost = "bassBoost"
    case vShape = "vShape"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off:       return "Off"
        case .warm:      return "Warm"
        case .clear:     return "Clear"
        case .bassBoost: return "Bass+"
        case .vShape:    return "V-Shape"
        }
    }

    public var subtitle: String {
        switch self {
        case .off:       return "Uncolored 0 dB frequency response"
        case .warm:      return "Full-bodied low-mids with smoothed upper treble"
        case .clear:     return "Enhanced vocal presence and high-frequency air"
        case .bassBoost: return "Deep low-end sub & punch boost"
        case .vShape:    return "Boosted lows and highs with recessed mids for dance & pop"
        }
    }

    public var defaultBassDB: Float {
        switch self {
        case .off:       return 0.0
        case .warm:      return 2.5
        case .clear:     return -1.0
        case .bassBoost: return 4.2
        case .vShape:    return 3.5
        }
    }

    public var defaultMidDB: Float {
        switch self {
        case .off:       return 0.0
        case .warm:      return -0.5
        case .clear:     return 2.0
        case .bassBoost: return 0.0
        case .vShape:    return -1.5
        }
    }

    public var defaultTrebleDB: Float {
        switch self {
        case .off:       return 0.0
        case .warm:      return -1.5
        case .clear:     return 2.5
        case .bassBoost: return 0.5
        case .vShape:    return 3.2
        }
    }
}

public struct BuiltInDSPSettings: Codable, Equatable {
    public var speakerMode: SpeakerSimMode
    public var eqProfile: EQToneProfile
    public var crossfeedAmount: Float
    public var roomAmbience: Float
    public var bassTiltDB: Float
    public var midTiltDB: Float
    public var trebleTiltDB: Float
    public var safeHeadroomLimiter: Bool

    public init(
        speakerMode: SpeakerSimMode = .off,
        eqProfile: EQToneProfile = .off,
        crossfeedAmount: Float? = nil,
        roomAmbience: Float? = nil,
        bassTiltDB: Float? = nil,
        midTiltDB: Float? = nil,
        trebleTiltDB: Float? = nil,
        safeHeadroomLimiter: Bool = true
    ) {
        self.speakerMode = speakerMode
        self.eqProfile = eqProfile
        self.crossfeedAmount = crossfeedAmount ?? speakerMode.defaultCrossfeed
        self.roomAmbience = roomAmbience ?? speakerMode.defaultRoomAmbience
        self.bassTiltDB = bassTiltDB ?? eqProfile.defaultBassDB
        self.midTiltDB = midTiltDB ?? eqProfile.defaultMidDB
        self.trebleTiltDB = trebleTiltDB ?? eqProfile.defaultTrebleDB
        self.safeHeadroomLimiter = safeHeadroomLimiter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let spk = try c.decodeIfPresent(SpeakerSimMode.self, forKey: .speakerMode) ?? .off
        let eq = try c.decodeIfPresent(EQToneProfile.self, forKey: .eqProfile) ?? .off
        self.speakerMode = spk
        self.eqProfile = eq
        self.crossfeedAmount = try c.decodeIfPresent(Float.self, forKey: .crossfeedAmount) ?? spk.defaultCrossfeed
        self.roomAmbience = try c.decodeIfPresent(Float.self, forKey: .roomAmbience) ?? spk.defaultRoomAmbience
        self.bassTiltDB = try c.decodeIfPresent(Float.self, forKey: .bassTiltDB) ?? eq.defaultBassDB
        self.midTiltDB = try c.decodeIfPresent(Float.self, forKey: .midTiltDB) ?? eq.defaultMidDB
        self.trebleTiltDB = try c.decodeIfPresent(Float.self, forKey: .trebleTiltDB) ?? eq.defaultTrebleDB
        self.safeHeadroomLimiter = try c.decodeIfPresent(Bool.self, forKey: .safeHeadroomLimiter) ?? true
    }

    public mutating func applySpeakerMode(_ mode: SpeakerSimMode) {
        speakerMode = mode
        crossfeedAmount = mode.defaultCrossfeed
        roomAmbience = mode.defaultRoomAmbience
    }

    public mutating func applyEQProfile(_ profile: EQToneProfile) {
        eqProfile = profile
        bassTiltDB = profile.defaultBassDB
        midTiltDB = profile.defaultMidDB
        trebleTiltDB = profile.defaultTrebleDB
    }

    public var summaryTitle: String {
        switch (speakerMode != .off, eqProfile != .off) {
        case (true, true):   return "\(speakerMode.title) + \(eqProfile.title)"
        case (true, false):  return speakerMode.title
        case (false, true):  return eqProfile.title
        case (false, false): return isEnabled ? "Custom" : "Direct"
        }
    }

    public var isEnabled: Bool {
        speakerMode != .off ||
        eqProfile != .off ||
        crossfeedAmount > 0.01 ||
        roomAmbience > 0.01 ||
        abs(bassTiltDB) > 0.05 ||
        abs(midTiltDB) > 0.05 ||
        abs(trebleTiltDB) > 0.05
    }
}

public struct AudioDeviceInfo: Identifiable, Equatable, Codable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
    public let sampleRate: Double
    public let transportType: String
    public var volume: Float
    public var hasHardwareVolume: Bool

    public init(
        id: UInt32,
        uid: String,
        name: String,
        hasInput: Bool,
        hasOutput: Bool,
        sampleRate: Double,
        transportType: String,
        volume: Float = 1.0,
        hasHardwareVolume: Bool = true
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.sampleRate = sampleRate
        self.transportType = transportType
        self.volume = volume
        self.hasHardwareVolume = hasHardwareVolume
    }

    public var isVirtual: Bool {
        transportType == "Virtual" ||
        name.contains("BlackHole") ||
        name.contains("MOTIV Mix") ||
        uid == "com.audiomatrix.virtual.mic" ||
        name.contains("AudioMatrix Virtual Mic")
    }

    public var isBluetooth: Bool {
        transportType == "Bluetooth" || name.localizedCaseInsensitiveContains("AirPods") || name.localizedCaseInsensitiveContains("Beats")
    }

    public var sfSymbolName: String {
        symbolName(forOutput: false)
    }

    public var outputSFSymbolName: String {
        symbolName(forOutput: true)
    }

    private func symbolName(forOutput: Bool) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods") { return "airpodspro" }
        if forOutput {
            if lower.contains("mv7") || lower.contains("shure") || lower.contains("fosi") || lower.contains("dac") || lower.contains("sk02") {
                return "headphones"
            }
        } else {
            if lower.contains("mv7") || lower.contains("shure") || (hasInput && !hasOutput) { return "mic.fill" }
            if lower.contains("fosi") || lower.contains("dac") || lower.contains("sk02") { return "headphones" }
        }
        if lower.contains("macbook") && hasOutput { return "laptopcomputer" }
        if lower.contains("lg") || lower.contains("hdr") || transportType == "DisplayPort" { return "display" }
        if transportType == "Aggregate" || transportType == "Shared" { return "person.2.wave.2.fill" }
        if isVirtual { return "point.3.connected.trianglepath.dotted" }
        return forOutput || hasOutput ? "hifispeaker.fill" : "mic.fill"
    }
}

public struct PluginSlot: Identifiable, Equatable, Codable {
    public var id: Int { nodeId }
    public var nodeId: Int
    public var slug: String
    public var name: String
    public var format: String
    public var identifier: String
    public var bus: AudioBusType
    public var bypass: Bool
    public var gain: Float

    public init(nodeId: Int, slug: String? = nil, name: String, format: String, identifier: String, bus: AudioBusType = .output, bypass: Bool = false, gain: Float = 1.0) {
        self.nodeId = nodeId
        self.slug = slug ?? Self.slugify(name)
        self.name = name
        self.format = format
        self.identifier = identifier
        self.bus = bus
        self.bypass = bypass
        self.gain = gain
    }

    /// Matches Kushview Element's `detail::oscSlugify` rule via Rust C-ABI (`am_osc_slugify`).
    public static func slugify(_ input: String) -> String {
        let cap = max(64, input.utf8.count + 16)
        var outBuf = [CChar](repeating: 0, count: cap)
        let written = input.withCString { cStr in
            outBuf.withUnsafeMutableBufferPointer { ptr in
                am_osc_slugify(cStr, ptr.baseAddress, ptr.count)
            }
        }
        if written == 0 {
            return "node"
        }
        return String(cString: outBuf)
    }
}

public struct InstalledPlugin: Identifiable, Equatable, Codable {
    public var id: String { identifier }
    public let name: String
    public let format: String
    public let identifier: String

    public init(name: String, format: String, identifier: String) {
        self.name = name
        self.format = format
        self.identifier = identifier
    }
}

public struct AppRouteRule: Codable, Equatable, Identifiable {
    public var id: String { bundleId }
    public var bundleId: String
    public var targetDevice: String
    public var volume: Int

    public init(bundleId: String, targetDevice: String, volume: Int = 100) {
        self.bundleId = bundleId
        self.targetDevice = targetDevice
        self.volume = volume
    }
}

public struct AppRoutingPreset: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var apps: [AppRouteRule]

    public init(name: String, apps: [AppRouteRule]) {
        self.name = name
        self.apps = apps
    }
}

public struct AppMixerState: Codable, Equatable, Identifiable {
    public var id: String { bundleId }
    public var bundleId: String
    public var volume: Float // 0.0 ... 2.0 (1.0 = 100%)
    public var isMuted: Bool
    public var targetDeviceUID: String?

    public init(
        bundleId: String,
        volume: Float = 1.0,
        isMuted: Bool = false,
        targetDeviceUID: String? = nil
    ) {
        self.bundleId = bundleId
        self.volume = max(0.0, min(2.0, volume))
        self.isMuted = isMuted
        self.targetDeviceUID = targetDeviceUID
    }

    public var isDefault: Bool {
        abs(volume - 1.0) < 0.01 && !isMuted && targetDeviceUID == nil
    }
}

public struct LoopbackAppState: Codable, Equatable, Identifiable {
    public var id: String { bundleId }
    public var bundleId: String
    public var isIncluded: Bool
    public var volume: Float // 0.0 ... 2.0 (1.0 = 100%)

    public init(bundleId: String, isIncluded: Bool = true, volume: Float = 1.0) {
        self.bundleId = bundleId
        self.isIncluded = isIncluded
        self.volume = max(0.0, min(2.0, volume))
    }

    public var isDefault: Bool {
        isIncluded && abs(volume - 1.0) < 0.01
    }
}

public struct LoopbackConfig: Codable, Equatable {
    public var virtualBusName: String
    public var includeMicrophone: Bool
    public var micGain: Float
    public var loopbackGain: Float

    public init(
        virtualBusName: String = "AudioMatrix Virtual Mic",
        includeMicrophone: Bool = false,
        micGain: Float = 1.8,
        loopbackGain: Float = 1.0
    ) {
        self.virtualBusName = virtualBusName
        self.includeMicrophone = includeMicrophone
        self.micGain = micGain
        self.loopbackGain = loopbackGain
    }
}

public enum AudioMatrixPaths {
    public static var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    public static var appSupportDirectory: String {
        "\(homeDirectory)/Library/Application Support/AudioMatrixHub"
    }

    public static var documentsMatrixDirectory: String {
        "\(homeDirectory)/Documents/AudioMatrix"
    }

    public static var defaultConfigPath: String {
        let docsConfig = "\(documentsMatrixDirectory)/config.json"
        if FileManager.default.fileExists(atPath: docsConfig) {
            return docsConfig
        }
        return "\(appSupportDirectory)/config.json"
    }

    public static var defaultElementSessionPath: String {
        let docsSession = "\(documentsMatrixDirectory)/element/AudioMatrix_Template.els"
        if FileManager.default.fileExists(atPath: docsSession) {
            return docsSession
        }
        return "\(appSupportDirectory)/element/AudioMatrix_Template.els"
    }

    public static var defaultElementSettingsPath: String {
        "\(homeDirectory)/Library/Application Support/Kushview/Element/Element.conf"
    }

    public static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

public struct ElementConfig: Codable, Equatable {
    public var appPath: String
    public var sessionPath: String
    public var settingsPath: String
    public var oscHost: String
    public var oscPort: UInt16
    public var oscFeedbackPort: UInt16

    public init(
        appPath: String = "/Applications/Element.app",
        sessionPath: String = AudioMatrixPaths.defaultElementSessionPath,
        settingsPath: String = AudioMatrixPaths.defaultElementSettingsPath,
        oscHost: String = "127.0.0.1",
        oscPort: UInt16 = 9000,
        oscFeedbackPort: UInt16 = 9001
    ) {
        self.appPath = AudioMatrixPaths.expandTilde(appPath)
        self.sessionPath = AudioMatrixPaths.expandTilde(sessionPath)
        self.settingsPath = AudioMatrixPaths.expandTilde(settingsPath)
        self.oscHost = oscHost
        self.oscPort = oscPort
        self.oscFeedbackPort = oscFeedbackPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.appPath = AudioMatrixPaths.expandTilde(try c.decodeIfPresent(String.self, forKey: .appPath) ?? "/Applications/Element.app")
        self.sessionPath = AudioMatrixPaths.expandTilde(try c.decodeIfPresent(String.self, forKey: .sessionPath) ?? AudioMatrixPaths.defaultElementSessionPath)
        self.settingsPath = AudioMatrixPaths.expandTilde(try c.decodeIfPresent(String.self, forKey: .settingsPath) ?? AudioMatrixPaths.defaultElementSettingsPath)
        self.oscHost = try c.decodeIfPresent(String.self, forKey: .oscHost) ?? "127.0.0.1"
        self.oscPort = try c.decodeIfPresent(UInt16.self, forKey: .oscPort) ?? 9000
        self.oscFeedbackPort = try c.decodeIfPresent(UInt16.self, forKey: .oscFeedbackPort) ?? 9001
    }
}

public struct AudioMatrixConfig: Codable, Equatable {
    public var version: String
    public var preferredInputDevice: String
    public var fallbackInputDevice: String
    public var inputGuardEnabled: Bool
    public var sampleRate: Double
    public var bufferSize: Int
    public var virtualOutputBus: String
    public var virtualMicBus: String
    public var preferredOutputDevices: [String]
    public var listenTogetherDevices: [String]
    public var builtInDSP: BuiltInDSPSettings
    public var loopback: LoopbackConfig
    public var element: ElementConfig
    public var appRoutingPresets: [AppRoutingPreset]

    public static var defaultConfigPath: String {
        AudioMatrixPaths.defaultConfigPath
    }

    public init(
        version: String = "2.0.0",
        preferredInputDevice: String = "Shure MV7i",
        fallbackInputDevice: String = "MacBook Pro Microphone",
        inputGuardEnabled: Bool = true,
        sampleRate: Double = 48000,
        bufferSize: Int = 512,
        virtualOutputBus: String = "BlackHole 2ch",
        virtualMicBus: String = "MOTIV Mix Virtual",
        preferredOutputDevices: [String] = [],
        listenTogetherDevices: [String] = [],
        builtInDSP: BuiltInDSPSettings = BuiltInDSPSettings(),
        loopback: LoopbackConfig = LoopbackConfig(),
        element: ElementConfig = ElementConfig(),
        appRoutingPresets: [AppRoutingPreset] = []
    ) {
        self.version = version
        self.preferredInputDevice = preferredInputDevice
        self.fallbackInputDevice = fallbackInputDevice
        self.inputGuardEnabled = inputGuardEnabled
        self.sampleRate = sampleRate
        self.bufferSize = bufferSize
        self.virtualOutputBus = virtualOutputBus
        self.virtualMicBus = virtualMicBus
        self.preferredOutputDevices = preferredOutputDevices
        self.listenTogetherDevices = listenTogetherDevices
        self.builtInDSP = builtInDSP
        self.loopback = loopback
        self.element = element
        self.appRoutingPresets = appRoutingPresets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? "2.0.0"
        self.preferredInputDevice = try c.decodeIfPresent(String.self, forKey: .preferredInputDevice) ?? "MacBook Pro Microphone"
        self.fallbackInputDevice = try c.decodeIfPresent(String.self, forKey: .fallbackInputDevice) ?? "MacBook Pro Microphone"
        self.inputGuardEnabled = try c.decodeIfPresent(Bool.self, forKey: .inputGuardEnabled) ?? true
        self.sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48000
        self.bufferSize = try c.decodeIfPresent(Int.self, forKey: .bufferSize) ?? 512
        self.virtualOutputBus = try c.decodeIfPresent(String.self, forKey: .virtualOutputBus) ?? "BlackHole 2ch"
        self.virtualMicBus = try c.decodeIfPresent(String.self, forKey: .virtualMicBus) ?? "MOTIV Mix Virtual"
        self.preferredOutputDevices = try c.decodeIfPresent([String].self, forKey: .preferredOutputDevices) ?? []
        self.listenTogetherDevices = try c.decodeIfPresent([String].self, forKey: .listenTogetherDevices) ?? []
        self.builtInDSP = try c.decodeIfPresent(BuiltInDSPSettings.self, forKey: .builtInDSP) ?? BuiltInDSPSettings()
        self.loopback = try c.decodeIfPresent(LoopbackConfig.self, forKey: .loopback) ?? LoopbackConfig()
        self.element = try c.decodeIfPresent(ElementConfig.self, forKey: .element) ?? ElementConfig()
        self.appRoutingPresets = try c.decodeIfPresent([AppRoutingPreset].self, forKey: .appRoutingPresets) ?? []
    }

    public static func load(from path: String = AudioMatrixPaths.defaultConfigPath) -> AudioMatrixConfig {
        let resolved = AudioMatrixPaths.expandTilde(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else {
            return AudioMatrixConfig()
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(AudioMatrixConfig.self, from: data)) ?? AudioMatrixConfig()
    }

    public func save(to path: String = AudioMatrixPaths.defaultConfigPath) throws {
        let resolved = AudioMatrixPaths.expandTilde(path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = URL(fileURLWithPath: resolved)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

import Foundation
import SwiftUI
import AppKit
import AudioMatrixCore

@MainActor
public final class AudioMatrixViewModel: ObservableObject {
    @Published public var config: AudioMatrixConfig
    @Published public var devices: [AudioDeviceInfo] = []
    @Published public var currentInput: AudioDeviceInfo?
    @Published public var currentOutput: AudioDeviceInfo?

    @Published public var selectedPhysicalOutputName: String = ""
    @Published public var primaryVolume: Float = 1.0
    @Published public var secondaryVolume: Float = 1.0

    @Published public var builtInDSP: BuiltInDSPSettings
    @Published public var externalElementDSPEnabled: Bool = false
    @Published public var listenTogetherActive: Bool = false
    @Published public var listenDeviceB: String = ""
    @Published public var pipelineStatus: NativePipelineStatus = .idle

    @Published public var outputSlots: [PluginSlot] = []
    @Published public var inputSlots: [PluginSlot] = []
    @Published public var installedPlugins: [InstalledPlugin] = []
    @Published public var runningApps: [RunningAudioApp] = []
    @Published public var appRoutes: [String: String] = [:] // bundleId -> deviceUID
    @Published public var appMixerStates: [String: AppMixerState] = [:]
    @Published public var loopbackActive: Bool = false
    @Published public var loopbackTargetBus: String = CoreAudioManager.builtInVirtualMicName
    @Published public var loopbackIncludeMic: Bool = false
    @Published public var loopbackMicGain: Float = 1.8
    @Published public var loopbackSystemGain: Float = 1.0
    @Published public var loopbackAppStates: [String: LoopbackAppState] = [:]
    @Published public var blackHoleInstalled: Bool = false
    @Published public var isRecording: Bool = false
    @Published public var recordingSeconds: Int = 0
    @Published public var lastRecordingURL: URL?
    @Published public var elementInstalled: Bool = false
    @Published public var elementRunning: Bool = false

    private let coreAudio = CoreAudioManager.shared
    private let pipeline = NativeAudioPipeline.shared
    private let xmlManager: ElementXMLManager
    private let oscClient: OSCClient
    private let bridge = FineTuneBridge.shared
    private var recordUITimer: Timer?

    public init() {
        let loadedConfig = AudioMatrixConfig.load()
        self.config = loadedConfig
        self.builtInDSP = loadedConfig.builtInDSP
        self.loopbackTargetBus = loadedConfig.loopback.virtualBusName
        self.loopbackIncludeMic = loadedConfig.loopback.includeMicrophone
        let initialMicGain: Float = (loadedConfig.version < "2.0.0" && abs(loadedConfig.loopback.micGain - 1.0) < 0.01)
            ? 1.8
            : max(0.0, min(2.5, loadedConfig.loopback.micGain))
        self.loopbackMicGain = initialMicGain
        self.pipeline.loopbackMicGain = initialMicGain
        let initialSysGain = max(0.0, min(2.0, loadedConfig.loopback.loopbackGain))
        self.loopbackSystemGain = initialSysGain
        self.pipeline.loopbackGain = initialSysGain
        self.xmlManager = ElementXMLManager(
            sessionPath: loadedConfig.element.sessionPath,
            settingsPath: loadedConfig.element.settingsPath
        )
        self.oscClient = OSCClient(
            host: loadedConfig.element.oscHost,
            port: loadedConfig.element.oscPort
        )
        self.xmlManager.ensureSessionFileExists()

        _ = coreAudio.alignAllDevicesTo48kHz()
        setupCallbacks()
        refreshAll()
        restoreInitialDevices()

        if loadedConfig.builtInDSP.isEnabled && !externalElementDSPEnabled {
            applyBuiltInDSP(loadedConfig.builtInDSP, save: false)
        }
    }

    private func restoreInitialDevices() {
        let outs = physicalOutputDevices()
        if selectedPhysicalOutputName.isEmpty {
            if let cur = currentOutput, !cur.isVirtual, cur.uid != CoreAudioManager.listenTogetherUID {
                selectedPhysicalOutputName = cur.name
            } else if let pref = config.preferredOutputDevices.first(where: { name in outs.contains(where: { $0.name == name }) }) {
                selectedPhysicalOutputName = pref
            } else if let first = outs.first {
                selectedPhysicalOutputName = first.name
            }
        }
        if listenDeviceB.isEmpty {
            if let sec = config.listenTogetherDevices.dropFirst().first,
               outs.contains(where: { $0.name == sec && $0.name != selectedPhysicalOutputName }) {
                listenDeviceB = sec
            } else {
                listenDeviceB = outs.first(where: { $0.name != selectedPhysicalOutputName })?.name ?? ""
            }
        }
        syncVolumesFromDevices()
    }

    private func setupCallbacks() {
        coreAudio.onDevicesChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        _ = oscClient.startListening(port: config.element.oscFeedbackPort) { [weak self] address, value in
            Task { @MainActor in
                self?.handleOSCFeedback(address: address, value: value)
            }
        }
        coreAudio.startMonitoring { [weak self] in
            self?.config ?? AudioMatrixConfig()
        }
    }

    private func handleOSCFeedback(address: String, value: Float) {
        // Handle `/element/.../node/<idOrSlug>/bypass` or `/outputgain`
        let parts = address.split(separator: "/").map(String.init)
        guard let nodeIdx = parts.firstIndex(of: "node"), nodeIdx + 2 < parts.count else { return }
        let target = parts[nodeIdx + 1]
        let prop = parts[nodeIdx + 2]

        if prop == "bypass" {
            let bypassed = value >= 0.5
            if let idx = outputSlots.firstIndex(where: { "\($0.nodeId)" == target || $0.slug == target }) {
                outputSlots[idx].bypass = bypassed
            } else if let idx = inputSlots.firstIndex(where: { "\($0.nodeId)" == target || $0.slug == target }) {
                inputSlots[idx].bypass = bypassed
            }
        } else if prop == "outputgain" {
            if let idx = outputSlots.firstIndex(where: { "\($0.nodeId)" == target || $0.slug == target }) {
                outputSlots[idx].gain = value
            } else if let idx = inputSlots.firstIndex(where: { "\($0.nodeId)" == target || $0.slug == target }) {
                inputSlots[idx].gain = value
            }
        }
    }

    public func refreshAll() {
        refreshDevices()
        refreshSlots()
        if installedPlugins.isEmpty {
            installedPlugins = xmlManager.scanInstalledPlugins()
        }
        runningApps = bridge.listRunningApps()
        appRoutes = pipeline.activeAppRoutes()
        appMixerStates = pipeline.getAppMixerStates()
        loopbackAppStates = pipeline.getLoopbackAppStates()
        loopbackActive = pipeline.isLoopbackActive
        isRecording = pipeline.isRecording
        if lastRecordingURL == nil {
            lastRecordingURL = pipeline.lastRecordedFileURL
        }
        blackHoleInstalled = coreAudio.isBlackHoleInstalled()
        let busOptions = loopbackBusOptions()
        if !busOptions.contains(loopbackTargetBus) {
            loopbackTargetBus = CoreAudioManager.builtInVirtualMicName
        }
        elementInstalled = bridge.isElementInstalled()
        elementRunning = bridge.isElementRunning()
    }

    public func refreshDevices() {
        devices = coreAudio.listDevices()
        currentInput = coreAudio.getDefaultInputDevice()
        currentOutput = coreAudio.getDefaultOutputDevice()
        listenTogetherActive = coreAudio.isListenTogetherActive() || (pipeline.status != .idle && listenTogetherActive)
        elementInstalled = bridge.isElementInstalled()
        elementRunning = bridge.isElementRunning()

        if let out = currentOutput {
            if out.name.localizedCaseInsensitiveContains(config.virtualOutputBus) {
                externalElementDSPEnabled = true
            } else {
                externalElementDSPEnabled = false
                if !out.isVirtual && out.uid != CoreAudioManager.listenTogetherUID {
                    selectedPhysicalOutputName = out.name
                }
            }
        }
        syncVolumesFromDevices()
    }

    public func refreshSlots() {
        let allSlots = xmlManager.loadSlotsFromSession()
        outputSlots = allSlots.filter { $0.bus == .output }
        inputSlots = allSlots.filter { $0.bus == .input }
    }

    public func physicalOutputDevices() -> [AudioDeviceInfo] {
        devices.filter {
            $0.hasOutput &&
            !$0.isVirtual &&
            $0.uid != CoreAudioManager.builtInVirtualMicUID &&
            !$0.name.localizedCaseInsensitiveContains(config.virtualOutputBus) &&
            !$0.name.localizedCaseInsensitiveContains(config.virtualMicBus) &&
            $0.uid != CoreAudioManager.listenTogetherUID
        }
    }

    private func syncVolumesFromDevices() {
        if let pri = devices.first(where: { $0.name == selectedPhysicalOutputName }) {
            primaryVolume = pri.hasHardwareVolume ? pri.volume : pipeline.primarySoftwareGain
        }
        if let sec = devices.first(where: { $0.name == listenDeviceB }) {
            secondaryVolume = sec.hasHardwareVolume ? sec.volume : pipeline.secondarySoftwareGain
        }
    }

    // MARK: - Direct 1-Click Input & Output Switching (Zero Restart)

    public func selectInputDevice(_ device: AudioDeviceInfo) {
        config.preferredInputDevice = device.name
        try? config.save()
        if coreAudio.setDefaultInputDevice(id: device.id) {
            currentInput = device
            refreshDevices()
        }
    }

    public func toggleInputGuard(_ enabled: Bool) {
        config.inputGuardEnabled = enabled
        try? config.save()
        if enabled {
            coreAudio.enforceInputGuard(config: config)
        }
    }

    public func selectPhysicalOutput(_ device: AudioDeviceInfo) {
        selectedPhysicalOutputName = device.name

        if listenTogetherActive {
            coreAudio.disableListenTogether()
            listenTogetherActive = false
        }

        if externalElementDSPEnabled {
            _ = coreAudio.ensureOutputProxy(targetDeviceUIDs: [device.uid])
            _ = coreAudio.setDefaultOutputDevice(byName: config.virtualOutputBus)
        } else {
            _ = coreAudio.setDefaultOutputDevice(id: device.id)
            currentOutput = device
            if builtInDSP.isEnabled {
                restartBuiltInPipelineIfNeeded()
            }
        }
        syncVolumesFromDevices()
        refreshDevices()
    }

    // MARK: - Inline Hardware & Software Volume Controls

    public func setPrimaryVolume(_ volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        primaryVolume = clamped
        guard let dev = devices.first(where: { $0.name == selectedPhysicalOutputName }) else { return }

        if dev.hasHardwareVolume {
            _ = coreAudio.setDeviceVolume(dev.id, volume: clamped)
            pipeline.primarySoftwareGain = 1.0
        } else {
            pipeline.primarySoftwareGain = clamped
        }
    }

    public func setSecondaryVolume(_ volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        secondaryVolume = clamped
        guard let dev = devices.first(where: { $0.name == listenDeviceB }) else { return }

        if dev.hasHardwareVolume {
            _ = coreAudio.setDeviceVolume(dev.id, volume: clamped)
            pipeline.secondarySoftwareGain = 1.0
        } else {
            pipeline.secondarySoftwareGain = clamped
        }
    }

    // MARK: - Built-in Sound Engine (Orthogonal Speaker Sim + Tone EQ + Fine-Tuning)

    public func selectSpeakerMode(_ mode: SpeakerSimMode) {
        var next = builtInDSP
        next.applySpeakerMode(mode)
        applyBuiltInDSP(next, save: true)
    }

    public func selectEQProfile(_ profile: EQToneProfile) {
        var next = builtInDSP
        next.applyEQProfile(profile)
        applyBuiltInDSP(next, save: true)
    }

    public func updateBuiltInDSP(_ settings: BuiltInDSPSettings) {
        applyBuiltInDSP(settings, save: true)
    }

    private func applyBuiltInDSP(_ settings: BuiltInDSPSettings, save: Bool) {
        builtInDSP = settings
        config.builtInDSP = settings
        if save {
            try? config.save()
        }

        if settings.isEnabled {
            // Disengage external Element routing if switching to Built-in Sound Engine
            if externalElementDSPEnabled {
                setExternalElementDSP(false)
            }
            pipeline.dspEngine.updateSettings(settings)
            if pipeline.status == .idle {
                restartBuiltInPipelineIfNeeded()
            }
        } else {
            pipeline.stopGlobalPipeline()
            pipelineStatus = .idle
            if listenTogetherActive && !externalElementDSPEnabled {
                _ = coreAudio.enableListenTogether(primaryDeviceName: selectedPhysicalOutputName, secondaryDeviceName: listenDeviceB)
            }
        }
    }

    private func restartBuiltInPipelineIfNeeded() {
        guard builtInDSP.isEnabled else {
            pipeline.stopGlobalPipeline()
            pipelineStatus = .idle
            return
        }
        guard let pri = devices.first(where: { $0.name == selectedPhysicalOutputName }) else { return }
        let secUID = listenTogetherActive ? devices.first(where: { $0.name == listenDeviceB })?.uid : nil

        if listenTogetherActive {
            coreAudio.disableListenTogether()
        }
        pipeline.primarySoftwareGain = pri.hasHardwareVolume ? 1.0 : primaryVolume
        if let sUID = secUID, let secDev = devices.first(where: { $0.uid == sUID }) {
            pipeline.secondarySoftwareGain = secDev.hasHardwareVolume ? 1.0 : secondaryVolume
        }

        pipelineStatus = pipeline.startGlobalPipeline(
            primaryOutputUID: pri.uid,
            secondaryOutputUID: secUID,
            virtualBusFallbackName: config.virtualOutputBus,
            dspSettings: builtInDSP
        )
    }

    // MARK: - Dual Output (Share Audio)

    public func setListenTogether(_ enabled: Bool) {
        let outs = physicalOutputDevices()
        if !enabled {
            listenTogetherActive = false
            coreAudio.disableListenTogether()

            if externalElementDSPEnabled, let pri = outs.first(where: { $0.name == selectedPhysicalOutputName }) {
                _ = coreAudio.ensureOutputProxy(targetDeviceUIDs: [pri.uid])
                _ = coreAudio.setDefaultOutputDevice(byName: config.virtualOutputBus)
            } else if builtInDSP.isEnabled {
                restartBuiltInPipelineIfNeeded()
            } else {
                _ = coreAudio.setDefaultOutputDevice(byName: selectedPhysicalOutputName)
            }
        } else {
            if !outs.contains(where: { $0.name == listenDeviceB && $0.name != selectedPhysicalOutputName }) {
                listenDeviceB = outs.first(where: { $0.name != selectedPhysicalOutputName })?.name ?? listenDeviceB
            }
            guard !listenDeviceB.isEmpty, listenDeviceB != selectedPhysicalOutputName else { return }

            config.listenTogetherDevices = [selectedPhysicalOutputName, listenDeviceB]
            try? config.save()
            listenTogetherActive = true

            if externalElementDSPEnabled {
                let uids = [selectedPhysicalOutputName, listenDeviceB].compactMap { name in
                    outs.first(where: { $0.name == name })?.uid
                }
                _ = coreAudio.ensureOutputProxy(targetDeviceUIDs: uids)
                _ = coreAudio.setDefaultOutputDevice(byName: config.virtualOutputBus)
            } else if builtInDSP.isEnabled {
                restartBuiltInPipelineIfNeeded()
            } else {
                _ = coreAudio.enableListenTogether(primaryDeviceName: selectedPhysicalOutputName, secondaryDeviceName: listenDeviceB)
            }
        }
        syncVolumesFromDevices()
        refreshDevices()
    }

    // MARK: - Optional External VST3 / AU Host (Element via Dynamic Aggregate Proxy)

    public func setExternalElementDSP(_ enabled: Bool) {
        externalElementDSPEnabled = enabled
        let outs = physicalOutputDevices()

        if enabled {
            if builtInDSP.isEnabled {
                pipeline.stopGlobalPipeline()
                pipelineStatus = .idle
                builtInDSP = BuiltInDSPSettings()
                config.builtInDSP = builtInDSP
                try? config.save()
            }

            var targetUIDs: [String] = []
            if let pri = outs.first(where: { $0.name == selectedPhysicalOutputName }) {
                targetUIDs.append(pri.uid)
            }
            if listenTogetherActive, let sec = outs.first(where: { $0.name == listenDeviceB }) {
                targetUIDs.append(sec.uid)
            }

            // Route Element through the hot-swappable Dynamic Aggregate Proxy so future headphone switches take <20ms
            let proxyCreated = coreAudio.ensureOutputProxy(targetDeviceUIDs: targetUIDs) != nil
            let elementOutTarget = proxyCreated ? CoreAudioManager.outputProxyName : selectedPhysicalOutputName

            try? xmlManager.updateElementHardwareDevices(
                inputDeviceName: config.virtualOutputBus,
                outputDeviceName: elementOutTarget,
                sampleRate: config.sampleRate,
                bufferSize: config.bufferSize
            )
            if !bridge.isElementRunning() {
                bridge.launchElement(sessionPath: config.element.sessionPath)
            } else {
                bridge.reloadElementWithSession(sessionPath: config.element.sessionPath)
            }
            _ = coreAudio.setDefaultOutputDevice(byName: config.virtualOutputBus)
        } else {
            coreAudio.destroyOutputProxy()
            if listenTogetherActive {
                _ = coreAudio.enableListenTogether(primaryDeviceName: selectedPhysicalOutputName, secondaryDeviceName: listenDeviceB)
            } else {
                _ = coreAudio.setDefaultOutputDevice(byName: selectedPhysicalOutputName)
            }
        }
        refreshDevices()
    }

    // MARK: - Dynamic Plugin Slots

    public func toggleSlotBypass(_ slot: PluginSlot) {
        let newBypass = !slot.bypass
        oscClient.setNodeBypass(bus: slot.bus, nodeId: slot.nodeId, slug: slot.slug, bypass: newBypass)
        try? xmlManager.updateSlotInSession(nodeId: slot.nodeId, bus: slot.bus, bypass: newBypass)
        refreshSlots()
    }

    public func updateSlotGain(_ slot: PluginSlot, gain: Float) {
        oscClient.setNodeGain(bus: slot.bus, nodeId: slot.nodeId, slug: slot.slug, gain: gain)
        try? xmlManager.updateSlotInSession(nodeId: slot.nodeId, bus: slot.bus, gain: gain)
        if slot.bus == .output, let idx = outputSlots.firstIndex(where: { $0.nodeId == slot.nodeId }) {
            outputSlots[idx].gain = gain
        } else if slot.bus == .input, let idx = inputSlots.firstIndex(where: { $0.nodeId == slot.nodeId }) {
            inputSlots[idx].gain = gain
        }
    }

    public func addPluginToBus(_ plugin: InstalledPlugin, bus: AudioBusType) {
        guard let _ = try? xmlManager.addPluginSlot(plugin: plugin, toBus: bus, initialBypass: false) else { return }
        refreshSlots()
        if bridge.isElementRunning() {
            bridge.reloadElementWithSession(sessionPath: config.element.sessionPath)
        }
    }

    public func removeSlot(_ slot: PluginSlot) {
        try? xmlManager.removePluginSlot(nodeId: slot.nodeId, fromBus: slot.bus)
        refreshSlots()
        if bridge.isElementRunning() {
            bridge.reloadElementWithSession(sessionPath: config.element.sessionPath)
        }
    }

    public func openElementGUI() {
        bridge.launchElement(sessionPath: config.element.sessionPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.elementRunning = self.bridge.isElementRunning()
        }
    }

    // MARK: - Output-Stage Per-App Mixer & Routing (Resettable to Default)

    public var hasCustomAppMixerChanges: Bool {
        !appMixerStates.isEmpty || !appRoutes.isEmpty
    }

    public func appVolume(for bundleId: String) -> Float {
        appMixerStates[bundleId]?.volume ?? 1.0
    }

    public func isAppMuted(_ bundleId: String) -> Bool {
        appMixerStates[bundleId]?.isMuted ?? false
    }

    public func setAppVolume(_ app: RunningAudioApp, volume: Float) {
        let existing = appMixerStates[app.bundleId]
        let clamped = max(0.0, min(2.0, volume))
        let snapped = (abs(clamped - 1.0) < 0.02 && !(existing?.isMuted ?? false) && existing?.targetDeviceUID == nil) ? 1.0 : clamped

        let nextState = AppMixerState(
            bundleId: app.bundleId,
            volume: snapped,
            isMuted: existing?.isMuted ?? false,
            targetDeviceUID: existing?.targetDeviceUID
        )
        if nextState.isDefault {
            appMixerStates.removeValue(forKey: app.bundleId)
        } else {
            appMixerStates[app.bundleId] = nextState
        }

        _ = pipeline.setAppMixerState(
            bundleID: app.bundleId,
            pid: app.pid,
            volume: nextState.volume,
            isMuted: nextState.isMuted,
            targetDeviceUID: nextState.targetDeviceUID
        )
        appRoutes = pipeline.activeAppRoutes()
    }

    public func toggleAppMute(_ app: RunningAudioApp) {
        let existing = appMixerStates[app.bundleId]
        let newMuted = !(existing?.isMuted ?? false)
        let vol = existing?.volume ?? 1.0
        let targetUID = existing?.targetDeviceUID

        let nextState = AppMixerState(
            bundleId: app.bundleId,
            volume: vol,
            isMuted: newMuted,
            targetDeviceUID: targetUID
        )
        if nextState.isDefault {
            appMixerStates.removeValue(forKey: app.bundleId)
        } else {
            appMixerStates[app.bundleId] = nextState
        }

        _ = pipeline.setAppMixerState(
            bundleID: app.bundleId,
            pid: app.pid,
            volume: nextState.volume,
            isMuted: nextState.isMuted,
            targetDeviceUID: nextState.targetDeviceUID
        )
        appRoutes = pipeline.activeAppRoutes()
    }

    public func routeApp(_ app: RunningAudioApp, toDevice device: AudioDeviceInfo?) {
        let existing = appMixerStates[app.bundleId]
        let vol = existing?.volume ?? 1.0
        let muted = existing?.isMuted ?? false
        let targetUID = device?.uid

        let nextState = AppMixerState(
            bundleId: app.bundleId,
            volume: vol,
            isMuted: muted,
            targetDeviceUID: targetUID
        )
        if nextState.isDefault {
            appMixerStates.removeValue(forKey: app.bundleId)
        } else {
            appMixerStates[app.bundleId] = nextState
        }

        _ = pipeline.setAppMixerState(
            bundleID: app.bundleId,
            pid: app.pid,
            volume: nextState.volume,
            isMuted: nextState.isMuted,
            targetDeviceUID: nextState.targetDeviceUID
        )
        appRoutes = pipeline.activeAppRoutes()
    }

    public func clearAppRoute(_ app: RunningAudioApp) {
        routeApp(app, toDevice: nil)
    }

    public func resetAllAppMixerToDefault() {
        bridge.resetAllApps()
        appMixerStates.removeAll()
        appRoutes.removeAll()
    }

    // MARK: - Loopback & Internal Audio Recorder

    public func virtualLoopbackDevices() -> [AudioDeviceInfo] {
        devices.filter { $0.hasOutput && $0.isVirtual }
    }

    public func loopbackBusOptions() -> [String] {
        var options: [String] = [CoreAudioManager.builtInVirtualMicName]
        for dev in virtualLoopbackDevices() where dev.name != CoreAudioManager.builtInVirtualMicName {
            options.append(dev.name)
        }
        return options
    }

    public func installBlackHoleDriver() {
        coreAudio.installBlackHoleViaTerminal()
    }

    private func resolvePhysicalMicID() -> UInt32? {
        if let curIn = currentInput, curIn.uid != CoreAudioManager.builtInVirtualMicUID, !curIn.isVirtual {
            return curIn.id
        }
        return devices.first(where: { $0.hasInput && !$0.isVirtual })?.id ?? coreAudio.getDefaultInputDevice()?.id
    }

    public func toggleLoopback(_ enabled: Bool) {
        if !enabled {
            pipeline.stopLoopback()
            loopbackActive = false
            refreshDevices()
            return
        }

        if !externalElementDSPEnabled,
           let curOut = coreAudio.getDefaultOutputDevice(),
           curOut.isVirtual || curOut.uid == CoreAudioManager.builtInVirtualMicUID {
            if let physDev = physicalOutputDevices().first(where: { $0.name == selectedPhysicalOutputName }) ?? physicalOutputDevices().first {
                _ = coreAudio.setDefaultOutputDevice(id: physDev.id)
            }
        }

        let selectedBus: String = loopbackBusOptions().contains(loopbackTargetBus)
            ? loopbackTargetBus
            : CoreAudioManager.builtInVirtualMicName
        loopbackTargetBus = selectedBus

        config.version = "2.0.0"
        config.loopback.virtualBusName = loopbackTargetBus
        config.loopback.includeMicrophone = loopbackIncludeMic
        config.loopback.micGain = loopbackMicGain
        config.loopback.loopbackGain = loopbackSystemGain
        try? config.save()

        pipeline.loopbackMicGain = loopbackMicGain
        pipeline.loopbackGain = loopbackSystemGain
        let micID: UInt32? = loopbackIncludeMic ? resolvePhysicalMicID() : nil

        if selectedBus == CoreAudioManager.builtInVirtualMicName {
            loopbackActive = pipeline.startLoopback(
                virtualTargetUID: CoreAudioManager.builtInVirtualMicUID,
                includeMic: loopbackIncludeMic,
                micDeviceID: micID
            )
        } else if let virtDev = devices.first(where: { $0.hasOutput && $0.name == selectedBus }) {
            loopbackActive = pipeline.startLoopback(
                virtualTargetUID: virtDev.uid,
                includeMic: loopbackIncludeMic,
                micDeviceID: micID
            )
        } else {
            loopbackActive = false
        }
        refreshDevices()
    }

    public func setLoopbackIncludeMic(_ include: Bool) {
        loopbackIncludeMic = include
        config.loopback.includeMicrophone = include
        try? config.save()
        if loopbackActive {
            toggleLoopback(true)
        }
    }

    public func setLoopbackMicGain(_ gain: Float) {
        let clamped = max(0.0, min(2.5, gain))
        loopbackMicGain = clamped
        pipeline.loopbackMicGain = clamped
        config.version = "2.0.0"
        config.loopback.micGain = clamped
        try? config.save()
    }

    public func setLoopbackSystemGain(_ gain: Float) {
        let clamped = max(0.0, min(2.0, gain))
        loopbackSystemGain = clamped
        pipeline.loopbackGain = clamped
        config.version = "2.0.0"
        config.loopback.loopbackGain = clamped
        try? config.save()
    }

    public func isAppIncludedInLoopback(_ bundleId: String) -> Bool {
        loopbackAppStates[bundleId]?.isIncluded ?? true
    }

    public func loopbackAppVolume(for bundleId: String) -> Float {
        loopbackAppStates[bundleId]?.volume ?? 1.0
    }

    public func toggleLoopbackAppIncluded(_ app: RunningAudioApp) {
        let nextIncluded = !isAppIncludedInLoopback(app.bundleId)
        let currentVol = loopbackAppVolume(for: app.bundleId)
        updateLoopbackAppState(bundleId: app.bundleId, isIncluded: nextIncluded, volume: currentVol)
    }

    public func setLoopbackAppVolume(_ app: RunningAudioApp, volume: Float) {
        let clamped = max(0.0, min(2.0, volume))
        let included = isAppIncludedInLoopback(app.bundleId)
        updateLoopbackAppState(bundleId: app.bundleId, isIncluded: included, volume: clamped)
    }

    private func updateLoopbackAppState(bundleId: String, isIncluded: Bool, volume: Float) {
        let next = LoopbackAppState(bundleId: bundleId, isIncluded: isIncluded, volume: volume)
        if next.isDefault {
            loopbackAppStates.removeValue(forKey: bundleId)
        } else {
            loopbackAppStates[bundleId] = next
        }
        pipeline.setLoopbackAppState(bundleID: bundleId, isIncluded: next.isIncluded, volume: next.volume)
    }

    public var hasCustomLoopbackMix: Bool {
        loopbackIncludeMic ||
        abs(loopbackMicGain - 1.8) > 0.02 ||
        abs(loopbackSystemGain - 1.0) > 0.02 ||
        !loopbackAppStates.isEmpty
    }

    public func resetLoopbackMixToDefault() {
        loopbackSystemGain = 1.0
        loopbackMicGain = 1.8
        loopbackAppStates.removeAll()
        pipeline.loopbackGain = 1.0
        pipeline.loopbackMicGain = 1.8
        config.version = "2.0.0"
        config.loopback.loopbackGain = 1.0
        config.loopback.micGain = 1.8
        try? config.save()
        pipeline.resetLoopbackAppStates()
    }

    public func cleanupOnQuit() {
        _ = pipeline.stopRecording()
        pipeline.stopLoopback()
    }

    public func toggleRecording() {
        if isRecording {
            recordUITimer?.invalidate()
            recordUITimer = nil
            if let url = pipeline.stopRecording() {
                lastRecordingURL = url
            }
            isRecording = false
            recordingSeconds = 0
        } else {
            pipeline.loopbackMicGain = loopbackMicGain
            pipeline.loopbackGain = loopbackSystemGain
            let micID = loopbackIncludeMic ? resolvePhysicalMicID() : nil
            if let url = pipeline.startRecording(to: nil, includeMic: loopbackIncludeMic, micDeviceID: micID) {
                isRecording = true
                recordingSeconds = 0
                lastRecordingURL = url
                recordUITimer?.invalidate()
                recordUITimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.recordingSeconds += 1
                    }
                }
            }
        }
    }

    public func revealLastRecordingInFinder() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openConfigFile() {
        let path = AudioMatrixConfig.defaultConfigPath
        if !FileManager.default.fileExists(atPath: path) {
            try? config.save(to: path)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

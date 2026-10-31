import Foundation
import CoreAudio
import AudioToolbox

public struct CoreAudioProcessInfo: Identifiable, Equatable {
    public var id: AudioObjectID { objectID }
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
}

public final class CoreAudioManager {
    public static let shared = CoreAudioManager()
    public static let listenTogetherUID = "com.audiomatrix.listentogether"
    public static let listenTogetherName = "Shared Audio Output"
    public static let outputProxyUID = "com.audiomatrix.proxy.output"
    public static let outputProxyName = "AudioMatrix Output Proxy"
    public static let builtInVirtualMicUID = "com.audiomatrix.virtual.mic"
    public static let builtInVirtualMicName = "AudioMatrix Virtual Mic"

    private let listenerQueue = DispatchQueue(label: "com.audiomatrix.coreaudio.listener")
    private var listenersRegistered = false
    private var pendingNotificationWorkItem: DispatchWorkItem?
    public var isUserSwitchingInput = false
    public var onDevicesChanged: (() -> Void)?
    public var onInputHijackPrevented: ((String, String) -> Void)?

    public init() {}

    // MARK: - Device Enumeration

    public func listDevices(includeInternal: Bool = false) -> [AudioDeviceInfo] {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        var infos: [AudioDeviceInfo] = []
        for devID in deviceIDs {
            guard let name = getDeviceStringProperty(devID, selector: kAudioObjectPropertyName),
                  let uid = getDeviceStringProperty(devID, selector: kAudioDevicePropertyDeviceUID) else {
                continue
            }
            if name.contains("CADefaultDeviceAggregate") || name.contains("MathematicsAdmissionTest") {
                continue
            }
            if !includeInternal && (uid == Self.outputProxyUID || uid.hasPrefix("com.audiomatrix.tap.")) {
                continue
            }
            let inChans = getChannelCount(devID, scope: kAudioObjectPropertyScopeInput)
            let outChans = getChannelCount(devID, scope: kAudioObjectPropertyScopeOutput)
            if inChans == 0 && outChans == 0 && uid != Self.listenTogetherUID && uid != Self.outputProxyUID {
                continue
            }
            let rate = getSampleRate(devID)
            let transport = (uid == Self.builtInVirtualMicUID) ? "Virtual" : getTransportTypeString(devID)
            let volInfo = getDeviceVolumeInfo(devID)

            infos.append(
                AudioDeviceInfo(
                    id: devID,
                    uid: uid,
                    name: name,
                    hasInput: inChans > 0,
                    hasOutput: outChans > 0,
                    sampleRate: rate,
                    transportType: transport,
                    volume: volInfo.volume,
                    hasHardwareVolume: volInfo.hasHardwareVolume
                )
            )
        }
        return infos
    }

    public func getDefaultInputDevice() -> AudioDeviceInfo? {
        guard let devID = getDefaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return listDevices(includeInternal: true).first(where: { $0.id == devID })
    }

    public func getDefaultOutputDevice() -> AudioDeviceInfo? {
        guard let devID = getDefaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return listDevices(includeInternal: true).first(where: { $0.id == devID })
    }

    public func device(withUID uid: String) -> AudioDeviceInfo? {
        return listDevices(includeInternal: true).first(where: { $0.uid == uid })
    }

    // MARK: - Hardware / Virtual Main Volume Control

    public func getDeviceVolume(_ deviceID: AudioObjectID) -> Float {
        return getDeviceVolumeInfo(deviceID).volume
    }

    public func getDeviceVolumeInfo(_ deviceID: AudioObjectID) -> (volume: Float, hasHardwareVolume: Bool) {
        var vmvcAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &vmvcAddr) {
            var vol: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &vmvcAddr, 0, nil, &size, &vol) == noErr {
                var settable: DarwinBoolean = false
                AudioObjectIsPropertySettable(deviceID, &vmvcAddr, &settable)
                return (max(0.0, min(1.0, vol)), settable.boolValue)
            }
        }

        var masterAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &masterAddr) {
            var vol: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &masterAddr, 0, nil, &size, &vol) == noErr {
                var settable: DarwinBoolean = false
                AudioObjectIsPropertySettable(deviceID, &masterAddr, &settable)
                return (max(0.0, min(1.0, vol)), settable.boolValue)
            }
        }

        var sum: Float = 0.0
        var count: Int = 0
        var anySettable = false
        for elem: UInt32 in [1, 2] {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: elem
            )
            if AudioObjectHasProperty(deviceID, &chAddr) {
                var vol: Float32 = 1.0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(deviceID, &chAddr, 0, nil, &size, &vol) == noErr {
                    sum += vol
                    count += 1
                    var settable: DarwinBoolean = false
                    AudioObjectIsPropertySettable(deviceID, &chAddr, &settable)
                    if settable.boolValue { anySettable = true }
                }
            }
        }

        if count > 0 {
            return (max(0.0, min(1.0, sum / Float(count))), anySettable)
        }
        return (1.0, false)
    }

    @discardableResult
    public func setDeviceVolume(_ deviceID: AudioObjectID, volume: Float) -> Bool {
        var clamped = Float32(max(0.0, min(1.0, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)

        var vmvcAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &vmvcAddr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &vmvcAddr, &settable) == noErr, settable.boolValue {
                if AudioObjectSetPropertyData(deviceID, &vmvcAddr, 0, nil, size, &clamped) == noErr {
                    return true
                }
            }
        }

        var masterAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &masterAddr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &masterAddr, &settable) == noErr, settable.boolValue {
                if AudioObjectSetPropertyData(deviceID, &masterAddr, 0, nil, size, &clamped) == noErr {
                    return true
                }
            }
        }

        var wroteAny = false
        for elem: UInt32 in [1, 2] {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: elem
            )
            if AudioObjectHasProperty(deviceID, &chAddr) {
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(deviceID, &chAddr, &settable) == noErr, settable.boolValue {
                    if AudioObjectSetPropertyData(deviceID, &chAddr, 0, nil, size, &clamped) == noErr {
                        wroteAny = true
                    }
                }
            }
        }
        return wroteAny
    }

    // MARK: - Independent Input / Output Switching

    @discardableResult
    public func setDefaultInputDevice(byName name: String) -> Bool {
        guard let dev = listDevices().first(where: { $0.hasInput && $0.name.localizedCaseInsensitiveContains(name) }) else {
            return false
        }
        return setDefaultInputDevice(id: dev.id)
    }

    @discardableResult
    public func setDefaultInputDevice(id: AudioObjectID) -> Bool {
        isUserSwitchingInput = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isUserSwitchingInput = false
            }
        }
        var mutableID = id
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableID
        )
        return status == noErr
    }

    @discardableResult
    public func setDefaultOutputDevice(byName name: String) -> Bool {
        guard let dev = listDevices(includeInternal: true).first(where: { $0.hasOutput && $0.name.localizedCaseInsensitiveContains(name) }) else {
            return false
        }
        return setDefaultOutputDevice(id: dev.id)
    }

    @discardableResult
    public func setDefaultOutputDevice(id: AudioObjectID) -> Bool {
        var mutableID = id
        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status1 = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &outAddr,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableID
        )

        var sysAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &sysAddr,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableID
        )
        return status1 == noErr
    }

    // MARK: - Dynamic Aggregate Output Proxy (<20ms Zero-Restart Headphone Hot-Swap)

    /// Creates or updates `"AudioMatrix Output Proxy"` (`com.audiomatrix.proxy.output`) in-place
    /// so external plugin hosts like Element never need to be restarted when switching headphones.
    @discardableResult
    public func ensureOutputProxy(targetDeviceUIDs: [String]) -> AudioObjectID? {
        let allOut = listDevices(includeInternal: false).filter { $0.hasOutput }
        let matchedDevices = targetDeviceUIDs.compactMap { uid in
            allOut.first(where: { $0.uid == uid })
        }
        guard let primary = matchedDevices.first else { return nil }

        var subDevices: [[String: Any]] = []
        for (idx, dev) in matchedDevices.enumerated() {
            setSampleRate(dev.id, rate: 48000.0)
            if idx == 0 {
                subDevices.append([
                    kAudioSubDeviceUIDKey as String: dev.uid,
                    kAudioSubDeviceDriftCompensationKey as String: 0
                ])
            } else {
                subDevices.append([
                    kAudioSubDeviceUIDKey as String: dev.uid,
                    kAudioSubDeviceDriftCompensationKey as String: 1,
                    kAudioSubDeviceDriftCompensationQualityKey as String: kAudioAggregateDriftCompensationHighQuality
                ])
            }
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: Self.outputProxyName,
            kAudioAggregateDeviceUIDKey as String: Self.outputProxyUID,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey as String: primary.uid,
            kAudioAggregateDeviceIsStackedKey as String: 1,
            kAudioAggregateDeviceIsPrivateKey as String: 0
        ]

        // Hot-swap subdevices in-place if the proxy already exists
        if let existingProxy = listDevices(includeInternal: true).first(where: { $0.uid == Self.outputProxyUID }) {
            let cfComp = composition as CFDictionary
            var unmanagedComp = Unmanaged.passUnretained(cfComp)
            var compAddr = AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyComposition,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                existingProxy.id,
                &compAddr,
                0,
                nil,
                UInt32(MemoryLayout<Unmanaged<CFDictionary>>.size),
                &unmanagedComp
            )
            if status == noErr {
                return existingProxy.id
            }
            _ = AudioHardwareDestroyAggregateDevice(existingProxy.id)
        }

        var aggregateID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != 0 else {
            return nil
        }
        return aggregateID
    }

    public func destroyOutputProxy() {
        for dev in listDevices(includeInternal: true) where dev.uid == Self.outputProxyUID {
            _ = AudioHardwareDestroyAggregateDevice(dev.id)
        }
    }

    // MARK: - Bluetooth Mic Hijack Guard

    public func enforceInputGuard(config: AudioMatrixConfig) {
        guard config.inputGuardEnabled, !isUserSwitchingInput else { return }
        let devices = listDevices()
        guard let currentIn = getDefaultInputDevice() else { return }

        let preferredIsBluetooth = config.preferredInputDevice.localizedCaseInsensitiveContains("AirPods")
        guard currentIn.isBluetooth && !preferredIsBluetooth else { return }

        let targetDevice = devices.first(where: { $0.hasInput && $0.name.localizedCaseInsensitiveContains(config.preferredInputDevice) })
            ?? devices.first(where: { $0.hasInput && $0.name.localizedCaseInsensitiveContains(config.fallbackInputDevice) })

        guard let target = targetDevice, currentIn.id != target.id else { return }

        let hijackerName = currentIn.name
        if setDefaultInputDevice(id: target.id) {
            onInputHijackPrevented?(hijackerName, target.name)
        }
    }

    public func startMonitoring(configProvider: @escaping () -> AudioMatrixConfig) {
        guard !listenersRegistered else { return }
        listenersRegistered = true

        var inAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let handler: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.pendingNotificationWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    let cfg = configProvider()
                    self.enforceInputGuard(config: cfg)
                    self.onDevicesChanged?()
                }
                self.pendingNotificationWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
            }
        }

        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inAddr, listenerQueue, handler)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outAddr, listenerQueue, handler)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, listenerQueue, handler)
    }

    // MARK: - Listen Together (Drift-Corrected Multi-Output Aggregate Device)

    public func isListenTogetherActive() -> Bool {
        return listDevices().contains(where: { $0.uid == Self.listenTogetherUID })
    }

    @discardableResult
    public func enableListenTogether(primaryDeviceName: String, secondaryDeviceName: String) -> AudioObjectID? {
        disableListenTogether()

        let devices = listDevices().filter { $0.hasOutput }
        guard let primary = devices.first(where: { $0.name.localizedCaseInsensitiveContains(primaryDeviceName) }),
              let secondary = devices.first(where: { $0.name.localizedCaseInsensitiveContains(secondaryDeviceName) }),
              primary.uid != secondary.uid else {
            return nil
        }

        setSampleRate(primary.id, rate: 48000.0)
        setSampleRate(secondary.id, rate: 48000.0)

        let subDevices: [[String: Any]] = [
            [
                kAudioSubDeviceUIDKey as String: primary.uid,
                kAudioSubDeviceDriftCompensationKey as String: 0
            ],
            [
                kAudioSubDeviceUIDKey as String: secondary.uid,
                kAudioSubDeviceDriftCompensationKey as String: 1,
                kAudioSubDeviceDriftCompensationQualityKey as String: kAudioAggregateDriftCompensationHighQuality
            ]
        ]

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: Self.listenTogetherName,
            kAudioAggregateDeviceUIDKey as String: Self.listenTogetherUID,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey as String: primary.uid,
            kAudioAggregateDeviceIsStackedKey as String: 1,
            kAudioAggregateDeviceIsPrivateKey as String: 0
        ]

        var aggregateID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != 0 else {
            return nil
        }

        _ = setDefaultOutputDevice(id: aggregateID)
        return aggregateID
    }

    public func disableListenTogether() {
        for dev in listDevices() where dev.uid == Self.listenTogetherUID {
            _ = AudioHardwareDestroyAggregateDevice(dev.id)
        }
    }

    // MARK: - CoreAudio Process Discovery (macOS 14.2+)

    public func listAudioProcesses() -> [CoreAudioProcessInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &procIDs) == noErr else {
            return []
        }

        var result: [CoreAudioProcessInfo] = []
        for pidObj in procIDs {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(pidObj, &pidAddr, 0, nil, &pidSize, &pid)

            let bundleID = getDeviceStringProperty(pidObj, selector: kAudioProcessPropertyBundleID) ?? ""

            var runningOut: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(pidObj, &runAddr, 0, nil, &runSize, &runningOut)

            if pid > 0 && !bundleID.isEmpty {
                result.append(CoreAudioProcessInfo(
                    objectID: pidObj,
                    pid: pid,
                    bundleID: bundleID,
                    isRunningOutput: runningOut != 0
                ))
            }
        }
        return result
    }

    public func processObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var pidVar = pid
        var objID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pidVar,
            &size,
            &objID
        ) == noErr, objID != 0 else {
            return nil
        }
        return objID
    }

    /// Returns all active CoreAudio ProcessObject IDs belonging to `bundleID`
    /// (including helper/renderer subprocesses such as Chrome/Discord renderers).
    public func processObjectIDs(forBundleID bundleID: String, fallbackPID: pid_t? = nil) -> [AudioObjectID] {
        var ids: [AudioObjectID] = []
        var seen = Set<AudioObjectID>()
        for proc in listAudioProcesses() {
            if proc.bundleID == bundleID || proc.bundleID.hasPrefix(bundleID + ".") {
                if seen.insert(proc.objectID).inserted {
                    ids.append(proc.objectID)
                }
            }
        }
        if let pid = fallbackPID, let obj = processObjectID(forPID: pid), seen.insert(obj).inserted {
            ids.append(obj)
        }
        return ids
    }

    // MARK: - Sample Rate Alignment & HAL Drivers

    public func alignAllDevicesTo48kHz() -> Int {
        var updatedCount = 0
        for dev in listDevices() {
            if abs(dev.sampleRate - 48000.0) > 1.0 {
                if setSampleRate(dev.id, rate: 48000.0) {
                    updatedCount += 1
                }
            }
        }
        return updatedCount
    }

    @discardableResult
    public func setSampleRate(_ deviceID: AudioObjectID, rate: Double) -> Bool {
        var mutableRate = rate
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &mutableRate
        )
        return status == noErr
    }

    public func listInstalledHALDrivers() -> [String] {
        let halPath = "/Library/Audio/Plug-Ins/HAL"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: halPath) else { return [] }
        return items.filter { $0.hasSuffix(".driver") }.sorted()
    }

    // MARK: - Built-in Virtual Cable Cleanup & Optional Dependency Installer

    public func destroyStaleBuiltInVirtualMic() {
        for dev in listDevices(includeInternal: true) where dev.uid == Self.builtInVirtualMicUID {
            _ = AudioHardwareDestroyAggregateDevice(dev.id)
        }
    }

    public func isBlackHoleInstalled() -> Bool {
        if FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver") {
            return true
        }
        return listDevices(includeInternal: true).contains { $0.name.localizedCaseInsensitiveContains("BlackHole") }
    }

    public func installBlackHoleViaTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "echo 'Installing BlackHole 2ch virtual audio driver via Homebrew...'; if ! command -v brew >/dev/null 2>&1; then echo 'Homebrew not found. Opening https://existential.audio/blackhole/'; open 'https://existential.audio/blackhole/'; else brew install --cask blackhole-2ch; fi"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    // MARK: - Private CoreAudio Helpers

    private func getDefaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var devID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != 0 else {
            return nil
        }
        return devID
    }

    private func getDeviceStringProperty(_ devID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &cfStr)
        guard status == noErr, let unwrapped = cfStr?.takeUnretainedValue() else { return nil }
        return unwrapped as String
    }

    private func getChannelCount(_ devID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPtr.deallocate() }

        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, rawPtr) == noErr else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func getSampleRate(_ devID: AudioObjectID) -> Double {
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &rate)
        return rate
    }

    private func getTransportTypeString(_ devID: AudioObjectID) -> String {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &transport) == noErr else { return "Hardware" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Shared"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "DisplayPort"
        default: return "Hardware"
        }
    }
}

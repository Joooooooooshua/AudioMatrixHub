import Foundation
import CoreAudio
import AudioToolbox
import Darwin
import os.lock
import CAudioMatrixRust

// MARK: - Lock-Free SPSC Stereo Audio Ring Buffer (Rust C-ABI)

/// Zero-allocation, lock-free Single-Producer Single-Consumer (SPSC) ring buffer
/// backed by `AmRingBuffer` (`libaudiomatrix_rust_core.a`) using Acquire/Release atomics.
public final class LockFreeAudioRingBuffer {
    public let capacityFrames: Int
    private let rustRing: OpaquePointer

    public init(capacityFrames: Int = 32768) {
        var pow2 = 256
        while pow2 < capacityFrames {
            pow2 <<= 1
        }
        self.capacityFrames = pow2
        guard let ptr = am_ring_create(pow2) else {
            fatalError("Failed to allocate Rust AmRingBuffer")
        }
        self.rustRing = ptr
    }

    deinit {
        am_ring_destroy(rustRing)
    }

    public func reset() {
        am_ring_reset(rustRing)
    }

    public func availableToRead() -> Int {
        Int(am_ring_available_frames(rustRing))
    }

    public func availableToWrite() -> Int {
        max(0, capacityFrames - availableToRead())
    }

    @discardableResult
    public func write(from src: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        return Int(am_ring_write(rustRing, src, frameCount))
    }

    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        return Int(am_ring_read(rustRing, dst, frameCount))
    }

    public func readOrZero(into dst: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        let readCount = read(into: dst, frameCount: frameCount)
        if readCount < frameCount {
            let missingSamples = (frameCount - readCount) * 2
            dst.advanced(by: readCount * 2).initialize(repeating: 0.0, count: missingSamples)
        }
        return readCount
    }
}

// MARK: - Native CoreAudio Process Tap + Ring Buffer Audio Relay

public enum NativePipelineStatus: Equatable {
    case idle
    case runningProcessTap
    case runningVirtualBus
    case permissionRequired
    case error(String)
}

/// Manages real-time capture from CoreAudio Process Taps (`CATapDescription` + `AudioHardwareCreateProcessTap`)
/// or virtual loopback buses, applies `BuiltInDSPEngine`, and outputs to one or two target physical devices
/// via lock-free SPSC ring buffers with independent per-output software volume multipliers.
public final class NativeAudioPipeline {
    public static let shared = NativeAudioPipeline()

    public let dspEngine = BuiltInDSPEngine()

    // Independent software volume multipliers (atomic-like unfair lock protection for real-time IOProcs)
    private var gainLock = os_unfair_lock_s()
    private var _primaryGain: Float = 1.0
    private var _secondaryGain: Float = 1.0

    public var primarySoftwareGain: Float {
        get {
            os_unfair_lock_lock(&gainLock)
            let v = _primaryGain
            os_unfair_lock_unlock(&gainLock)
            return v
        }
        set {
            os_unfair_lock_lock(&gainLock)
            _primaryGain = max(0.0, min(2.0, newValue))
            os_unfair_lock_unlock(&gainLock)
        }
    }

    public var secondarySoftwareGain: Float {
        get {
            os_unfair_lock_lock(&gainLock)
            let v = _secondaryGain
            os_unfair_lock_unlock(&gainLock)
            return v
        }
        set {
            os_unfair_lock_lock(&gainLock)
            _secondaryGain = max(0.0, min(2.0, newValue))
            os_unfair_lock_unlock(&gainLock)
        }
    }

    // Active global pipeline handles
    private var globalTapID: AudioObjectID = 0
    private var globalTapAggregateID: AudioObjectID = 0
    private var globalCaptureDeviceID: AudioObjectID = 0
    private var globalCaptureIOProc: AudioDeviceIOProcID?

    private var primaryOutDeviceID: AudioObjectID = 0
    private var primaryOutIOProc: AudioDeviceIOProcID?
    private let primaryRing = LockFreeAudioRingBuffer(capacityFrames: 32768)

    private var secondaryOutDeviceID: AudioObjectID = 0
    private var secondaryOutIOProc: AudioDeviceIOProcID?
    private let secondaryRing = LockFreeAudioRingBuffer(capacityFrames: 32768)

    private var hasSecondaryOutput: Bool = false

    // Pre-allocated real-time scratch buffers (max 4096 stereo frames per callback)
    private static let maxIOFrames = 4096
    private let captureScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private let primaryScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private let secondaryScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)

    // Per-app active tap sessions keyed by bundleID
    private final class AppTapRoute {
        let bundleID: String
        var tapID: AudioObjectID = 0
        var tapAggregateID: AudioObjectID = 0
        var captureIOProc: AudioDeviceIOProcID?
        var outDeviceID: AudioObjectID = 0
        var outIOProc: AudioDeviceIOProcID?
        var ring = LockFreeAudioRingBuffer(capacityFrames: 16384)
        var volume: Float = 1.0
        let captureScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
        let outScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)

        init(bundleID: String) {
            self.bundleID = bundleID
        }

        deinit {
            captureScratch.deallocate()
            outScratch.deallocate()
        }
    }

    private var appRoutes: [String: AppTapRoute] = [:]
    private var appMixerStates: [String: AppMixerState] = [:]
    private let stateLock = NSLock()

    // Live Virtual Mic Loopback handles (non-muting global tap + optional mic -> virtual input bus)
    public private(set) var isLoopbackActive: Bool = false
    public var loopbackGain: Float = 1.0
    public var loopbackMicGain: Float = 1.8
    private var loopbackIncludeMic: Bool = false
    private var loopbackTapID: AudioObjectID = 0
    private var loopbackTapAggID: AudioObjectID = 0
    private var loopbackCapProc: AudioDeviceIOProcID?
    private var loopbackMicDeviceID: AudioObjectID = 0
    private var loopbackMicProc: AudioDeviceIOProcID?
    private var loopbackTargetDeviceID: AudioObjectID = 0
    private var loopbackOutProc: AudioDeviceIOProcID?
    private var builtInVirtualMicTapID: AudioObjectID = 0
    private var builtInVirtualMicAggID: AudioObjectID = 0
    private var activeLoopbackTargetUID: String = ""
    private var activeLoopbackRequestedIncludeMic: Bool = false
    private var activeLoopbackRequestedMicID: AudioObjectID?
    private var loopbackAppStates: [String: LoopbackAppState] = [:]
    private var loopbackCustomAppTaps: [String: AppTapRoute] = [:]
    private var loopbackCustomTapSnapshot: [AppTapRoute] = []
    private var customTapSnapshotLock = os_unfair_lock_s()
    private let loopbackSysRing = LockFreeAudioRingBuffer(capacityFrames: 32768)
    private let loopbackMicRing = LockFreeAudioRingBuffer(capacityFrames: 32768)
    private let loopbackCapScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private let loopbackMicInScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private let loopbackSysOutScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private let loopbackMicOutScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private let loopbackCustomAppScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private let loopbackMixScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)

    // Internal Audio WAV Recorder handles
    public private(set) var isRecording: Bool = false
    public private(set) var lastRecordedFileURL: URL?
    private var recordTapID: AudioObjectID = 0
    private var recordTapAggID: AudioObjectID = 0
    private var recordCapProc: AudioDeviceIOProcID?
    private var recordIncludeMic: Bool = false
    private var recordMicDeviceID: AudioObjectID = 0
    private var recordMicProc: AudioDeviceIOProcID?
    private let recordMicRing = LockFreeAudioRingBuffer(capacityFrames: 32768)
    private let recordRing = LockFreeAudioRingBuffer(capacityFrames: 65536)
    private let recordCapScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private let recordMicInScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private let recordMicMixScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxIOFrames * 2)
    private var recordDrainScratch = [Float](repeating: 0.0, count: 8192 * 2)
    private var recordTimer: DispatchSourceTimer?
    private var recordFileHandle: FileHandle?
    private var recordFileURL: URL?
    private var recordedDataBytes: UInt32 = 0
    private let recordWriteQueue = DispatchQueue(label: "com.audiomatrix.recorder.writer")

    public private(set) var status: NativePipelineStatus = .idle

    public init() {
        CoreAudioManager.shared.destroyStaleBuiltInVirtualMic()
    }

    deinit {
        _ = stopRecording()
        stopLoopback()
        stopGlobalPipeline()
        stopAllAppRoutes()
        captureScratch.deallocate()
        primaryScratch.deallocate()
        secondaryScratch.deallocate()
        loopbackCapScratch.deallocate()
        loopbackMicInScratch.deallocate()
        loopbackSysOutScratch.deallocate()
        loopbackMicOutScratch.deallocate()
        loopbackCustomAppScratch.deallocate()
        loopbackMixScratch.deallocate()
        recordCapScratch.deallocate()
        recordMicInScratch.deallocate()
        recordMicMixScratch.deallocate()
    }

    // MARK: - Global Built-in DSP & Dual-Output Pipeline

    /// Starts the built-in DSP capture -> process -> playback pipeline.
    /// Attempts native macOS 14.2+ CoreAudio Global Process Tap first (excluding self PID so system volume keys keep working);
    /// if TCC permission is unavailable or tap creation fails, falls back to capturing `virtualBusName` (BlackHole 2ch) if present.
    @discardableResult
    public func startGlobalPipeline(
        primaryOutputUID: String,
        secondaryOutputUID: String? = nil,
        virtualBusFallbackName: String = "BlackHole 2ch",
        dspSettings: BuiltInDSPSettings
    ) -> NativePipelineStatus {
        stateLock.lock()
        defer { stateLock.unlock() }

        stopGlobalPipelineLocked()
        dspEngine.updateSettings(dspSettings)

        let coreAudio = CoreAudioManager.shared
        guard let primaryDev = coreAudio.device(withUID: primaryOutputUID) else {
            status = .error("Primary output device not found")
            return status
        }

        coreAudio.setSampleRate(primaryDev.id, rate: 48000.0)
        dspEngine.setSampleRate(48000.0)
        dspEngine.resetState()
        primaryRing.reset()
        secondaryRing.reset()

        var secondaryDev: AudioDeviceInfo? = nil
        if let secUID = secondaryOutputUID, secUID != primaryOutputUID, let foundSec = coreAudio.device(withUID: secUID) {
            coreAudio.setSampleRate(foundSec.id, rate: 48000.0)
            secondaryDev = foundSec
        }
        hasSecondaryOutput = (secondaryDev != nil)

        // Attempt 1: Native macOS 14.2+ Global Process Tap excluding our own process
        if #available(macOS 14.2, *), startGlobalProcessTapCapture(targetOutputUID: primaryOutputUID) {
            if startOutputPlayback(primary: primaryDev, secondary: secondaryDev) {
                status = .runningProcessTap
                return status
            }
            stopGlobalPipelineLocked()
        }

        // Attempt 2: Fallback to Virtual Bus (e.g. BlackHole 2ch)
        if let busDev = coreAudio.listDevices(includeInternal: true).first(where: {
            $0.hasInput && $0.name.localizedCaseInsensitiveContains(virtualBusFallbackName)
        }) {
            if startDeviceCapture(deviceID: busDev.id) && startOutputPlayback(primary: primaryDev, secondary: secondaryDev) {
                status = .runningVirtualBus
                return status
            }
            stopGlobalPipelineLocked()
        }

        status = .permissionRequired
        return status
    }

    public func stopGlobalPipeline() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopGlobalPipelineLocked()
    }

    private func stopGlobalPipelineLocked() {
        if let ioProc = globalCaptureIOProc, globalCaptureDeviceID != 0 {
            _ = AudioDeviceStop(globalCaptureDeviceID, ioProc)
            _ = AudioDeviceDestroyIOProcID(globalCaptureDeviceID, ioProc)
        }
        globalCaptureIOProc = nil
        globalCaptureDeviceID = 0

        if let ioProc = primaryOutIOProc, primaryOutDeviceID != 0 {
            _ = AudioDeviceStop(primaryOutDeviceID, ioProc)
            _ = AudioDeviceDestroyIOProcID(primaryOutDeviceID, ioProc)
        }
        primaryOutIOProc = nil
        primaryOutDeviceID = 0

        if let ioProc = secondaryOutIOProc, secondaryOutDeviceID != 0 {
            _ = AudioDeviceStop(secondaryOutDeviceID, ioProc)
            _ = AudioDeviceDestroyIOProcID(secondaryOutDeviceID, ioProc)
        }
        secondaryOutIOProc = nil
        secondaryOutDeviceID = 0

        if globalTapAggregateID != 0 {
            _ = AudioHardwareDestroyAggregateDevice(globalTapAggregateID)
            globalTapAggregateID = 0
        }
        if #available(macOS 14.2, *), globalTapID != 0 {
            _ = AudioHardwareDestroyProcessTap(globalTapID)
            globalTapID = 0
        }

        hasSecondaryOutput = false
        status = .idle
    }

    @available(macOS 14.2, *)
    private func startGlobalProcessTapCapture(targetOutputUID: String) -> Bool {
        let coreAudio = CoreAudioManager.shared
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var excludeObjects: [AudioObjectID] = []
        if let selfObj = coreAudio.processObjectID(forPID: selfPID) {
            excludeObjects.append(selfObj)
        }

        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeObjects)
        tapDesc.name = "AudioMatrix Global DSP Tap"
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped

        var tapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard tapStatus == noErr, tapID != 0 else {
            return false
        }
        globalTapID = tapID

        let aggUID = "com.audiomatrix.tap.global.\(UUID().uuidString)"
        let tapList: [[String: Any]] = [
            [
                kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey as String: 1
            ]
        ]
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AudioMatrix Global Tap Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceTapListKey as String: tapList,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapAutoStartKey as String: 1
        ]

        var aggID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard aggStatus == noErr, aggID != 0 else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            globalTapID = 0
            return false
        }
        globalTapAggregateID = aggID

        return startDeviceCapture(deviceID: aggID)
    }

    private func startDeviceCapture(deviceID: AudioObjectID) -> Bool {
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self = self else { return }
            let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let frameCount = Self.extractStereoInterleaved(from: bufList, into: self.captureScratch, maxFrames: Self.maxIOFrames)
            guard frameCount > 0 else { return }

            let bufPtr = UnsafeMutableBufferPointer(start: self.captureScratch, count: frameCount * 2)
            self.dspEngine.processStereoInterleaved(bufPtr, frameCount: frameCount)

            self.primaryRing.write(from: self.captureScratch, frameCount: frameCount)
            if self.hasSecondaryOutput {
                self.secondaryRing.write(from: self.captureScratch, frameCount: frameCount)
            }
        }
        guard status == noErr, let createdProc = ioProcID else {
            return false
        }

        let startStatus = AudioDeviceStart(deviceID, createdProc)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(deviceID, createdProc)
            return false
        }

        globalCaptureDeviceID = deviceID
        globalCaptureIOProc = createdProc
        return true
    }

    private func startOutputPlayback(primary: AudioDeviceInfo, secondary: AudioDeviceInfo?) -> Bool {
        // Primary Output IOProc
        var pProc: AudioDeviceIOProcID?
        let pCreate = AudioDeviceCreateIOProcIDWithBlock(&pProc, primary.id, nil) { [weak self] _, _, _, outOutputData, _ in
            guard let self = self else { return }
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
            let frameCount = Self.frameCount(of: outList, maxFrames: Self.maxIOFrames)
            guard frameCount > 0 else { return }

            _ = self.primaryRing.readOrZero(into: self.primaryScratch, frameCount: frameCount)
            let gain = self.primarySoftwareGain
            Self.writeStereoInterleaved(from: self.primaryScratch, frameCount: frameCount, gain: gain, into: outList)
        }
        guard pCreate == noErr, let createdPrimary = pProc, AudioDeviceStart(primary.id, createdPrimary) == noErr else {
            if let created = pProc { _ = AudioDeviceDestroyIOProcID(primary.id, created) }
            return false
        }
        primaryOutDeviceID = primary.id
        primaryOutIOProc = createdPrimary

        if let sec = secondary {
            var sProc: AudioDeviceIOProcID?
            let sCreate = AudioDeviceCreateIOProcIDWithBlock(&sProc, sec.id, nil) { [weak self] _, _, _, outOutputData, _ in
                guard let self = self else { return }
                let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
                let frameCount = Self.frameCount(of: outList, maxFrames: Self.maxIOFrames)
                guard frameCount > 0 else { return }

                _ = self.secondaryRing.readOrZero(into: self.secondaryScratch, frameCount: frameCount)
                let gain = self.secondarySoftwareGain
                Self.writeStereoInterleaved(from: self.secondaryScratch, frameCount: frameCount, gain: gain, into: outList)
            }
            if sCreate == noErr, let createdSec = sProc, AudioDeviceStart(sec.id, createdSec) == noErr {
                secondaryOutDeviceID = sec.id
                secondaryOutIOProc = createdSec
            } else if let createdSec = sProc {
                _ = AudioDeviceDestroyIOProcID(sec.id, createdSec)
            }
        }
        return true
    }

    // MARK: - Native Per-App Routing Engine (CoreAudio Process Tap)

    public func activeAppRoutes() -> [String: String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        var map: [String: String] = [:]
        for (bundleID, route) in appRoutes {
            if let dev = CoreAudioManager.shared.listDevices().first(where: { $0.id == route.outDeviceID }) {
                map[bundleID] = dev.uid
            }
        }
        return map
    }

    /// Routes a specific application's audio natively to `targetDeviceUID` using macOS 14.2+ `CATapDescription`.
    @discardableResult
    public func routeApp(bundleID: String, pid: pid_t, toDeviceUID targetUID: String, volume: Float = 1.0) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }

        removeAppRouteLocked(bundleID: bundleID)

        let coreAudio = CoreAudioManager.shared
        let procObjIDs = coreAudio.processObjectIDs(forBundleID: bundleID, fallbackPID: pid)
        guard let targetDev = coreAudio.device(withUID: targetUID),
              !procObjIDs.isEmpty else {
            return false
        }

        let tapDesc = CATapDescription(stereoMixdownOfProcesses: procObjIDs)
        tapDesc.name = "AudioMatrix Tap \(bundleID)"
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        // Virtual targets use a non-muting side-tap so headphones remain unaffected
        tapDesc.muteBehavior = targetDev.isVirtual ? .unmuted : .mutedWhenTapped

        var tapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr, tapID != 0 else {
            return false
        }

        let aggUID = "com.audiomatrix.tap.app.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AudioMatrix App Tap \(bundleID)",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
            ],
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapAutoStartKey as String: 1
        ]

        var aggID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID) == noErr, aggID != 0 else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            return false
        }

        let route = AppTapRoute(bundleID: bundleID)
        route.tapID = tapID
        route.tapAggregateID = aggID
        route.outDeviceID = targetDev.id
        route.volume = max(0.0, min(2.0, volume))

        var capProc: AudioDeviceIOProcID?
        let capCreate = AudioDeviceCreateIOProcIDWithBlock(&capProc, aggID, nil) { _, inInputData, _, _, _ in
            let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let frames = Self.extractStereoInterleaved(from: bufList, into: route.captureScratch, maxFrames: Self.maxIOFrames)
            if frames > 0 {
                route.ring.write(from: route.captureScratch, frameCount: frames)
            }
        }
        guard capCreate == noErr, let createdCap = capProc, AudioDeviceStart(aggID, createdCap) == noErr else {
            if let createdCap = capProc { _ = AudioDeviceDestroyIOProcID(aggID, createdCap) }
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        route.captureIOProc = createdCap

        var outProc: AudioDeviceIOProcID?
        let outCreate = AudioDeviceCreateIOProcIDWithBlock(&outProc, targetDev.id, nil) { _, _, _, outOutputData, _ in
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
            let frames = Self.frameCount(of: outList, maxFrames: Self.maxIOFrames)
            guard frames > 0 else { return }
            _ = route.ring.readOrZero(into: route.outScratch, frameCount: frames)
            Self.writeStereoInterleaved(from: route.outScratch, frameCount: frames, gain: route.volume, into: outList)
        }
        guard outCreate == noErr, let createdOut = outProc, AudioDeviceStart(targetDev.id, createdOut) == noErr else {
            if let createdOut = outProc { _ = AudioDeviceDestroyIOProcID(targetDev.id, createdOut) }
            _ = AudioDeviceStop(aggID, createdCap)
            _ = AudioDeviceDestroyIOProcID(aggID, createdCap)
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        route.outIOProc = createdOut
        appRoutes[bundleID] = route
        return true
    }

    public func setAppVolume(bundleID: String, volume: Float) {
        stateLock.lock()
        let clamped = max(0.0, min(2.0, volume))
        appRoutes[bundleID]?.volume = clamped
        if var existing = appMixerStates[bundleID] {
            existing.volume = clamped
            appMixerStates[bundleID] = existing
        }
        stateLock.unlock()
    }

    /// Non-destructive output-stage per-app gain, mute, and device routing.
    @discardableResult
    public func setAppMixerState(
        bundleID: String,
        pid: pid_t?,
        volume: Float,
        isMuted: Bool,
        targetDeviceUID: String?
    ) -> Bool {
        let clampedVol = max(0.0, min(2.0, volume))
        let state = AppMixerState(
            bundleId: bundleID,
            volume: clampedVol,
            isMuted: isMuted,
            targetDeviceUID: targetDeviceUID
        )

        let coreAudio = CoreAudioManager.shared
        let effectiveGain: Float = isMuted ? 0.0 : clampedVol
        let resolvedTargetDev = targetDeviceUID.flatMap({ coreAudio.device(withUID: $0) }) ?? coreAudio.getDefaultOutputDevice()

        stateLock.lock()
        if state.isDefault {
            appMixerStates.removeValue(forKey: bundleID)
            if let existing = appRoutes[bundleID] {
                if let targetDev = resolvedTargetDev, existing.outDeviceID == targetDev.id {
                    // Keep the active tap alive while dragging across 100% to avoid CoreAudio tap thrashing
                    existing.volume = 1.0
                } else {
                    removeAppRouteLocked(bundleID: bundleID)
                }
            }
            stateLock.unlock()
            return true
        }

        guard let targetDev = resolvedTargetDev else {
            stateLock.unlock()
            return false
        }

        appMixerStates[bundleID] = state
        if let existing = appRoutes[bundleID], existing.outDeviceID == targetDev.id {
            existing.volume = effectiveGain
            stateLock.unlock()
            return true
        }
        stateLock.unlock()

        let resolvedPID = pid ?? coreAudio.listAudioProcesses().first(where: { $0.bundleID == bundleID })?.pid
        guard let targetPID = resolvedPID else { return false }

        let ok = routeApp(bundleID: bundleID, pid: targetPID, toDeviceUID: targetDev.uid, volume: effectiveGain)
        if !ok {
            stateLock.lock()
            appMixerStates.removeValue(forKey: bundleID)
            stateLock.unlock()
        }
        return ok
    }

    public func getAppMixerStates() -> [String: AppMixerState] {
        stateLock.lock()
        let copy = appMixerStates
        stateLock.unlock()
        return copy
    }

    public func removeAppRoute(bundleID: String) {
        stateLock.lock()
        appMixerStates.removeValue(forKey: bundleID)
        removeAppRouteLocked(bundleID: bundleID)
        stateLock.unlock()
    }

    public func stopAllAppRoutes() {
        stateLock.lock()
        let keys = Array(appRoutes.keys)
        for key in keys {
            removeAppRouteLocked(bundleID: key)
        }
        appMixerStates.removeAll()
        stateLock.unlock()
    }

    // MARK: - Live Virtual Mic Loopback & Independent Multi-Channel Mixer

    private var isLoopbackPushingExternalBus: Bool {
        isLoopbackActive && loopbackOutProc != nil
    }

    public func getLoopbackAppStates() -> [String: LoopbackAppState] {
        stateLock.lock()
        let copy = loopbackAppStates
        stateLock.unlock()
        return copy
    }

    public func setLoopbackAppState(bundleID: String, isIncluded: Bool, volume: Float) {
        let clampedVol = max(0.0, min(2.0, volume))
        let next = LoopbackAppState(bundleId: bundleID, isIncluded: isIncluded, volume: clampedVol)

        stateLock.lock()
        let previous = loopbackAppStates[bundleID]
        if next.isDefault {
            loopbackAppStates.removeValue(forKey: bundleID)
        } else {
            loopbackAppStates[bundleID] = next
        }

        // Keep an existing custom Loopback tap alive in-place when sliding across 100%
        if isIncluded, (previous?.isIncluded ?? true),
           let existingTap = loopbackCustomAppTaps[bundleID] {
            existingTap.volume = clampedVol
            stateLock.unlock()
            return
        }

        rebuildActiveLoopbackAndRecorderLocked()
        stateLock.unlock()
    }

    public func resetLoopbackAppStates() {
        stateLock.lock()
        loopbackAppStates.removeAll()
        loopbackGain = 1.0
        rebuildActiveLoopbackAndRecorderLocked()
        stateLock.unlock()
    }

    private func rebuildActiveLoopbackAndRecorderLocked() {
        guard #available(macOS 14.2, *) else { return }
        if isLoopbackActive {
            _ = startLoopbackLocked(
                virtualTargetUID: activeLoopbackTargetUID,
                includeMic: activeLoopbackRequestedIncludeMic,
                micDeviceID: activeLoopbackRequestedMicID
            )
        } else if isRecording && !isLoopbackPushingExternalBus {
            let prevRecIncludeMic = recordIncludeMic
            let prevRecMicID = recordMicDeviceID
            stopStandaloneRecordTapLocked()
            _ = startStandaloneRecordTap(includeMic: prevRecIncludeMic, micDeviceID: prevRecMicID == 0 ? nil : prevRecMicID)
        }
    }

    @available(macOS 14.2, *)
    private func buildLoopbackExclusionAndCustomTapsLocked(
        baseExcluded: [AudioObjectID],
        createCustomTaps: Bool
    ) -> [AudioObjectID] {
        stopAllLoopbackCustomTapsLocked()

        let coreAudio = CoreAudioManager.shared
        var excluded = baseExcluded
        var seenExcluded = Set(baseExcluded)
        let audioProcs = coreAudio.listAudioProcesses()

        for (bundleID, state) in loopbackAppStates {
            let matchingPID = audioProcs.first(where: {
                $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".")
            })?.pid
            let objIDs = coreAudio.processObjectIDs(forBundleID: bundleID, fallbackPID: matchingPID)
            guard !objIDs.isEmpty else { continue }

            let needsExcludeFromGlobal = !state.isIncluded || (createCustomTaps && abs(state.volume - 1.0) > 0.01)
            if needsExcludeFromGlobal {
                for obj in objIDs where seenExcluded.insert(obj).inserted {
                    excluded.append(obj)
                }
            }

            if createCustomTaps && state.isIncluded && abs(state.volume - 1.0) > 0.01 {
                if let customRoute = startNonMutingLoopbackAppTap(bundleID: bundleID, processObjectIDs: objIDs, volume: state.volume) {
                    loopbackCustomAppTaps[bundleID] = customRoute
                }
            }
        }

        os_unfair_lock_lock(&customTapSnapshotLock)
        loopbackCustomTapSnapshot = Array(loopbackCustomAppTaps.values)
        os_unfair_lock_unlock(&customTapSnapshotLock)
        return excluded
    }

    @available(macOS 14.2, *)
    private func startNonMutingLoopbackAppTap(
        bundleID: String,
        processObjectIDs: [AudioObjectID],
        volume: Float
    ) -> AppTapRoute? {
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDesc.name = "AudioMatrix Loopback App \(bundleID)"
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted // Never mute headphones!

        var tapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr, tapID != 0 else {
            return nil
        }

        let aggUID = "com.audiomatrix.tap.lbmix.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AudioMatrix Loopback App Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
            ],
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapAutoStartKey as String: 1
        ]

        var aggID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID) == noErr, aggID != 0 else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let route = AppTapRoute(bundleID: bundleID)
        route.tapID = tapID
        route.tapAggregateID = aggID
        route.volume = volume

        var capProc: AudioDeviceIOProcID?
        let capCreate = AudioDeviceCreateIOProcIDWithBlock(&capProc, aggID, nil) { _, inInputData, _, _, _ in
            let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let frames = Self.extractStereoInterleaved(from: bufList, into: route.captureScratch, maxFrames: Self.maxIOFrames)
            if frames > 0 {
                route.ring.write(from: route.captureScratch, frameCount: frames)
            }
        }
        guard capCreate == noErr, let createdCap = capProc, AudioDeviceStart(aggID, createdCap) == noErr else {
            if let createdCap = capProc { _ = AudioDeviceDestroyIOProcID(aggID, createdCap) }
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        route.captureIOProc = createdCap
        return route
    }

    private func stopAllLoopbackCustomTapsLocked() {
        os_unfair_lock_lock(&customTapSnapshotLock)
        loopbackCustomTapSnapshot = []
        os_unfair_lock_unlock(&customTapSnapshotLock)

        for route in loopbackCustomAppTaps.values {
            if let capProc = route.captureIOProc, route.tapAggregateID != 0 {
                _ = AudioDeviceStop(route.tapAggregateID, capProc)
                _ = AudioDeviceDestroyIOProcID(route.tapAggregateID, capProc)
            }
            if route.tapAggregateID != 0 {
                _ = AudioHardwareDestroyAggregateDevice(route.tapAggregateID)
            }
            if #available(macOS 14.2, *), route.tapID != 0 {
                _ = AudioHardwareDestroyProcessTap(route.tapID)
            }
        }
        loopbackCustomAppTaps.removeAll()
    }

    @inline(__always)
    private func mixLoopbackStreams(
        sysBuf: UnsafePointer<Float>,
        frameCount: Int,
        includeMic: Bool,
        micRing: LockFreeAudioRingBuffer,
        micScratch: UnsafeMutablePointer<Float>,
        micGain: Float,
        sysGain: Float,
        into dstScratch: UnsafeMutablePointer<Float>
    ) {
        let sampleCount = frameCount * 2
        for i in 0..<sampleCount {
            dstScratch[i] = sysBuf[i] * sysGain
        }

        var hasExtraSignal = (sysGain > 1.001)
        if os_unfair_lock_trylock(&customTapSnapshotLock) {
            let customTaps = loopbackCustomTapSnapshot
            if !customTaps.isEmpty {
                hasExtraSignal = true
                for tap in customTaps {
                    _ = tap.ring.readOrZero(into: loopbackCustomAppScratch, frameCount: frameCount)
                    let appGain = tap.volume * sysGain
                    for i in 0..<sampleCount {
                        dstScratch[i] += loopbackCustomAppScratch[i] * appGain
                    }
                }
            }
            os_unfair_lock_unlock(&customTapSnapshotLock)
        }

        if includeMic {
            hasExtraSignal = true
            _ = micRing.readOrZero(into: micScratch, frameCount: frameCount)
            for i in 0..<sampleCount {
                dstScratch[i] += micScratch[i] * micGain
            }
        }

        if hasExtraSignal {
            for i in 0..<sampleCount {
                dstScratch[i] = tanhf(dstScratch[i])
            }
        }
    }

    @discardableResult
    public func startLoopback(
        virtualTargetUID: String,
        includeMic: Bool,
        micDeviceID: AudioObjectID?
    ) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        return startLoopbackLocked(virtualTargetUID: virtualTargetUID, includeMic: includeMic, micDeviceID: micDeviceID)
    }

    @available(macOS 14.2, *)
    private func startLoopbackLocked(
        virtualTargetUID: String,
        includeMic: Bool,
        micDeviceID: AudioObjectID?
    ) -> Bool {
        let recPausedIncludeMic = recordIncludeMic
        let recPausedMicID = recordMicDeviceID
        if isRecording {
            stopStandaloneRecordTapLocked()
        }
        stopLoopbackLocked()

        activeLoopbackTargetUID = virtualTargetUID
        activeLoopbackRequestedIncludeMic = includeMic
        activeLoopbackRequestedMicID = micDeviceID

        let coreAudio = CoreAudioManager.shared
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var baseExcluded: [AudioObjectID] = []
        if let selfObj = coreAudio.processObjectID(forPID: selfPID) {
            baseExcluded.append(selfObj)
        }

        // Mode A: `AudioMatrix Virtual Mic` mixes via a silent virtual sink so headphones hear zero echo
        if virtualTargetUID == CoreAudioManager.builtInVirtualMicUID || virtualTargetUID == CoreAudioManager.builtInVirtualMicName {
            coreAudio.destroyStaleBuiltInVirtualMic()

            let defaultOutID = coreAudio.getDefaultOutputDevice()?.id ?? 0
            let silentSink = coreAudio.listDevices(includeInternal: true).first(where: {
                $0.hasOutput && $0.isVirtual && $0.uid != CoreAudioManager.builtInVirtualMicUID && $0.id != defaultOutID && $0.name.localizedCaseInsensitiveContains("BlackHole")
            }) ?? coreAudio.listDevices(includeInternal: true).first(where: {
                $0.hasOutput && $0.isVirtual && $0.uid != CoreAudioManager.builtInVirtualMicUID && $0.id != defaultOutID
            })

            if let sink = silentSink {
                let excluded = buildLoopbackExclusionAndCustomTapsLocked(baseExcluded: baseExcluded, createCustomTaps: true)
                guard createPrivateGlobalSysTapLocked(excluding: excluded) else {
                    stopLoopbackLocked()
                    return false
                }
                guard attachLoopbackExternalBusMixer(
                    tapAggregateID: loopbackTapAggID,
                    targetDev: sink,
                    includeMic: includeMic,
                    micDeviceID: micDeviceID
                ) else {
                    stopLoopbackLocked()
                    return false
                }

                // Wait briefly for CoreAudio to register AudioMatrixHub's output ProcessObject if not yet registered
                var selfObj = coreAudio.processObjectID(forPID: selfPID)
                if selfObj == nil {
                    for _ in 0..<6 {
                        Thread.sleep(forTimeInterval: 0.03)
                        selfObj = coreAudio.processObjectID(forPID: selfPID)
                        if selfObj != nil { break }
                    }
                }

                if let procObj = selfObj {
                    let vmTapDesc = CATapDescription(processes: [procObj], deviceUID: sink.uid, stream: 0)
                    vmTapDesc.name = "AudioMatrix Virtual Mic Mix Tap"
                    if createPublicVirtualMicLocked(tapDesc: vmTapDesc) {
                        isLoopbackActive = true
                        return true
                    }
                }

                // Fallback: expose a tap-only `AudioMatrix Virtual Mic` if device-scoped process tap wasn't available
                let fallbackTapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
                fallbackTapDesc.name = "AudioMatrix Built-in Loopback Tap"
                _ = createPublicVirtualMicLocked(tapDesc: fallbackTapDesc)
                isLoopbackActive = true
                return true
            }

            // Fallback when machine has 0 third-party virtual drivers installed:
            // Pure tap-only `AudioMatrix Virtual Mic` excluding excluded apps cleanly with 0 echo.
            let excluded = buildLoopbackExclusionAndCustomTapsLocked(baseExcluded: baseExcluded, createCustomTaps: false)
            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            tapDesc.name = "AudioMatrix Built-in Loopback Tap"
            guard createPublicVirtualMicLocked(tapDesc: tapDesc) else {
                return false
            }

            loopbackIncludeMic = false
            isLoopbackActive = true

            if isRecording && recordTapAggID == 0 {
                _ = startStandaloneRecordTap(includeMic: recPausedIncludeMic, micDeviceID: recPausedMicID == 0 ? nil : recPausedMicID)
            }
            return true
        }

        // Mode B: Push mixed stream into an explicit external virtual bus
        guard let targetDev = coreAudio.device(withUID: virtualTargetUID) else {
            return false
        }

        let excluded = buildLoopbackExclusionAndCustomTapsLocked(baseExcluded: baseExcluded, createCustomTaps: true)
        guard createPrivateGlobalSysTapLocked(excluding: excluded) else {
            stopLoopbackLocked()
            return false
        }

        guard attachLoopbackExternalBusMixer(
            tapAggregateID: loopbackTapAggID,
            targetDev: targetDev,
            includeMic: includeMic,
            micDeviceID: micDeviceID
        ) else {
            stopLoopbackLocked()
            return false
        }
        isLoopbackActive = true
        return true
    }

    @available(macOS 14.2, *)
    private func createPublicVirtualMicLocked(tapDesc: CATapDescription) -> Bool {
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = false
        tapDesc.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr, tapID != 0 else {
            return false
        }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: CoreAudioManager.builtInVirtualMicName,
            kAudioAggregateDeviceUIDKey as String: CoreAudioManager.builtInVirtualMicUID,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
            ],
            kAudioAggregateDeviceIsPrivateKey as String: 0,
            kAudioAggregateDeviceTapAutoStartKey as String: 1
        ]

        var aggID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID) == noErr, aggID != 0 else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            return false
        }

        builtInVirtualMicTapID = tapID
        builtInVirtualMicAggID = aggID
        return true
    }

    @available(macOS 14.2, *)
    private func createPrivateGlobalSysTapLocked(excluding: [AudioObjectID]) -> Bool {
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluding)
        tapDesc.name = "AudioMatrix Loopback Sys Tap"
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr, tapID != 0 else {
            return false
        }
        loopbackTapID = tapID

        let aggUID = "com.audiomatrix.tap.loopback.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AudioMatrix Loopback Tap Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
            ],
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapAutoStartKey as String: 1
        ]

        var aggID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID) == noErr, aggID != 0 else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            loopbackTapID = 0
            return false
        }
        loopbackTapAggID = aggID
        return true
    }

    private func attachLoopbackExternalBusMixer(
        tapAggregateID aggID: AudioObjectID,
        targetDev: AudioDeviceInfo,
        includeMic: Bool,
        micDeviceID: AudioObjectID?
    ) -> Bool {
        let coreAudio = CoreAudioManager.shared
        coreAudio.setSampleRate(targetDev.id, rate: 48000.0)
        loopbackSysRing.reset()
        loopbackMicRing.reset()

        var capProc: AudioDeviceIOProcID?
        let capCreate = AudioDeviceCreateIOProcIDWithBlock(&capProc, aggID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self = self else { return }
            let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let frames = Self.extractStereoInterleaved(from: bufList, into: self.loopbackCapScratch, maxFrames: Self.maxIOFrames)
            if frames > 0 {
                self.loopbackSysRing.write(from: self.loopbackCapScratch, frameCount: frames)
            }
        }
        guard capCreate == noErr, let createdCap = capProc, AudioDeviceStart(aggID, createdCap) == noErr else {
            if let createdCap = capProc { _ = AudioDeviceDestroyIOProcID(aggID, createdCap) }
            return false
        }

        var createdMicProc: AudioDeviceIOProcID?
        var startedMicDeviceID: AudioObjectID = 0
        var hasMic = false
        if includeMic, let micID = micDeviceID, micID != 0 {
            coreAudio.setSampleRate(micID, rate: 48000.0)
            var mProc: AudioDeviceIOProcID?
            let mCreate = AudioDeviceCreateIOProcIDWithBlock(&mProc, micID, nil) { [weak self] _, inInputData, _, _, _ in
                guard let self = self else { return }
                let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let frames = Self.extractStereoInterleaved(from: bufList, into: self.loopbackMicInScratch, maxFrames: Self.maxIOFrames)
                if frames > 0 {
                    self.loopbackMicRing.write(from: self.loopbackMicInScratch, frameCount: frames)
                }
            }
            if mCreate == noErr, let createdMic = mProc, AudioDeviceStart(micID, createdMic) == noErr {
                createdMicProc = createdMic
                startedMicDeviceID = micID
                hasMic = true
            } else if let createdMic = mProc {
                _ = AudioDeviceDestroyIOProcID(micID, createdMic)
            }
        }

        var outProc: AudioDeviceIOProcID?
        let outCreate = AudioDeviceCreateIOProcIDWithBlock(&outProc, targetDev.id, nil) { [weak self] _, _, _, outOutputData, _ in
            guard let self = self else { return }
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
            let frames = Self.frameCount(of: outList, maxFrames: Self.maxIOFrames)
            guard frames > 0 else { return }

            _ = self.loopbackSysRing.readOrZero(into: self.loopbackSysOutScratch, frameCount: frames)
            self.mixLoopbackStreams(
                sysBuf: self.loopbackSysOutScratch,
                frameCount: frames,
                includeMic: self.loopbackIncludeMic,
                micRing: self.loopbackMicRing,
                micScratch: self.loopbackMicOutScratch,
                micGain: self.loopbackMicGain,
                sysGain: self.loopbackGain,
                into: self.loopbackMixScratch
            )

            if self.isRecording {
                self.recordRing.write(from: self.loopbackMixScratch, frameCount: frames)
            }
            Self.writeStereoInterleaved(from: self.loopbackMixScratch, frameCount: frames, gain: 1.0, into: outList)
        }
        guard outCreate == noErr, let createdOut = outProc, AudioDeviceStart(targetDev.id, createdOut) == noErr else {
            if let createdOut = outProc { _ = AudioDeviceDestroyIOProcID(targetDev.id, createdOut) }
            if let mProc = createdMicProc, startedMicDeviceID != 0 {
                _ = AudioDeviceStop(startedMicDeviceID, mProc)
                _ = AudioDeviceDestroyIOProcID(startedMicDeviceID, mProc)
            }
            _ = AudioDeviceStop(aggID, createdCap)
            _ = AudioDeviceDestroyIOProcID(aggID, createdCap)
            return false
        }

        loopbackCapProc = createdCap
        loopbackMicDeviceID = startedMicDeviceID
        loopbackMicProc = createdMicProc
        loopbackIncludeMic = hasMic
        loopbackTargetDeviceID = targetDev.id
        loopbackOutProc = createdOut
        return true
    }

    public func stopLoopback() {
        stateLock.lock()
        stopLoopbackLocked()
        if isRecording && recordTapAggID == 0 {
            if #available(macOS 14.2, *) {
                _ = startStandaloneRecordTap(includeMic: recordIncludeMic, micDeviceID: recordMicDeviceID == 0 ? nil : recordMicDeviceID)
            }
        }
        stateLock.unlock()
    }

    private func stopLoopbackLocked() {
        if builtInVirtualMicAggID != 0 {
            _ = AudioHardwareDestroyAggregateDevice(builtInVirtualMicAggID)
            builtInVirtualMicAggID = 0
        }
        if #available(macOS 14.2, *), builtInVirtualMicTapID != 0 {
            _ = AudioHardwareDestroyProcessTap(builtInVirtualMicTapID)
            builtInVirtualMicTapID = 0
        }
        CoreAudioManager.shared.destroyStaleBuiltInVirtualMic()

        if let proc = loopbackOutProc, loopbackTargetDeviceID != 0 {
            _ = AudioDeviceStop(loopbackTargetDeviceID, proc)
            _ = AudioDeviceDestroyIOProcID(loopbackTargetDeviceID, proc)
        }
        loopbackOutProc = nil
        loopbackTargetDeviceID = 0

        if let proc = loopbackMicProc, loopbackMicDeviceID != 0 {
            _ = AudioDeviceStop(loopbackMicDeviceID, proc)
            _ = AudioDeviceDestroyIOProcID(loopbackMicDeviceID, proc)
        }
        loopbackMicProc = nil
        loopbackMicDeviceID = 0

        if let proc = loopbackCapProc, loopbackTapAggID != 0 {
            _ = AudioDeviceStop(loopbackTapAggID, proc)
            _ = AudioDeviceDestroyIOProcID(loopbackTapAggID, proc)
        }
        loopbackCapProc = nil

        if loopbackTapAggID != 0 {
            _ = AudioHardwareDestroyAggregateDevice(loopbackTapAggID)
            loopbackTapAggID = 0
        }
        if #available(macOS 14.2, *), loopbackTapID != 0 {
            _ = AudioHardwareDestroyProcessTap(loopbackTapID)
            loopbackTapID = 0
        }

        if !isRecording || recordTapAggID == 0 {
            stopAllLoopbackCustomTapsLocked()
        }

        loopbackIncludeMic = false
        isLoopbackActive = false
    }

    // MARK: - Internal Audio Lock-Free WAV Recorder (48kHz Stereo Float32)

    public static func writeWAVHeader(sampleRate: UInt32 = 48000, channels: UInt16 = 2, dataByteSize: UInt32) -> Data {
        var header = Data(count: 44)
        header.withUnsafeMutableBytes { rawBuf in
            if let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                am_wav_write_header(sampleRate, channels, dataByteSize, base)
            }
        }
        return header
    }

    @discardableResult
    public func startRecording(to customURL: URL? = nil, includeMic: Bool = false, micDeviceID: AudioObjectID? = nil) -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isRecording {
            return recordFileURL
        }

        let targetURL: URL
        if let custom = customURL {
            targetURL = custom
        } else {
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            targetURL = downloads.appendingPathComponent("AudioMatrix_Loopback_\(df.string(from: Date())).wav")
        }

        try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: targetURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: targetURL) else {
            return nil
        }

        let initialHeader = Self.writeWAVHeader(sampleRate: 48000, channels: 2, dataByteSize: 0)
        try? handle.write(contentsOf: initialHeader)

        recordRing.reset()
        recordMicRing.reset()
        recordedDataBytes = 0
        recordFileHandle = handle
        recordFileURL = targetURL
        isRecording = true

        if !isLoopbackPushingExternalBus {
            if #available(macOS 14.2, *) {
                _ = startStandaloneRecordTap(includeMic: includeMic, micDeviceID: micDeviceID)
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: recordWriteQueue)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            self?.drainRecordBufferToFile()
        }
        recordTimer = timer
        timer.resume()

        return targetURL
    }

    @discardableResult
    public func stopRecording() -> URL? {
        stateLock.lock()
        guard isRecording else {
            stateLock.unlock()
            return nil
        }
        isRecording = false
        stopStandaloneRecordTapLocked()
        let timer = recordTimer
        recordTimer = nil
        stateLock.unlock()

        timer?.cancel()

        var finalizedURL: URL?
        recordWriteQueue.sync {
            drainRecordBufferToFile()
            if let handle = self.recordFileHandle {
                try? handle.seek(toOffset: 0)
                let finalHeader = Self.writeWAVHeader(sampleRate: 48000, channels: 2, dataByteSize: self.recordedDataBytes)
                try? handle.write(contentsOf: finalHeader)
                try? handle.close()
            }
            self.recordFileHandle = nil
            finalizedURL = self.recordFileURL
            self.lastRecordedFileURL = finalizedURL
        }
        return finalizedURL
    }

    private func drainRecordBufferToFile() {
        guard let handle = recordFileHandle else { return }
        while true {
            let avail = recordRing.availableToRead()
            if avail <= 0 { break }
            let toRead = min(avail, 8192)
            let readFrames = recordDrainScratch.withUnsafeMutableBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return recordRing.read(into: base, frameCount: toRead)
            }
            if readFrames <= 0 { break }
            let byteCount = readFrames * 2 * MemoryLayout<Float>.size
            recordDrainScratch.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    let chunk = Data(bytes: base, count: byteCount)
                    try? handle.write(contentsOf: chunk)
                    recordedDataBytes &+= UInt32(byteCount)
                }
            }
        }
    }

    @inline(__always)
    private func mixMicAndWriteToRecorder(sysBuf: UnsafePointer<Float>, frameCount: Int) {
        mixLoopbackStreams(
            sysBuf: sysBuf,
            frameCount: frameCount,
            includeMic: recordIncludeMic,
            micRing: recordMicRing,
            micScratch: recordMicMixScratch,
            micGain: loopbackMicGain,
            sysGain: loopbackGain,
            into: loopbackMixScratch
        )
        recordRing.write(from: loopbackMixScratch, frameCount: frameCount)
    }

    private func startRecordMicCaptureLocked(micDeviceID: AudioObjectID) {
        stopRecordMicCaptureLocked()
        guard micDeviceID != 0 else { return }
        CoreAudioManager.shared.setSampleRate(micDeviceID, rate: 48000.0)
        recordMicRing.reset()

        var mProc: AudioDeviceIOProcID?
        let mCreate = AudioDeviceCreateIOProcIDWithBlock(&mProc, micDeviceID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self = self, self.isRecording else { return }
            let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let frames = Self.extractStereoInterleaved(from: bufList, into: self.recordMicInScratch, maxFrames: Self.maxIOFrames)
            if frames > 0 {
                self.recordMicRing.write(from: self.recordMicInScratch, frameCount: frames)
            }
        }
        if mCreate == noErr, let createdMic = mProc, AudioDeviceStart(micDeviceID, createdMic) == noErr {
            recordMicDeviceID = micDeviceID
            recordMicProc = createdMic
            recordIncludeMic = true
        } else if let createdMic = mProc {
            _ = AudioDeviceDestroyIOProcID(micDeviceID, createdMic)
        }
    }

    private func stopRecordMicCaptureLocked() {
        if let proc = recordMicProc, recordMicDeviceID != 0 {
            _ = AudioDeviceStop(recordMicDeviceID, proc)
            _ = AudioDeviceDestroyIOProcID(recordMicDeviceID, proc)
        }
        recordMicProc = nil
        recordMicDeviceID = 0
        recordIncludeMic = false
    }

    @available(macOS 14.2, *)
    private func startStandaloneRecordTap(includeMic: Bool = false, micDeviceID: AudioObjectID? = nil) -> Bool {
        let coreAudio = CoreAudioManager.shared
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var baseExcluded: [AudioObjectID] = []
        if let selfObj = coreAudio.processObjectID(forPID: selfPID) {
            baseExcluded.append(selfObj)
        }

        let excluded = buildLoopbackExclusionAndCustomTapsLocked(baseExcluded: baseExcluded, createCustomTaps: true)
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapDesc.name = "AudioMatrix Recorder Tap"
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr, tapID != 0 else {
            return false
        }
        recordTapID = tapID

        let aggUID = "com.audiomatrix.tap.recorder.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AudioMatrix Recorder Tap Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
            ],
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapAutoStartKey as String: 1
        ]

        var aggID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID) == noErr, aggID != 0 else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            recordTapID = 0
            return false
        }
        recordTapAggID = aggID

        if includeMic, let micID = micDeviceID, micID != 0 {
            startRecordMicCaptureLocked(micDeviceID: micID)
        } else {
            stopRecordMicCaptureLocked()
        }

        var capProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&capProc, aggID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self = self, self.isRecording else { return }
            let bufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let frames = Self.extractStereoInterleaved(from: bufList, into: self.recordCapScratch, maxFrames: Self.maxIOFrames)
            if frames > 0 {
                self.mixMicAndWriteToRecorder(sysBuf: self.recordCapScratch, frameCount: frames)
            }
        }
        guard status == noErr, let createdCap = capProc, AudioDeviceStart(aggID, createdCap) == noErr else {
            if let createdCap = capProc { _ = AudioDeviceDestroyIOProcID(aggID, createdCap) }
            stopStandaloneRecordTapLocked()
            return false
        }
        recordCapProc = createdCap
        return true
    }

    private func stopStandaloneRecordTapLocked() {
        stopRecordMicCaptureLocked()

        if let proc = recordCapProc, recordTapAggID != 0 {
            _ = AudioDeviceStop(recordTapAggID, proc)
            _ = AudioDeviceDestroyIOProcID(recordTapAggID, proc)
        }
        recordCapProc = nil

        if recordTapAggID != 0 {
            _ = AudioHardwareDestroyAggregateDevice(recordTapAggID)
            recordTapAggID = 0
        }
        if #available(macOS 14.2, *), recordTapID != 0 {
            _ = AudioHardwareDestroyProcessTap(recordTapID)
            recordTapID = 0
        }
        if !isLoopbackActive {
            stopAllLoopbackCustomTapsLocked()
        }
    }

    private func removeAppRouteLocked(bundleID: String) {
        guard let route = appRoutes.removeValue(forKey: bundleID) else { return }
        if let capProc = route.captureIOProc {
            _ = AudioDeviceStop(route.tapAggregateID, capProc)
            _ = AudioDeviceDestroyIOProcID(route.tapAggregateID, capProc)
        }
        if let outProc = route.outIOProc {
            _ = AudioDeviceStop(route.outDeviceID, outProc)
            _ = AudioDeviceDestroyIOProcID(route.outDeviceID, outProc)
        }
        if route.tapAggregateID != 0 {
            _ = AudioHardwareDestroyAggregateDevice(route.tapAggregateID)
        }
        if #available(macOS 14.2, *), route.tapID != 0 {
            _ = AudioHardwareDestroyProcessTap(route.tapID)
        }
    }

    // MARK: - AudioBufferList Format Helpers (Zero-Allocation)

    @inline(__always)
    public static func frameCount(of list: UnsafeMutableAudioBufferListPointer, maxFrames: Int) -> Int {
        guard let first = list.first else { return 0 }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        return min(frames, maxFrames)
    }

    @inline(__always)
    public static func extractStereoInterleaved(
        from list: UnsafeMutableAudioBufferListPointer,
        into dst: UnsafeMutablePointer<Float>,
        maxFrames: Int
    ) -> Int {
        guard !list.isEmpty else { return 0 }
        if list.count == 1 {
            let buf = list[0]
            guard let raw = buf.mData else { return 0 }
            let src = raw.assumingMemoryBound(to: Float.self)
            let ch = Int(buf.mNumberChannels)
            let frames = min(maxFrames, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * max(1, ch)))
            if ch == 2 {
                dst.update(from: src, count: frames * 2)
            } else if ch == 1 {
                for i in 0..<frames {
                    let v = src[i]
                    dst[i * 2] = v
                    dst[i * 2 + 1] = v
                }
            } else if ch > 2 {
                for i in 0..<frames {
                    dst[i * 2] = src[i * ch]
                    dst[i * 2 + 1] = src[i * ch + 1]
                }
            }
            return frames
        } else {
            // Non-interleaved (planar): buffer 0 = Left, buffer 1 = Right
            let bufL = list[0]
            let bufR = list[1]
            guard let rawL = bufL.mData, let rawR = bufR.mData else { return 0 }
            let srcL = rawL.assumingMemoryBound(to: Float.self)
            let srcR = rawR.assumingMemoryBound(to: Float.self)
            let frames = min(maxFrames, Int(bufL.mDataByteSize) / MemoryLayout<Float>.size)
            for i in 0..<frames {
                dst[i * 2] = srcL[i]
                dst[i * 2 + 1] = srcR[i]
            }
            return frames
        }
    }

    @inline(__always)
    public static func writeStereoInterleaved(
        from src: UnsafeMutablePointer<Float>,
        frameCount: Int,
        gain: Float,
        into list: UnsafeMutableAudioBufferListPointer
    ) {
        guard !list.isEmpty, frameCount > 0 else { return }
        if list.count == 1 {
            let buf = list[0]
            guard let raw = buf.mData else { return }
            let dst = raw.assumingMemoryBound(to: Float.self)
            let ch = Int(buf.mNumberChannels)
            let capFrames = min(frameCount, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * max(1, ch)))
            if ch == 2 {
                for i in 0..<(capFrames * 2) {
                    dst[i] = src[i] * gain
                }
            } else if ch == 1 {
                for i in 0..<capFrames {
                    dst[i] = 0.5 * (src[i * 2] + src[i * 2 + 1]) * gain
                }
            } else if ch > 2 {
                for i in 0..<capFrames {
                    dst[i * ch] = src[i * 2] * gain
                    dst[i * ch + 1] = src[i * 2 + 1] * gain
                }
            }
        } else {
            let bufL = list[0]
            let bufR = list[1]
            guard let rawL = bufL.mData, let rawR = bufR.mData else { return }
            let dstL = rawL.assumingMemoryBound(to: Float.self)
            let dstR = rawR.assumingMemoryBound(to: Float.self)
            let capFrames = min(frameCount, Int(bufL.mDataByteSize) / MemoryLayout<Float>.size)
            for i in 0..<capFrames {
                dstL[i] = src[i * 2] * gain
                dstR[i] = src[i * 2 + 1] * gain
            }
        }
    }
}

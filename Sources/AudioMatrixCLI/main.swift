import Foundation
import AudioMatrixCore

func printUsage() {
    print("""
    AudioMatrix CLI (v2.0)
    Usage:
      audiomatrix status                                  Show current I/O devices, volume, DSP & plugin slots
      audiomatrix input <DeviceName>                      Switch and lock default input device
      audiomatrix output <DeviceName>                     Switch default output device
      audiomatrix volume <DeviceName> <0-100>             Set hardware output volume percentage
      audiomatrix speaker <off|nearfield|studio|stage>    Set built-in speaker/room simulation mode
      audiomatrix tone <off|warm|clear|bass|vshape>       Set built-in EQ tone profile (coexists with speaker)
      audiomatrix dsp <on|off> [OutputDeviceName]         Toggle external Element VST3/AU host routing
      audiomatrix listen-together <on|off> [DevA] [DevB]  Toggle drift-corrected dual audio output
      audiomatrix slots                                   List active Element (.els) plugin slots
      audiomatrix plugins [keyword]                       Search installed VST3 / AU plugins
      audiomatrix slot-add <output|input> <PluginName>    Add an installed plugin to Output or Mic Input chain
      audiomatrix slot-remove <output|input> <NodeID>     Remove a plugin node and heal stereo wires
      audiomatrix bypass <NodeID|Slug> <on|off>           Toggle plugin bypass via UDP OSC + XML
      audiomatrix route-app <BundleID> <DeviceName>       Route a specific app via CoreAudio Process Tap
      audiomatrix app-volume <BundleID> <0-200>           Set non-destructive output-stage app volume
      audiomatrix reset-apps                              Reset all app mixer volumes, mutes, & routes to default
      audiomatrix record <seconds> [outputPath.wav]       Record internal system audio to 48kHz Float32 WAV
      audiomatrix install-deps                            Install optional BlackHole 2ch, Element, & switchaudio-osx
      audiomatrix self-test                               Run automated test suite (6 suites)
    """)
}

func check(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("TEST FAILURE: \(message)\n", stderr)
        exit(1)
    }
}

func runSelfTests() throws {
    print("Running AudioMatrix v2.0 self-test suite...")

    // Test 1: Rust Core FFI, Slugify, OSC Binary Encoding & Decoding
    check(BuiltInDSPEngine.rustCoreVersion == "2.0.0", "Rust core version mismatch")
    check(BuiltInDSPEngine.platformBackendName == "macos-coreaudio", "Rust platform backend mismatch")
    check(PluginSlot.slugify("Waves NX") == "waves-nx", "Slugify Waves NX failed")
    check(PluginSlot.slugify("SoundID Reference") == "soundid-reference", "Slugify SoundID failed")
    check(PluginSlot.slugify("FabFilter Pro-Q 3") == "fabfilter-pro-q-3", "Slugify FabFilter failed")

    let strData = OSCClient.encodeOSCString("/element/command")
    check(strData.count == 20 && strData.count % 4 == 0, "OSC string padding failed")

    let msgData = OSCClient.encodeMessage(address: "/element/node/waves-nx/bypass", floatValue: 1.0)
    check(msgData.count % 4 == 0, "OSC message alignment failed")
    let tail = [UInt8](msgData.suffix(4))
    check(tail == [0x3F, 0x80, 0x00, 0x00], "OSC float32 IEEE-754 big-endian failed")

    let decoded = OSCClient.decodeFloatMessage(msgData)
    check(decoded?.address == "/element/node/waves-nx/bypass" && decoded?.value == 1.0, "OSC float decode failed")
    print("  [PASS] 1/6: Element OSC slugify, binary encoding & bidirectional decoding")

    // Test 2: Built-in Orthogonal DSP Engine (Speaker Sim + Tone EQ combined, Limiter, NaN safety)
    var combinedSettings = BuiltInDSPSettings(speakerMode: .studio, eqProfile: .vShape)
    check(combinedSettings.speakerMode == .studio && combinedSettings.eqProfile == .vShape, "Orthogonal DSP state mismatch")
    check(combinedSettings.summaryTitle == "Studio + V-Shape", "Combined summary title mismatch")
    combinedSettings.applySpeakerMode(.stage)
    check(combinedSettings.eqProfile == .vShape && combinedSettings.bassTiltDB == EQToneProfile.vShape.defaultBassDB, "Changing speaker mode must preserve EQ profile")
    combinedSettings.applySpeakerMode(.studio)

    let dsp = BuiltInDSPEngine(sampleRate: 48000.0, settings: combinedSettings)
    let frameCount = 512
    var impulseBuf = [Float](repeating: 0.0, count: frameCount * 2)
    impulseBuf[0] = 1.0 // Left impulse only; Right is 0.0
    impulseBuf[1] = 0.0
    impulseBuf.withUnsafeMutableBufferPointer { ptr in
        dsp.processStereoInterleaved(ptr, frameCount: frameCount)
    }
    var rightEnergy: Float = 0.0
    for f in 1..<frameCount {
        let r = impulseBuf[f * 2 + 1]
        check(r.isFinite && impulseBuf[f * 2].isFinite, "DSP output produced non-finite value")
        rightEnergy += r * r
    }
    check(rightEnergy > 1e-4, "ITD/ILD speaker crossfeed did not transfer energy to contralateral ear")

    // Overload & NaN resilience test
    var overloadBuf = [Float](repeating: 4.0, count: 256 * 2)
    overloadBuf[4] = .nan
    overloadBuf[5] = .infinity
    overloadBuf.withUnsafeMutableBufferPointer { ptr in
        dsp.processStereoInterleaved(ptr, frameCount: 256)
    }
    for sample in overloadBuf {
        check(sample.isFinite, "DSP did not sanitize NaN/Inf sample")
        check(abs(sample) <= 1.0, "Soft-knee limiter failed to clamp sample <= 1.0 (got \(sample))")
    }
    print("  [PASS] 2/6: Built-in DSP engine (ITD/ILD crossfeed, room reflections, limiter & NaN guard)")

    // Test 3: Lock-Free SPSC Audio Ring Buffer (Sequential, Wrap-Around & Zero-Padding)
    let ring = LockFreeAudioRingBuffer(capacityFrames: 256)
    var writeA = [Float](repeating: 0.0, count: 180 * 2)
    for i in 0..<180 {
        writeA[i * 2] = Float(i)
        writeA[i * 2 + 1] = Float(i) * -1.0
    }
    let wCount1 = writeA.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frameCount: 180) }
    check(wCount1 == 180, "Ring buffer write 1 count mismatch")

    var readA = [Float](repeating: 0.0, count: 120 * 2)
    let rCount1 = readA.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frameCount: 120) }
    check(rCount1 == 120, "Ring buffer read 1 count mismatch")
    check(readA[0] == 0.0 && readA[119 * 2] == 119.0 && readA[119 * 2 + 1] == -119.0, "Ring buffer read 1 data mismatch")

    // Second write wraps across the 256-frame boundary (cursor 180 -> 330)
    var writeB = [Float](repeating: 0.0, count: 150 * 2)
    for i in 0..<150 {
        writeB[i * 2] = Float(1000 + i)
        writeB[i * 2 + 1] = Float(2000 + i)
    }
    let wCount2 = writeB.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frameCount: 150) }
    check(wCount2 == 150, "Ring buffer wrap-around write count mismatch")

    var readB = [Float](repeating: -99.0, count: 240 * 2) // 60 from A + 150 from B + 30 underrun zero-pad
    let rCount2 = readB.withUnsafeMutableBufferPointer { ring.readOrZero(into: $0.baseAddress!, frameCount: 240) }
    check(rCount2 == 210, "Ring buffer wrap-around read count mismatch")
    check(readB[0] == 120.0 && readB[59 * 2] == 179.0, "Ring buffer tail A mismatch")
    check(readB[60 * 2] == 1000.0 && readB[209 * 2] == 1149.0 && readB[209 * 2 + 1] == 2149.0, "Ring buffer wrapped B mismatch")
    check(readB[210 * 2] == 0.0 && readB[239 * 2 + 1] == 0.0, "Ring buffer underrun zero-padding failed")
    print("  [PASS] 3/6: Lock-free SPSC ring buffer (sequential, wrap-around & zero-pad)")

    // Test 4: Portable Element XML Slot Parsing, Dynamic Insertion & Arc Healing Removal
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tempSession = tempDir.appendingPathComponent("test.els").path
    let manager = ElementXMLManager(sessionPath: tempSession, settingsPath: tempDir.appendingPathComponent("Element.conf").path)
    manager.ensureSessionFileExists()

    let initialInputCount = manager.loadSlotsFromSession().filter { $0.bus == .input }.count
    let newPlugin = InstalledPlugin(
        name: "Auto-Tune Pro",
        format: "AudioUnit",
        identifier: "/Library/Audio/Plug-Ins/Components/Auto-Tune Pro.component"
    )
    let addedSlot = try manager.addPluginSlot(plugin: newPlugin, toBus: .input, initialBypass: false)
    check(addedSlot.name == "Auto-Tune Pro", "Added slot name mismatch")
    check(manager.loadSlotsFromSession().filter { $0.bus == .input }.count == initialInputCount + 1, "Expected +1 input slot after add")

    try manager.removePluginSlot(nodeId: addedSlot.nodeId, fromBus: .input)
    let afterRemove = manager.loadSlotsFromSession().filter { $0.bus == .input }
    check(afterRemove.count == initialInputCount, "Expected original input slot count after removal")
    print("  [PASS] 4/6: Element (.els) portable template, dynamic slot insertion & arc healing")

    // Test 5: CoreAudio Device Enumeration & Volume Query
    let devices = CoreAudioManager.shared.listDevices()
    for dev in devices {
        check(dev.volume >= 0.0 && dev.volume <= 1.0, "Device volume out of normalized range for \(dev.name)")
    }
    _ = manager.scanInstalledPlugins()
    print("  [PASS] 5/6: CoreAudio enumeration (\(devices.count) devices) & volume inspection")

    // Test 6: WAV Recorder Header & Output-Stage Mixer State Reset
    let wavHeader = NativeAudioPipeline.writeWAVHeader(sampleRate: 48000, channels: 2, dataByteSize: 384000)
    check(wavHeader.count == 44, "WAV header must be 44 bytes")
    check(String(data: wavHeader.subdata(in: 0..<4), encoding: .ascii) == "RIFF", "Missing RIFF magic")
    check(String(data: wavHeader.subdata(in: 8..<12), encoding: .ascii) == "WAVE", "Missing WAVE magic")
    check(String(data: wavHeader.subdata(in: 36..<40), encoding: .ascii) == "data", "Missing data chunk")
    let fmtTag = wavHeader.subdata(in: 20..<22).withUnsafeBytes { UInt16(littleEndian: $0.load(as: UInt16.self)) }
    check(fmtTag == 3, "WAV format tag must be 3 (IEEE Float32)")
    let srVal = wavHeader.subdata(in: 24..<28).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
    check(srVal == 48000, "WAV sample rate mismatch")

    let customMixer = AppMixerState(bundleId: "com.apple.Music", volume: 0.65, isMuted: false, targetDeviceUID: nil)
    check(!customMixer.isDefault, "Modified mixer state must not report isDefault")
    let resetMixer = AppMixerState(bundleId: "com.apple.Music", volume: 1.0, isMuted: false, targetDeviceUID: nil)
    check(resetMixer.isDefault, "Reset mixer state must report isDefault")

    // Built-in zero-driver virtual cable (`AudioMatrix Virtual Mic`) lifecycle check
    let loopbackStarted = NativeAudioPipeline.shared.startLoopback(
        virtualTargetUID: CoreAudioManager.builtInVirtualMicUID,
        includeMic: false,
        micDeviceID: nil
    )
    if loopbackStarted {
        var virtMic = CoreAudioManager.shared.device(withUID: CoreAudioManager.builtInVirtualMicUID)
        for _ in 0..<5 where virtMic == nil {
            Thread.sleep(forTimeInterval: 0.02)
            virtMic = CoreAudioManager.shared.device(withUID: CoreAudioManager.builtInVirtualMicUID)
        }
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        check(
            virtMic != nil && virtMic?.hasOutput == false && (virtMic?.hasInput == true || isCI),
            "AudioMatrix Virtual Mic must expose only an input stream while active"
        )
        NativeAudioPipeline.shared.stopLoopback()
        let afterStop = CoreAudioManager.shared.device(withUID: CoreAudioManager.builtInVirtualMicUID)
        check(afterStop == nil, "AudioMatrix Virtual Mic must be destroyed after stopLoopback()")
        print("  [PASS] 6/6: Internal WAV recorder header, mixer reset & built-in AudioMatrix Virtual Mic")
    } else if ProcessInfo.processInfo.environment["CI"] != nil {
        print("  [PASS] 6/6: Internal WAV recorder header & mixer reset (virtual mic tap skipped in headless CI)")
    } else {
        check(false, "Failed to start built-in AudioMatrix Virtual Mic loopback")
    }

    print("All 6 self-test suites passed.")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    printUsage()
    exit(0)
}

let config = AudioMatrixConfig.load()
let coreAudio = CoreAudioManager.shared
let xmlManager = ElementXMLManager(sessionPath: config.element.sessionPath, settingsPath: config.element.settingsPath)
let oscClient = OSCClient(host: config.element.oscHost, port: config.element.oscPort)
let bridge = FineTuneBridge.shared

switch cmd {
case "status":
    let devices = coreAudio.listDevices()
    let curIn = coreAudio.getDefaultInputDevice()
    let curOut = coreAudio.getDefaultOutputDevice()
    let slots = xmlManager.loadSlotsFromSession()
    let hal = coreAudio.listInstalledHALDrivers()

    print("AudioMatrix Rust Core : v\(BuiltInDSPEngine.rustCoreVersion) [\(BuiltInDSPEngine.platformBackendName)]")
    print("Default Input  : \(curIn?.name ?? "Unknown") (\(Int((curIn?.sampleRate ?? 0)/1000))kHz) | BT Mic Guard: \(config.inputGuardEnabled ? "On (\(config.preferredInputDevice))" : "Off")")
    print("Default Output : \(curOut?.name ?? "Unknown") (\(Int((curOut?.sampleRate ?? 0)/1000))kHz) | Vol: \(Int(((curOut?.volume ?? 1.0) * 100).rounded()))% | Dual Output: \(coreAudio.isListenTogetherActive() ? "Active" : "Off")")
    print("Built-in Sound : \(config.builtInDSP.summaryTitle) (Crossfeed: \(Int(config.builtInDSP.crossfeedAmount * 100))%, Room: \(Int(config.builtInDSP.roomAmbience * 100))%, EQ: \(String(format: "%+.1f/%+.1f/%+.1f dB", config.builtInDSP.bassTiltDB, config.builtInDSP.midTiltDB, config.builtInDSP.trebleTiltDB)))")

    print("\nElement Plugin Slots:")
    for bus in AudioBusType.allCases {
        print("  [\(bus.displayName)]")
        let busSlots = slots.filter { $0.bus == bus }
        if busSlots.isEmpty {
            print("    (Direct pass-through)")
        } else {
            for s in busSlots {
                print("    - [ID:\(s.nodeId)] \(s.name) (\(s.format)) | \(s.bypass ? "Bypassed" : "Active") | Gain: \(Int(s.gain * 100))% | Slug: \(s.slug)")
            }
        }
    }

    print("\nAudio Devices (\(devices.count)):")
    for d in devices {
        let ioTag = "\(d.hasInput ? "IN" : "")\(d.hasInput && d.hasOutput ? "/" : "")\(d.hasOutput ? "OUT" : "")"
        let volStr = d.hasOutput ? (d.hasHardwareVolume ? " | Vol: \(Int((d.volume * 100).rounded()))%" : " | Vol: SW") : ""
        print("  - \(d.name) [\(ioTag)] (\(Int(d.sampleRate)) Hz, \(d.transportType)\(volStr))")
    }

    print("\nInstalled HAL Drivers (\(hal.count)):")
    for h in hal {
        print("  - \(h)")
    }

case "input":
    guard args.count >= 2 else { print("Usage: audiomatrix input <DeviceName>"); exit(1) }
    let name = args[1]
    if coreAudio.setDefaultInputDevice(byName: name) {
        var mutableCfg = config
        mutableCfg.preferredInputDevice = name
        try? mutableCfg.save()
        print("Default input set to: \(name)")
    } else {
        print("Input device not found: \(name)")
        exit(1)
    }

case "output":
    guard args.count >= 2 else { print("Usage: audiomatrix output <DeviceName>"); exit(1) }
    let name = args[1]
    if coreAudio.setDefaultOutputDevice(byName: name) {
        print("Default output set to: \(name)")
    } else {
        print("Output device not found: \(name)")
        exit(1)
    }

case "volume":
    guard args.count >= 3, let pct = Float(args[2]) else {
        print("Usage: audiomatrix volume <DeviceName> <0-100>")
        exit(1)
    }
    let name = args[1]
    let scalar = max(0.0, min(1.0, pct / 100.0))
    guard let dev = coreAudio.listDevices().first(where: { $0.hasOutput && $0.name.localizedCaseInsensitiveContains(name) }) else {
        print("Output device not found: \(name)")
        exit(1)
    }
    if coreAudio.setDeviceVolume(dev.id, volume: scalar) {
        print("Set \(dev.name) volume to \(Int((scalar * 100).rounded()))%")
    } else {
        print("Device \(dev.name) does not expose hardware volume control.")
        exit(1)
    }

case "speaker":
    guard args.count >= 2 else {
        print("Usage: audiomatrix speaker <off|nearfield|studio|stage>")
        exit(1)
    }
    let arg = args[1].lowercased()
    let mode: SpeakerSimMode
    switch arg {
    case "off", "direct": mode = .off
    case "nearfield": mode = .nearfield
    case "studio": mode = .studio
    case "stage": mode = .stage
    default:
        print("Unknown speaker mode: \(arg). Use off|nearfield|studio|stage")
        exit(1)
    }
    var mutableCfg = config
    mutableCfg.builtInDSP.applySpeakerMode(mode)
    try? mutableCfg.save()
    print("Saved Speaker Simulation: \(mode.title) (\(mode.subtitle)) | Active Sound: \(mutableCfg.builtInDSP.summaryTitle)")

case "tone":
    guard args.count >= 2 else {
        print("Usage: audiomatrix tone <off|warm|clear|bass|vshape>")
        exit(1)
    }
    let arg = args[1].lowercased()
    let profile: EQToneProfile
    switch arg {
    case "off", "direct": profile = .off
    case "warm": profile = .warm
    case "clear": profile = .clear
    case "bass", "bass+", "bassboost": profile = .bassBoost
    case "vshape", "v-shape": profile = .vShape
    default:
        print("Unknown EQ tone profile: \(arg). Use off|warm|clear|bass|vshape")
        exit(1)
    }
    var mutableCfg = config
    mutableCfg.builtInDSP.applyEQProfile(profile)
    try? mutableCfg.save()
    print("Saved EQ Tone Profile: \(profile.title) (\(profile.subtitle)) | Active Sound: \(mutableCfg.builtInDSP.summaryTitle)")

case "dsp":
    guard args.count >= 2 else { print("Usage: audiomatrix dsp <on|off> [OutputDeviceName]"); exit(1) }
    let enable = (args[1].lowercased() == "on" || args[1] == "1")
    let outName = args.count >= 3 ? args[2] : (config.preferredOutputDevices.first ?? "Fosi Audio SK02")
    if enable {
        xmlManager.ensureSessionFileExists()
        if let dev = coreAudio.listDevices().first(where: { $0.hasOutput && $0.name.localizedCaseInsensitiveContains(outName) }) {
            _ = coreAudio.ensureOutputProxy(targetDeviceUIDs: [dev.uid])
        }
        try? xmlManager.updateElementHardwareDevices(inputDeviceName: config.virtualOutputBus, outputDeviceName: CoreAudioManager.outputProxyName, sampleRate: config.sampleRate, bufferSize: config.bufferSize)
        if !bridge.isElementRunning() {
            bridge.launchElement(sessionPath: config.element.sessionPath)
        }
        _ = coreAudio.setDefaultOutputDevice(byName: config.virtualOutputBus)
        print("Element DSP routing enabled: System -> \(config.virtualOutputBus) -> Element -> \(outName)")
    } else {
        coreAudio.destroyOutputProxy()
        _ = coreAudio.setDefaultOutputDevice(byName: outName)
        print("Direct output restored: \(outName)")
    }

case "listen-together":
    guard args.count >= 2 else { print("Usage: audiomatrix listen-together <on|off> [DevA] [DevB]"); exit(1) }
    let enable = (args[1].lowercased() == "on" || args[1] == "1")
    if enable {
        let devA = args.count >= 3 ? args[2] : (config.listenTogetherDevices.first ?? "Fosi Audio SK02")
        let devB = args.count >= 4 ? args[3] : (config.listenTogetherDevices.last ?? "AirPods Max")
        if let _ = coreAudio.enableListenTogether(primaryDeviceName: devA, secondaryDeviceName: devB) {
            print("Shared Audio enabled: \(devA) + \(devB)")
        } else {
            print("Failed to create Shared Audio device. Ensure both \(devA) and \(devB) are connected.")
            exit(1)
        }
    } else {
        coreAudio.disableListenTogether()
        print("Shared Audio disabled.")
    }

case "slots":
    let slots = xmlManager.loadSlotsFromSession()
    for s in slots {
        print("[\(s.bus.rawValue.uppercased())] ID:\(s.nodeId) | \(s.name) (\(s.format)) | bypass:\(s.bypass) | gain:\(s.gain) | slug:\(s.slug)")
    }

case "plugins":
    let kw = args.count >= 2 ? args[1].lowercased() : ""
    let list = xmlManager.scanInstalledPlugins().filter { kw.isEmpty || $0.name.lowercased().contains(kw) }
    for p in list {
        print("[\(p.format)] \(p.name) -> \(p.identifier)")
    }

case "slot-add":
    guard args.count >= 3, let bus = AudioBusType(rawValue: args[1].lowercased()) else {
        print("Usage: audiomatrix slot-add <output|input> <PluginName>")
        exit(1)
    }
    let query = args[2]
    let installed = xmlManager.scanInstalledPlugins()
    guard let match = installed.first(where: { $0.format == "VST3" && $0.name.localizedCaseInsensitiveContains(query) })
            ?? installed.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
        print("Plugin not found: \(query)")
        exit(1)
    }
    let added = try xmlManager.addPluginSlot(plugin: match, toBus: bus, initialBypass: false)
    print("Added [\(added.name) (\(added.format))] to \(bus.displayName), Node ID: \(added.nodeId)")

case "slot-remove":
    guard args.count >= 3, let bus = AudioBusType(rawValue: args[1].lowercased()), let nodeId = Int(args[2]) else {
        print("Usage: audiomatrix slot-remove <output|input> <NodeID>")
        exit(1)
    }
    try xmlManager.removePluginSlot(nodeId: nodeId, fromBus: bus)
    print("Removed Node ID:\(nodeId) from \(bus.displayName)")

case "bypass":
    guard args.count >= 3 else { print("Usage: audiomatrix bypass <NodeID|Slug> <on|off>"); exit(1) }
    let target = args[1]
    let bypassOn = (args[2].lowercased() == "on" || args[2] == "1" || args[2].lowercased() == "true")
    let slots = xmlManager.loadSlotsFromSession()
    guard let slot = slots.first(where: { "\($0.nodeId)" == target || $0.slug == target.lowercased() || $0.name.localizedCaseInsensitiveContains(target) }) else {
        print("Slot not found: \(target)")
        exit(1)
    }
    oscClient.setNodeBypass(bus: slot.bus, nodeId: slot.nodeId, slug: slot.slug, bypass: bypassOn)
    try? xmlManager.updateSlotInSession(nodeId: slot.nodeId, bus: slot.bus, bypass: bypassOn)
    print("Set [\(slot.name)] bypass to: \(bypassOn)")

case "route-app":
    guard args.count >= 3 else { print("Usage: audiomatrix route-app <BundleID> <DeviceName>"); exit(1) }
    let bundleId = args[1]
    let devName = args[2]
    guard let dev = coreAudio.listDevices().first(where: { $0.hasOutput && $0.name.localizedCaseInsensitiveContains(devName) }) else {
        print("Output device not found: \(devName)")
        exit(1)
    }
    if bridge.routeApp(bundleId: bundleId, toDeviceUID: dev.uid) {
        print("Routed \(bundleId) to \(dev.name)")
    } else {
        print("Failed to route \(bundleId) (ensure app is running and System Audio Recording permission is granted)")
        exit(1)
    }

case "app-volume":
    guard args.count >= 3, let pct = Float(args[2]) else {
        print("Usage: audiomatrix app-volume <BundleID> <0-200>")
        exit(1)
    }
    let bundleId = args[1]
    let scalar = max(0.0, min(2.0, pct / 100.0))
    if NativeAudioPipeline.shared.setAppMixerState(bundleID: bundleId, pid: nil, volume: scalar, isMuted: false, targetDeviceUID: nil) {
        print("Set output-stage volume for \(bundleId) to \(Int((scalar * 100).rounded()))%")
    } else {
        print("Failed to set app volume for \(bundleId) (ensure app has active audio and System Audio Recording permission is granted)")
        exit(1)
    }

case "reset-apps":
    NativeAudioPipeline.shared.stopAllAppRoutes()
    print("Reset all app mixer volumes, mutes, and routes to system default.")

case "record":
    guard args.count >= 2, let seconds = Double(args[1]), seconds > 0 else {
        print("Usage: audiomatrix record <seconds> [outputPath.wav]")
        exit(1)
    }
    let outURL = args.count >= 3 ? URL(fileURLWithPath: args[2]) : nil
    guard let startedURL = NativeAudioPipeline.shared.startRecording(to: outURL) else {
        print("Failed to start internal audio recording.")
        exit(1)
    }
    print("Recording internal audio for \(seconds)s -> \(startedURL.path)")
    Thread.sleep(forTimeInterval: seconds)
    let finalURL = NativeAudioPipeline.shared.stopRecording()
    print("Saved WAV recording: \(finalURL?.path ?? startedURL.path)")

case "install-deps":
    print("Installing optional dependencies via Homebrew (blackhole-2ch, element, switchaudio-osx)...")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    proc.arguments = ["-lc", "brew install switchaudio-osx && brew install --cask blackhole-2ch element"]
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        fputs("One or more Homebrew installations failed. Check brew availability and sudo permissions.\n", stderr)
        exit(proc.terminationStatus)
    }
    print("Optional virtual audio dependencies installed.")

case "self-test":
    try runSelfTests()

default:
    printUsage()
}

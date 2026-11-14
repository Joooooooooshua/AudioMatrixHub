import SwiftUI
import AppKit
import AudioMatrixCore

@main
struct AudioMatrixHubApp: App {
    @StateObject private var vm = AudioMatrixViewModel()

    var body: some Scene {
        MenuBarExtra {
            AudioMatrixControlCenterView(vm: vm)
                .frame(width: 344)
        } label: {
            Image(systemName: vm.isRecording ? "record.circle.fill" : ((vm.builtInDSP.isEnabled || vm.externalElementDSPEnabled || vm.loopbackActive) ? "waveform.circle.fill" : "waveform"))
        }
        .menuBarExtraStyle(.window)
    }
}

struct AudioMatrixControlCenterView: View {
    @ObservedObject var vm: AudioMatrixViewModel
    @State private var showTuneSubMenu: Bool = false
    @State private var showLoopbackPanel: Bool = false
    @State private var showProPluginHost: Bool = false
    @State private var showAppRouting: Bool = false
    @State private var showAllRunningApps: Bool = false
    @State private var showAllLoopbackApps: Bool = false

    private var physicalOutputs: [AudioDeviceInfo] {
        vm.physicalOutputDevices()
    }

    private var inputDevices: [AudioDeviceInfo] {
        vm.devices.filter {
            $0.hasInput &&
            !$0.name.localizedCaseInsensitiveContains(vm.config.virtualOutputBus)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // MARK: - Output

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Output")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.externalElementDSPEnabled {
                        Text("VST3 / AU Host")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.accentColor)
                    } else if vm.builtInDSP.isEnabled {
                        Text(vm.builtInDSP.summaryTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 4)

                VStack(spacing: 2) {
                    ForEach(physicalOutputs) { dev in
                        let isSelected = (vm.selectedPhysicalOutputName == dev.name)
                            || (!vm.externalElementDSPEnabled && !vm.listenTogetherActive && vm.currentOutput?.id == dev.id)
                        OutputDeviceRow(
                            device: dev,
                            isSelected: isSelected,
                            volume: Binding(
                                get: { vm.primaryVolume },
                                set: { vm.setPrimaryVolume($0) }
                            ),
                            onSelect: { vm.selectPhysicalOutput(dev) }
                        )
                    }
                }
                .padding(4)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)

                // Share Audio (Dual Output) + Independent Secondary Volume Slider
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(isOn: Binding(
                            get: { vm.listenTogetherActive },
                            set: { vm.setListenTogether($0) }
                        )) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.2.wave.2")
                                    .frame(width: 14)
                                Text("Share Audio (Dual Output)")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Spacer()

                        if vm.listenTogetherActive {
                            Picker("", selection: Binding(
                                get: { vm.listenDeviceB },
                                set: { newDev in
                                    vm.listenDeviceB = newDev
                                    vm.setListenTogether(true)
                                }
                            )) {
                                ForEach(physicalOutputs.filter { $0.name != vm.selectedPhysicalOutputName }, id: \.name) { d in
                                    Text(d.name).tag(d.name)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 132)
                        }
                    }

                    if vm.listenTogetherActive, !vm.listenDeviceB.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "headphones")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 14)
                            Text(vm.listenDeviceB)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 90, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(vm.secondaryVolume) },
                                    set: { vm.setSecondaryVolume(Float($0)) }
                                ),
                                in: 0.0...1.0
                            )
                            .controlSize(.mini)
                            Text("\(Int((vm.secondaryVolume * 100).rounded()))%")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)
            }

            Divider()

            // MARK: - Built-in Sound

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Built-in Sound")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showTuneSubMenu.toggle()
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 10))
                            Text("Tune")
                                .font(.system(size: 10, weight: .medium))
                            Image(systemName: showTuneSubMenu ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundColor(showTuneSubMenu ? .accentColor : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(showTuneSubMenu ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                // Row 1: Orthogonal Speaker / Spatial Simulation
                HStack(spacing: 4) {
                    Text("Speaker")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .leading)

                    ForEach(SpeakerSimMode.allCases) { mode in
                        let isSelected = (vm.builtInDSP.speakerMode == mode && !vm.externalElementDSPEnabled)
                        Button(action: { vm.selectSpeakerMode(mode) }) {
                            Text(mode.title)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                                )
                                .foregroundColor(isSelected ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .help(mode.subtitle)
                    }
                }

                // Row 2: Orthogonal Universal Tone EQ Profiles
                HStack(spacing: 4) {
                    Text("Tone EQ")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .leading)

                    ForEach(EQToneProfile.allCases) { profile in
                        let isSelected = (vm.builtInDSP.eqProfile == profile && !vm.externalElementDSPEnabled)
                        Button(action: { vm.selectEQProfile(profile) }) {
                            Text(profile.title)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                                )
                                .foregroundColor(isSelected ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .help(profile.subtitle)
                    }
                }

                if vm.pipelineStatus == .permissionRequired {
                    Text("Enable System Audio Recording in Privacy & Security, or install BlackHole 2ch.")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                }

                if showTuneSubMenu {
                    builtInTuneSubMenu
                }
            }

            Divider()

            // MARK: - Input

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Input")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { vm.toggleInputGuard(!vm.config.inputGuardEnabled) }) {
                        HStack(spacing: 4) {
                            Image(systemName: vm.config.inputGuardEnabled ? "lock.fill" : "lock.open")
                                .font(.system(size: 10))
                            Text(vm.config.inputGuardEnabled ? "BT Mic Guard On" : "BT Mic Guard Off")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(vm.config.inputGuardEnabled ? .accentColor : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(vm.config.inputGuardEnabled ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Prevents Bluetooth headsets from hijacking your microphone input")
                }
                .padding(.horizontal, 4)

                VStack(spacing: 2) {
                    ForEach(inputDevices) { dev in
                        let isSelected = (vm.currentInput?.id == dev.id)
                        DeviceRowButton(
                            icon: dev.sfSymbolName,
                            title: dev.name,
                            subtitle: dev.transportType,
                            isSelected: isSelected
                        ) {
                            vm.selectInputDevice(dev)
                        }
                    }
                }
                .padding(4)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)
            }

            Divider()

            // MARK: - Mixer & Routing Panels

            VStack(alignment: .leading, spacing: 6) {
                SectionDisclosureRow(
                    icon: "slider.vertical.3",
                    title: "App Mixer & Routing",
                    badge: vm.hasCustomAppMixerChanges ? "\(vm.appMixerStates.count) Custom" : "Default",
                    isExpanded: $showAppRouting,
                    resetTitle: "Reset to Default",
                    resetEnabled: vm.hasCustomAppMixerChanges,
                    onReset: { vm.resetAllAppMixerToDefault() }
                )

                if showAppRouting {
                    perAppRoutingPanel
                }

                SectionDisclosureRow(
                    icon: "record.circle",
                    title: "Loopback & Recorder",
                    badge: vm.isRecording ? formatDuration(vm.recordingSeconds) : (vm.loopbackActive ? "Live" : "Off"),
                    isExpanded: $showLoopbackPanel
                )

                if showLoopbackPanel {
                    loopbackAndRecorderPanel
                }

                SectionDisclosureRow(
                    icon: "puzzlepiece.extension",
                    title: "External VST3 / AU Chain",
                    badge: vm.externalElementDSPEnabled ? "Active" : "Optional",
                    isExpanded: $showProPluginHost
                )

                if showProPluginHost {
                    proPluginHostPanel
                }
            }

            Divider()

            // MARK: - Footer

            HStack {
                Button(action: { vm.refreshAll() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { vm.openConfigFile() }) {
                    Text("Config")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Text("·")
                    .foregroundColor(.secondary)

                Button(action: {
                    vm.cleanupOnQuit()
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .onAppear {
            vm.refreshAll()
        }
        .onChange(of: showAppRouting) { _, expanded in
            if expanded {
                vm.refreshAll()
            }
        }
        .onChange(of: showLoopbackPanel) { _, expanded in
            if expanded {
                vm.refreshAll()
            }
        }
    }

    // MARK: - Built-in Sound Fine-Tuning Sub-Menu

    private var builtInTuneSubMenu: some View {
        VStack(alignment: .leading, spacing: 7) {
            DSPSliderRow(
                label: "Speaker Crossfeed",
                valueText: "\(Int((vm.builtInDSP.crossfeedAmount * 100).rounded()))%",
                value: Binding(
                    get: { Double(vm.builtInDSP.crossfeedAmount) },
                    set: { val in
                        var s = vm.builtInDSP
                        s.crossfeedAmount = Float(val)
                        vm.updateBuiltInDSP(s)
                    }
                ),
                range: 0.0...1.0
            )

            DSPSliderRow(
                label: "Room Ambience",
                valueText: "\(Int((vm.builtInDSP.roomAmbience * 100).rounded()))%",
                value: Binding(
                    get: { Double(vm.builtInDSP.roomAmbience) },
                    set: { val in
                        var s = vm.builtInDSP
                        s.roomAmbience = Float(val)
                        vm.updateBuiltInDSP(s)
                    }
                ),
                range: 0.0...1.0
            )

            DSPSliderRow(
                label: "Bass (110 Hz)",
                valueText: String(format: "%+.1f dB", vm.builtInDSP.bassTiltDB),
                value: Binding(
                    get: { Double(vm.builtInDSP.bassTiltDB) },
                    set: { val in
                        var s = vm.builtInDSP
                        s.bassTiltDB = Float(val)
                        vm.updateBuiltInDSP(s)
                    }
                ),
                range: -6.0...6.0
            )

            DSPSliderRow(
                label: "Mid (2.5 kHz)",
                valueText: String(format: "%+.1f dB", vm.builtInDSP.midTiltDB),
                value: Binding(
                    get: { Double(vm.builtInDSP.midTiltDB) },
                    set: { val in
                        var s = vm.builtInDSP
                        s.midTiltDB = Float(val)
                        vm.updateBuiltInDSP(s)
                    }
                ),
                range: -6.0...6.0
            )

            DSPSliderRow(
                label: "Treble (7.0 kHz)",
                valueText: String(format: "%+.1f dB", vm.builtInDSP.trebleTiltDB),
                value: Binding(
                    get: { Double(vm.builtInDSP.trebleTiltDB) },
                    set: { val in
                        var s = vm.builtInDSP
                        s.trebleTiltDB = Float(val)
                        vm.updateBuiltInDSP(s)
                    }
                ),
                range: -6.0...6.0
            )

            Toggle(isOn: Binding(
                get: { vm.builtInDSP.safeHeadroomLimiter },
                set: { val in
                    var s = vm.builtInDSP
                    s.safeHeadroomLimiter = val
                    vm.updateBuiltInDSP(s)
                }
            )) {
                Text("Safe Headroom Soft Limiter")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Optional External VST3 / AU Host (Element)

    private var proPluginHostPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(
                    get: { vm.externalElementDSPEnabled },
                    set: { vm.setExternalElementDSP($0) }
                )) {
                    Text("Route via Element Host")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Spacer()

                if vm.elementInstalled {
                    Button(action: { vm.openElementGUI() }) {
                        HStack(spacing: 3) {
                            Text("Open")
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Element not installed")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            if !vm.blackHoleInstalled {
                HStack(spacing: 6) {
                    Text("BlackHole 2ch needed only for Element host")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { vm.installBlackHoleDriver() }) {
                        Text("Install BlackHole 2ch")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }

            slotGroupView(title: "Output Chain", bus: .output, slots: vm.outputSlots)
            slotGroupView(title: "Mic Input Chain", bus: .input, slots: vm.inputSlots)
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func slotGroupView(title: String, bus: AudioBusType, slots: [PluginSlot]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    Menu("VST3") {
                        ForEach(vm.installedPlugins.filter { $0.format == "VST3" }) { p in
                            Button(p.name) { vm.addPluginToBus(p, bus: bus) }
                        }
                    }
                    Menu("AudioUnit") {
                        ForEach(vm.installedPlugins.filter { $0.format == "AudioUnit" }) { p in
                            Button(p.name) { vm.addPluginToBus(p, bus: bus) }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }

            if slots.isEmpty {
                Text("Direct pass-through (no plugins)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(slots) { slot in
                    HStack(spacing: 6) {
                        Button(action: { vm.toggleSlotBypass(slot) }) {
                            Image(systemName: slot.bypass ? "circle" : "checkmark.circle.fill")
                                .foregroundColor(slot.bypass ? .secondary : .accentColor)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)

                        Text(slot.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(slot.bypass ? .secondary : .primary)
                            .lineLimit(1)

                        Spacer()

                        Button(action: { vm.removeSlot(slot) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Loopback & Internal Audio Recorder

    private var loopbackAndRecorderPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 1. Live Virtual Mic Loopback Header + Independent Reset Mix
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { vm.loopbackActive },
                        set: { vm.toggleLoopback($0) }
                    )) {
                        Text("Loopback to Virtual Input")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Spacer()

                    Button(action: { vm.resetLoopbackMixToDefault() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Reset Mix")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(vm.hasCustomLoopbackMix ? .accentColor : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(vm.hasCustomLoopbackMix ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.hasCustomLoopbackMix)
                }

                let busOptions = vm.loopbackBusOptions()
                HStack(spacing: 6) {
                    Text("Target Bus")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { vm.loopbackTargetBus },
                        set: { newBus in
                            vm.loopbackTargetBus = newBus
                            if vm.loopbackActive {
                                vm.toggleLoopback(true)
                            }
                        }
                    )) {
                        ForEach(busOptions, id: \.self) { name in
                            Text(name == CoreAudioManager.builtInVirtualMicName ? "AudioMatrix Virtual Mic (Built-in)" : name)
                                .tag(name)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 195)
                }

                if !vm.blackHoleInstalled {
                    HStack(spacing: 6) {
                        Text("Install BlackHole 2ch for multi-app loopback gains.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: { vm.installBlackHoleDriver() }) {
                            Text("Install BlackHole 2ch")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // 2. Independent Loopback & Recorder Source Mixer
            VStack(alignment: .leading, spacing: 5) {
                // Channel 1: Microphone Input
                HStack(spacing: 6) {
                    Button(action: { vm.setLoopbackIncludeMic(!vm.loopbackIncludeMic) }) {
                        Image(systemName: vm.loopbackIncludeMic ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11))
                            .foregroundColor(vm.loopbackIncludeMic ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Include Microphone in Loopback & Recording")

                    Image(systemName: "mic.fill")
                        .font(.system(size: 10))
                        .foregroundColor(vm.loopbackIncludeMic ? .accentColor : .secondary)
                        .frame(width: 12)

                    Text(vm.currentInput?.name ?? "Microphone")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(vm.loopbackIncludeMic ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(width: 82, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { Double(vm.loopbackMicGain) },
                            set: { vm.setLoopbackMicGain(Float($0)) }
                        ),
                        in: 0.0...2.5
                    )
                    .controlSize(.mini)
                    .disabled(!vm.loopbackIncludeMic)

                    Button(action: { vm.setLoopbackMicGain(1.8) }) {
                        Text("\(Int((vm.loopbackMicGain * 100).rounded()))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(vm.loopbackIncludeMic ? (abs(vm.loopbackMicGain - 1.8) > 0.02 ? .accentColor : .primary) : .secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                }

                // Channel 2: System Audio Master
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.square.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)

                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.primary)
                        .frame(width: 12)

                    Text("System Audio")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 82, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { Double(vm.loopbackSystemGain) },
                            set: { vm.setLoopbackSystemGain(Float($0)) }
                        ),
                        in: 0.0...2.0
                    )
                    .controlSize(.mini)

                    Button(action: { vm.setLoopbackSystemGain(1.0) }) {
                        Text("\(Int((vm.loopbackSystemGain * 100).rounded()))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(abs(vm.loopbackSystemGain - 1.0) > 0.02 ? .accentColor : .secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                }

                // Per-App Loopback Channels (include/exclude + independent Loopback volume)
                let lbApps = showAllLoopbackApps ? Array(vm.runningApps.prefix(10)) : Array(vm.runningApps.prefix(5))
                if !lbApps.isEmpty {
                    ForEach(lbApps) { app in
                        let included = vm.isAppIncludedInLoopback(app.bundleId)
                        let lbVol = vm.loopbackAppVolume(for: app.bundleId)
                        HStack(spacing: 6) {
                            Button(action: { vm.toggleLoopbackAppIncluded(app) }) {
                                Image(systemName: included ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 11))
                                    .foregroundColor(included ? .accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Include \(app.name) in Loopback & Recording")

                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 12, height: 12)
                            }

                            Circle()
                                .fill(app.isProducingAudio ? Color.green : Color.clear)
                                .frame(width: 4, height: 4)

                            Text(app.name)
                                .font(.system(size: 10))
                                .foregroundColor(included ? .primary : .secondary)
                                .lineLimit(1)
                                .frame(width: 72, alignment: .leading)

                            Slider(
                                value: Binding(
                                    get: { Double(lbVol) },
                                    set: { vm.setLoopbackAppVolume(app, volume: Float($0)) }
                                ),
                                in: 0.0...2.0
                            )
                            .controlSize(.mini)
                            .disabled(!included)

                            Button(action: { vm.setLoopbackAppVolume(app, volume: 1.0) }) {
                                Text(included ? "\(Int((lbVol * 100).rounded()))%" : "Off")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(!included ? .secondary : (abs(lbVol - 1.0) > 0.02 ? .accentColor : .secondary))
                                    .frame(width: 34, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if vm.runningApps.count > 5 {
                        Button(action: { showAllLoopbackApps.toggle() }) {
                            HStack {
                                Spacer()
                                Text(showAllLoopbackApps ? "Show Fewer Apps" : "Show All (\(vm.runningApps.count) Apps)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // 3. Internal Audio WAV Recorder
            HStack(spacing: 8) {
                Button(action: { vm.toggleRecording() }) {
                    HStack(spacing: 5) {
                        Image(systemName: vm.isRecording ? "stop.circle.fill" : "record.circle.fill")
                            .foregroundColor(vm.isRecording ? .red : .accentColor)
                        Text(vm.isRecording ? "Stop (\(formatDuration(vm.recordingSeconds)))" : "Record Internal Audio")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(vm.isRecording ? Color.red.opacity(0.14) : Color.primary.opacity(0.07))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Spacer()

                if let url = vm.lastRecordingURL, !vm.isRecording {
                    Button(action: { vm.revealLastRecordingInFinder() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                            Text("Finder")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help(url.lastPathComponent)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Output-Stage Per-App Mixer & Routing

    private var perAppRoutingPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            let displayedApps = showAllRunningApps ? Array(vm.runningApps.prefix(12)) : Array(vm.runningApps.prefix(6))
            if displayedApps.isEmpty {
                Text("No active media or communication apps detected.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(displayedApps) { app in
                        let appVol = vm.appVolume(for: app.bundleId)
                        let muted = vm.isAppMuted(app.bundleId)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 15, height: 15)
                                }
                                Circle()
                                    .fill(app.isProducingAudio ? Color.green : Color.clear)
                                    .frame(width: 5, height: 5)
                                Text(app.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Menu {
                                    Button("System Default") {
                                        vm.clearAppRoute(app)
                                    }
                                    Divider()
                                    ForEach(vm.devices.filter { $0.hasOutput }) { dev in
                                        Button(dev.name) {
                                            vm.routeApp(app, toDevice: dev)
                                        }
                                    }
                                } label: {
                                    Text(appRouteLabel(for: app.bundleId))
                                        .font(.system(size: 10))
                                        .foregroundColor(vm.appMixerStates[app.bundleId]?.targetDeviceUID != nil ? .accentColor : .secondary)
                                        .frame(width: 105, alignment: .trailing)
                                }
                                .menuStyle(.borderlessButton)
                            }

                            HStack(spacing: 6) {
                                Button(action: { vm.toggleAppMute(app) }) {
                                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(muted ? .red : .secondary)
                                        .frame(width: 16)
                                }
                                .buttonStyle(.plain)

                                Slider(
                                    value: Binding(
                                        get: { Double(appVol) },
                                        set: { vm.setAppVolume(app, volume: Float($0)) }
                                    ),
                                    in: 0.0...2.0
                                )
                                .controlSize(.mini)
                                .disabled(muted)

                                Button(action: { vm.setAppVolume(app, volume: 1.0) }) {
                                    Text("\(Int((appVol * 100).rounded()))%")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundColor(abs(appVol - 1.0) > 0.02 ? .accentColor : .secondary)
                                        .frame(width: 34, alignment: .trailing)
                                }
                                .buttonStyle(.plain)
                                .help("Click to reset app volume to 100%")
                            }
                        }
                        .padding(5)
                        .background(Color.primary.opacity(0.03))
                        .cornerRadius(6)
                    }
                }

                if vm.runningApps.count > 6 {
                    Button(action: { showAllRunningApps.toggle() }) {
                        HStack {
                            Spacer()
                            Text(showAllRunningApps ? "Show Less" : "Show All (\(vm.runningApps.count) Apps)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func appRouteLabel(for bundleId: String) -> String {
        guard let uid = vm.appMixerStates[bundleId]?.targetDeviceUID ?? vm.appRoutes[bundleId],
              let dev = vm.devices.first(where: { $0.uid == uid }) else {
            return "System Default"
        }
        return dev.name
    }
}

// MARK: - Reusable Native Control Center Components

struct OutputDeviceRow: View {
    let device: AudioDeviceInfo
    let isSelected: Bool
    @Binding var volume: Float
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                            .frame(width: 26, height: 26)
                        Image(systemName: device.outputSFSymbolName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isSelected ? .white : .primary)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(device.transportType)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                HStack(spacing: 8) {
                    Image(systemName: volume < 0.01 ? "speaker.slash.fill" : (volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 26)
                    Slider(
                        value: Binding(
                            get: { Double(volume) },
                            set: { volume = Float($0) }
                        ),
                        in: 0.0...1.0
                    )
                    .controlSize(.mini)
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct DeviceRowButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct DSPSliderRow: View {
    let label: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 108, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.mini)
            Text(valueText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

struct SectionDisclosureRow: View {
    let icon: String
    let title: String
    let badge: String
    @Binding var isExpanded: Bool
    var resetTitle: String? = nil
    var resetEnabled: Bool = false
    var onReset: (() -> Void)? = nil
    @State private var isHovered: Bool = false

    private var showResetButton: Bool {
        (isExpanded || resetEnabled) && resetTitle != nil && onReset != nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if !showResetButton {
                        Text(badge)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showResetButton, let resetTitle, let onReset {
                Button(action: onReset) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .semibold))
                        Text(resetTitle)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(resetEnabled ? .accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(resetEnabled ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(!resetEnabled)
                .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

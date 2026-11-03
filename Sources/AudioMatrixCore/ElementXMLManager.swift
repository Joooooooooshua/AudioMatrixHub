import Foundation

/// Parses and modifies Kushview Element `.els` XML sessions and `Element.conf` device configurations,
/// and scans installed VST3 / AU plugins on macOS so any plugin can be dynamically slotted.
public final class ElementXMLManager {
    public let sessionPath: String
    public let settingsPath: String

    public init(
        sessionPath: String = AudioMatrixPaths.defaultElementSessionPath,
        settingsPath: String = AudioMatrixPaths.defaultElementSettingsPath
    ) {
        self.sessionPath = AudioMatrixPaths.expandTilde(sessionPath)
        self.settingsPath = AudioMatrixPaths.expandTilde(settingsPath)
    }

    // MARK: - Installed Plugin Scanner (VST3 & AU)

    public func scanInstalledPlugins() -> [InstalledPlugin] {
        var plugins: [InstalledPlugin] = []
        let fm = FileManager.default

        let searchDirs: [(path: String, format: String, ext: String)] = [
            ("/Library/Audio/Plug-Ins/VST3", "VST3", "vst3"),
            ("/Library/Audio/Plug-Ins/Components", "AudioUnit", "component")
        ]

        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for item in items.sorted() where item.hasSuffix(".\(dir.ext)") {
                let name = String(item.dropLast(dir.ext.count + 1))
                let fullPath = "\(dir.path)/\(item)"
                plugins.append(InstalledPlugin(name: name, format: dir.format, identifier: fullPath))
            }
        }
        return plugins
    }

    // MARK: - Parse Dynamic Plugin Slots from .els XML

    public func loadSlotsFromSession() -> [PluginSlot] {
        let url = URL(fileURLWithPath: sessionPath)
        guard let doc = try? XMLDocument(contentsOf: url, options: [.nodePreserveAll]),
              let root = doc.rootElement(),
              let graphsElem = root.elements(forName: "graphs").first else {
            return []
        }

        var discovered: [PluginSlot] = []
        let graphNodes = graphsElem.elements(forName: "Node")

        for (graphIdx, graphNode) in graphNodes.enumerated() {
            let graphName = graphNode.attribute(forName: "name")?.stringValue ?? ""
            let defaultBus: AudioBusType = (graphIdx == 1 || graphName.lowercased().contains("input") || graphName.lowercased().contains("mic")) ? .input : .output

            guard let nodesContainer = graphNode.elements(forName: "nodes").first else { continue }
            for nodeElem in nodesContainer.elements(forName: "Node") {
                let format = nodeElem.attribute(forName: "format")?.stringValue ?? ""
                let identifier = nodeElem.attribute(forName: "identifier")?.stringValue ?? ""
                // Skip built-in I/O nodes (audio.input, audio.output, midi.input, midi.output)
                if format == "Internal" || identifier.hasPrefix("audio.") || identifier.hasPrefix("midi.") {
                    continue
                }

                let nodeId = Int(nodeElem.attribute(forName: "id")?.stringValue ?? "0") ?? 0
                let name = nodeElem.attribute(forName: "name")?.stringValue ?? URL(fileURLWithPath: identifier).deletingPathExtension().lastPathComponent
                let busAttr = nodeElem.attribute(forName: "bus")?.stringValue
                let bus = busAttr.flatMap { AudioBusType(rawValue: $0) } ?? defaultBus
                let bypass = (nodeElem.attribute(forName: "bypass")?.stringValue == "1")
                let gain = Float(nodeElem.attribute(forName: "gain")?.stringValue ?? "1.0") ?? 1.0

                discovered.append(
                    PluginSlot(
                        nodeId: nodeId,
                        name: name,
                        format: format,
                        identifier: identifier,
                        bus: bus,
                        bypass: bypass,
                        gain: gain
                    )
                )
            }
        }
        return discovered
    }

    // MARK: - Update Bypass / Gain in .els XML

    public func updateSlotInSession(nodeId: Int, bus: AudioBusType, bypass: Bool? = nil, gain: Float? = nil) throws {
        let url = URL(fileURLWithPath: sessionPath)
        let doc = try XMLDocument(contentsOf: url, options: [.nodePreserveAll])
        guard let root = doc.rootElement(),
              let graphsElem = root.elements(forName: "graphs").first else { return }

        let graphNodes = graphsElem.elements(forName: "Node")
        guard bus.graphIndex < graphNodes.count else { return }
        let targetGraph = graphNodes[bus.graphIndex]
        guard let nodesContainer = targetGraph.elements(forName: "nodes").first else { return }

        for nodeElem in nodesContainer.elements(forName: "Node") {
            if Int(nodeElem.attribute(forName: "id")?.stringValue ?? "") == nodeId {
                if let bypass = bypass {
                    nodeElem.removeAttribute(forName: "bypass")
                    nodeElem.addAttribute(XMLNode.attribute(withName: "bypass", stringValue: bypass ? "1" : "0") as! XMLNode)
                }
                if let gain = gain {
                    nodeElem.removeAttribute(forName: "gain")
                    nodeElem.addAttribute(XMLNode.attribute(withName: "gain", stringValue: String(format: "%.3f", gain)) as! XMLNode)
                }
            }
        }

        let xmlData = doc.xmlData(options: [.nodePrettyPrint])
        try xmlData.write(to: url, options: .atomic)
    }

    // MARK: - Dynamically Insert a New Plugin Slot & Auto-Wire Stereo Arcs

    @discardableResult
    public func addPluginSlot(plugin: InstalledPlugin, toBus bus: AudioBusType, initialBypass: Bool = false) throws -> PluginSlot {
        let url = URL(fileURLWithPath: sessionPath)
        let doc = try XMLDocument(contentsOf: url, options: [.nodePreserveAll])
        guard let root = doc.rootElement(),
              let graphsElem = root.elements(forName: "graphs").first else {
            throw NSError(domain: "ElementXMLManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid .els session XML"])
        }

        let graphNodes = graphsElem.elements(forName: "Node")
        guard bus.graphIndex < graphNodes.count else {
            throw NSError(domain: "ElementXMLManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bus graph not found in .els"])
        }

        let targetGraph = graphNodes[bus.graphIndex]
        guard let nodesContainer = targetGraph.elements(forName: "nodes").first,
              let arcsContainer = targetGraph.elements(forName: "arcs").first else {
            throw NSError(domain: "ElementXMLManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing nodes/arcs container"])
        }

        var maxId = bus == .output ? 10 : 20
        for nodeElem in nodesContainer.elements(forName: "Node") {
            if let idVal = Int(nodeElem.attribute(forName: "id")?.stringValue ?? "") {
                maxId = max(maxId, idVal)
            }
        }
        let newNodeId = maxId + 1
        let uuidStr = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let newNode = XMLElement(name: "Node")
        let attrs: [(String, String)] = [
            ("id", "\(newNodeId)"),
            ("format", plugin.format),
            ("identifier", plugin.identifier),
            ("type", "plugin"),
            ("name", plugin.name),
            ("bus", bus.rawValue),
            ("uuid", uuidStr),
            ("bypass", initialBypass ? "1" : "0"),
            ("persistent", "1"),
            ("renderMode", "single"),
            ("x", "160.0"),
            ("y", "\(140 + (newNodeId % 10) * 90).0"),
            ("mute", "0"),
            ("muteInput", "0"),
            ("enabled", "1"),
            ("gain", "1.0")
        ]
        for (k, v) in attrs {
            newNode.addAttribute(XMLNode.attribute(withName: k, stringValue: v) as! XMLNode)
        }
        newNode.addChild(XMLElement(name: "nodes"))
        newNode.addChild(XMLElement(name: "scripts"))
        let uiElem = XMLElement(name: "ui")
        let blockElem = XMLElement(name: "Block")
        blockElem.addAttribute(XMLNode.attribute(withName: "portAlignment", stringValue: "before") as! XMLNode)
        uiElem.addChild(blockElem)
        newNode.addChild(uiElem)

        let portsElem = XMLElement(name: "ports")
        let portDefs: [(String, String, String, String, String)] = [
            ("0", "0", "In L", "in_1", "input"),
            ("1", "1", "In R", "in_2", "input"),
            ("2", "0", "Out L", "out_1", "output"),
            ("3", "1", "Out R", "out_2", "output")
        ]
        for (idx, ch, name, sym, flow) in portDefs {
            let p = XMLElement(name: "Port")
            p.addAttribute(XMLNode.attribute(withName: "index", stringValue: idx) as! XMLNode)
            p.addAttribute(XMLNode.attribute(withName: "channel", stringValue: ch) as! XMLNode)
            p.addAttribute(XMLNode.attribute(withName: "type", stringValue: "audio") as! XMLNode)
            p.addAttribute(XMLNode.attribute(withName: "name", stringValue: name) as! XMLNode)
            p.addAttribute(XMLNode.attribute(withName: "symbol", stringValue: sym) as! XMLNode)
            p.addAttribute(XMLNode.attribute(withName: "flow", stringValue: flow) as! XMLNode)
            p.addAttribute(XMLNode.attribute(withName: "hiddenOnBlock", stringValue: "0") as! XMLNode)
            portsElem.addChild(p)
        }
        newNode.addChild(portsElem)
        nodesContainer.addChild(newNode)

        let outputNodeId = "2"
        var redirectedAny = false
        for arc in arcsContainer.elements(forName: "Arc") {
            if arc.attribute(forName: "destNode")?.stringValue == outputNodeId {
                arc.removeAttribute(forName: "destNode")
                arc.addAttribute(XMLNode.attribute(withName: "destNode", stringValue: "\(newNodeId)") as! XMLNode)
                redirectedAny = true
            }
        }

        if !redirectedAny {
            for ch in 0...1 {
                let inArc = XMLElement(name: "Arc")
                inArc.addAttribute(XMLNode.attribute(withName: "sourceNode", stringValue: "1") as! XMLNode)
                inArc.addAttribute(XMLNode.attribute(withName: "sourcePort", stringValue: "\(ch)") as! XMLNode)
                inArc.addAttribute(XMLNode.attribute(withName: "destNode", stringValue: "\(newNodeId)") as! XMLNode)
                inArc.addAttribute(XMLNode.attribute(withName: "destPort", stringValue: "\(ch)") as! XMLNode)
                arcsContainer.addChild(inArc)
            }
        }

        for ch in 0...1 {
            let outArc = XMLElement(name: "Arc")
            outArc.addAttribute(XMLNode.attribute(withName: "sourceNode", stringValue: "\(newNodeId)") as! XMLNode)
            outArc.addAttribute(XMLNode.attribute(withName: "sourcePort", stringValue: "\(ch + 2)") as! XMLNode)
            outArc.addAttribute(XMLNode.attribute(withName: "destNode", stringValue: outputNodeId) as! XMLNode)
            outArc.addAttribute(XMLNode.attribute(withName: "destPort", stringValue: "\(ch)") as! XMLNode)
            arcsContainer.addChild(outArc)
        }

        let xmlData = doc.xmlData(options: [.nodePrettyPrint])
        try xmlData.write(to: url, options: .atomic)

        return PluginSlot(
            nodeId: newNodeId,
            name: plugin.name,
            format: plugin.format,
            identifier: plugin.identifier,
            bus: bus,
            bypass: initialBypass,
            gain: 1.0
        )
    }

    // MARK: - Remove a Plugin Slot & Heal Stereo Arcs

    public func removePluginSlot(nodeId: Int, fromBus bus: AudioBusType) throws {
        let url = URL(fileURLWithPath: sessionPath)
        let doc = try XMLDocument(contentsOf: url, options: [.nodePreserveAll])
        guard let root = doc.rootElement(),
              let graphsElem = root.elements(forName: "graphs").first else { return }

        let graphNodes = graphsElem.elements(forName: "Node")
        guard bus.graphIndex < graphNodes.count else { return }
        let targetGraph = graphNodes[bus.graphIndex]
        guard let nodesContainer = targetGraph.elements(forName: "nodes").first,
              let arcsContainer = targetGraph.elements(forName: "arcs").first else { return }

        let targetIdStr = "\(nodeId)"
        var upstreamByPort: [String: (srcNode: String, srcPort: String)] = [:]
        var downstreamByPort: [String: (dstNode: String, dstPort: String)] = [:]

        let existingArcs = arcsContainer.elements(forName: "Arc")
        for arc in existingArcs {
            let srcNode = arc.attribute(forName: "sourceNode")?.stringValue ?? ""
            let srcPort = arc.attribute(forName: "sourcePort")?.stringValue ?? ""
            let dstNode = arc.attribute(forName: "destNode")?.stringValue ?? ""
            let dstPort = arc.attribute(forName: "destPort")?.stringValue ?? ""

            if dstNode == targetIdStr {
                upstreamByPort[dstPort] = (srcNode, srcPort)
            }
            if srcNode == targetIdStr {
                // Element stereo plugin ports map Out 2/3 -> In 0/1
                let channelKey = (srcPort == "2") ? "0" : (srcPort == "3" ? "1" : srcPort)
                downstreamByPort[channelKey] = (dstNode, dstPort)
            }
        }

        for i in stride(from: arcsContainer.childCount - 1, through: 0, by: -1) {
            if let elem = arcsContainer.child(at: i) as? XMLElement, elem.name == "Arc" {
                let s = elem.attribute(forName: "sourceNode")?.stringValue ?? ""
                let d = elem.attribute(forName: "destNode")?.stringValue ?? ""
                if s == targetIdStr || d == targetIdStr {
                    arcsContainer.removeChild(at: i)
                }
            }
        }

        for (chKey, up) in upstreamByPort {
            if let down = downstreamByPort[chKey] {
                let healedArc = XMLElement(name: "Arc")
                healedArc.addAttribute(XMLNode.attribute(withName: "sourceNode", stringValue: up.srcNode) as! XMLNode)
                healedArc.addAttribute(XMLNode.attribute(withName: "sourcePort", stringValue: up.srcPort) as! XMLNode)
                healedArc.addAttribute(XMLNode.attribute(withName: "destNode", stringValue: down.dstNode) as! XMLNode)
                healedArc.addAttribute(XMLNode.attribute(withName: "destPort", stringValue: down.dstPort) as! XMLNode)
                arcsContainer.addChild(healedArc)
            }
        }

        for i in stride(from: nodesContainer.childCount - 1, through: 0, by: -1) {
            if let elem = nodesContainer.child(at: i) as? XMLElement,
               elem.name == "Node",
               elem.attribute(forName: "id")?.stringValue == targetIdStr {
                nodesContainer.removeChild(at: i)
            }
        }

        let xmlData = doc.xmlData(options: [.nodePrettyPrint])
        try xmlData.write(to: url, options: .atomic)
    }

    // MARK: - Update Element.conf Hardware Input / Output Devices

    public func updateElementHardwareDevices(
        inputDeviceName: String,
        outputDeviceName: String,
        sampleRate: Double = 48000.0,
        bufferSize: Int = 256
    ) throws {
        let url = URL(fileURLWithPath: settingsPath)
        guard FileManager.default.fileExists(atPath: settingsPath),
              let doc = try? XMLDocument(contentsOf: url, options: [.nodePreserveAll]),
              let root = doc.rootElement() else {
            return
        }

        for valElem in root.elements(forName: "VALUE") {
            if valElem.attribute(forName: "name")?.stringValue == "devices",
               let setupElem = valElem.elements(forName: "DEVICESETUP").first {
                setupElem.removeAttribute(forName: "audioInputDeviceName")
                setupElem.addAttribute(XMLNode.attribute(withName: "audioInputDeviceName", stringValue: inputDeviceName) as! XMLNode)

                setupElem.removeAttribute(forName: "audioOutputDeviceName")
                setupElem.addAttribute(XMLNode.attribute(withName: "audioOutputDeviceName", stringValue: outputDeviceName) as! XMLNode)

                setupElem.removeAttribute(forName: "audioDeviceRate")
                setupElem.addAttribute(XMLNode.attribute(withName: "audioDeviceRate", stringValue: String(format: "%.1f", sampleRate)) as! XMLNode)

                setupElem.removeAttribute(forName: "audioDeviceBufferSize")
                setupElem.addAttribute(XMLNode.attribute(withName: "audioDeviceBufferSize", stringValue: "\(bufferSize)") as! XMLNode)
            }
        }

        let xmlData = doc.xmlData(options: [.nodePrettyPrint])
        try xmlData.write(to: url, options: .atomic)
    }

    // MARK: - Default Template Generation (Portable Out-of-the-Box Setup)

    public static func defaultTemplateXML(
        virtualOutputBus: String = "BlackHole 2ch",
        virtualMicBus: String = "MOTIV Mix Virtual"
    ) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Session version="1" name="AudioMatrix_Template" tempo="120.0" notes="AudioMatrix Dual-Bus Modular Patchbay" beatsPerBar="4" beatDivisor="2">
          <graphs active="0">
            <Node version="1" type="Graph" uuid="a10000007eec4883ad744157dba427a0" name="Output_Bus_Master" bypass="0" persistent="1" renderMode="single" keyStart="0" keyEnd="127" transpose="0" delayCompensation="0" tempo="120.0">
              <nodes>
                <Node id="1" format="Internal" identifier="audio.input" type="plugin" name="System In (\(virtualOutputBus))" relativeX="0.25" relativeY="0.15" pluginIdentifierString="Internal--da9d27b2-0" uuid="d76b107d36ed4c3097fe052412975153" bypass="0" persistent="1" renderMode="single" x="180.0" y="60.0" mute="0" muteInput="0" enabled="1">
                  <nodes/><scripts/><ui><Block displayMode="compact" portAlignment="before"/></ui>
                  <ports>
                    <Port index="0" channel="0" type="audio" name="Audio Out 1" symbol="audio_out_1" flow="output" hiddenOnBlock="0"/>
                    <Port index="1" channel="1" type="audio" name="Audio Out 2" symbol="audio_out_2" flow="output" hiddenOnBlock="0"/>
                  </ports>
                </Node>
                <Node id="2" format="Internal" identifier="audio.output" type="plugin" name="Headphones Out" relativeX="0.25" relativeY="0.75" pluginIdentifierString="Internal--83a94619-0" uuid="79bcc8631ff840f7911cd47f211841d5" bypass="0" persistent="1" renderMode="single" x="180.0" y="340.0" mute="0" muteInput="0" enabled="1">
                  <nodes/><scripts/><ui><Block displayMode="compact" portAlignment="before"/></ui>
                  <ports>
                    <Port index="0" channel="0" type="audio" name="Audio In 1" symbol="audio_in_1" flow="input" hiddenOnBlock="0"/>
                    <Port index="1" channel="1" type="audio" name="Audio In 2" symbol="audio_in_2" flow="input" hiddenOnBlock="0"/>
                  </ports>
                </Node>
              </nodes>
              <scripts/><ui><Block/><GraphEditorView width="980" height="600"/></ui>
              <arcs>
                <Arc sourceNode="1" sourcePort="0" destNode="2" destPort="0"/>
                <Arc sourceNode="1" sourcePort="1" destNode="2" destPort="1"/>
              </arcs>
              <ports>
                <Port index="0" channel="0" type="audio" name="Audio In 1" symbol="audio_in_1" flow="input"/>
                <Port index="1" channel="1" type="audio" name="Audio In 2" symbol="audio_in_2" flow="input"/>
                <Port index="2" channel="0" type="audio" name="Audio Out 1" symbol="audio_out_1" flow="output"/>
                <Port index="3" channel="1" type="audio" name="Audio Out 2" symbol="audio_out_2" flow="output"/>
              </ports>
            </Node>
            <Node version="1" type="Graph" uuid="b20000007eec4883ad744157dba427a1" name="Input_Bus_Mic" bypass="0" persistent="1" renderMode="single" keyStart="0" keyEnd="127" transpose="0" delayCompensation="0" tempo="120.0">
              <nodes>
                <Node id="1" format="Internal" identifier="audio.input" type="plugin" name="Mic In" relativeX="0.25" relativeY="0.15" pluginIdentifierString="Internal--da9d27b2-0" uuid="d76b107d36ed4c3097fe052412975201" bypass="0" persistent="1" renderMode="single" x="180.0" y="60.0" mute="0" muteInput="0" enabled="1">
                  <nodes/><scripts/><ui><Block displayMode="compact" portAlignment="before"/></ui>
                  <ports>
                    <Port index="0" channel="0" type="audio" name="Audio Out 1" symbol="audio_out_1" flow="output" hiddenOnBlock="0"/>
                    <Port index="1" channel="1" type="audio" name="Audio Out 2" symbol="audio_out_2" flow="output" hiddenOnBlock="0"/>
                  </ports>
                </Node>
                <Node id="2" format="Internal" identifier="audio.output" type="plugin" name="Virtual Mic Out (\(virtualMicBus))" relativeX="0.25" relativeY="0.75" pluginIdentifierString="Internal--83a94619-0" uuid="79bcc8631ff840f7911cd47f21184202" bypass="0" persistent="1" renderMode="single" x="180.0" y="340.0" mute="0" muteInput="0" enabled="1">
                  <nodes/><scripts/><ui><Block displayMode="compact" portAlignment="before"/></ui>
                  <ports>
                    <Port index="0" channel="0" type="audio" name="Audio In 1" symbol="audio_in_1" flow="input" hiddenOnBlock="0"/>
                    <Port index="1" channel="1" type="audio" name="Audio In 2" symbol="audio_in_2" flow="input" hiddenOnBlock="0"/>
                  </ports>
                </Node>
              </nodes>
              <scripts/><ui><Block/><GraphEditorView width="980" height="600"/></ui>
              <arcs>
                <Arc sourceNode="1" sourcePort="0" destNode="2" destPort="0"/>
                <Arc sourceNode="1" sourcePort="1" destNode="2" destPort="1"/>
              </arcs>
              <ports>
                <Port index="0" channel="0" type="audio" name="Audio In 1" symbol="audio_in_1" flow="input"/>
                <Port index="1" channel="1" type="audio" name="Audio In 2" symbol="audio_in_2" flow="input"/>
                <Port index="2" channel="0" type="audio" name="Audio Out 1" symbol="audio_out_1" flow="output"/>
                <Port index="3" channel="1" type="audio" name="Audio Out 2" symbol="audio_out_2" flow="output"/>
              </ports>
            </Node>
          </graphs>
          <controllers/>
          <maps/>
        </Session>
        """
    }

    public func ensureSessionFileExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: sessionPath) else { return }
        let url = URL(fileURLWithPath: sessionPath)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.defaultTemplateXML().data(using: .utf8)?.write(to: url, options: .atomic)
    }
}

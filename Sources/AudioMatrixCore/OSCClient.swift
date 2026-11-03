import Foundation
import Darwin

/// Lightweight, dependency-free bidirectional UDP OSC 1.0 client and feedback listener for Kushview Element.
public final class OSCClient {
    public let host: String
    public let port: UInt16

    private var sendSocket: Int32 = -1
    private let sendLock = NSLock()
    private var listenSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private let listenQueue = DispatchQueue(label: "com.audiomatrix.osc.listener")

    public init(host: String = "127.0.0.1", port: UInt16 = 9000) {
        self.host = host
        self.port = port
    }

    deinit {
        stopListening()
        sendLock.lock()
        if sendSocket >= 0 {
            close(sendSocket)
            sendSocket = -1
        }
        sendLock.unlock()
    }

    // MARK: - OSC Binary Encoding (OSC 1.0)

    public static func encodeOSCString(_ str: String) -> Data {
        var data = Data(str.utf8)
        data.append(0)
        let padCount = (4 - (data.count % 4)) % 4
        if padCount > 0 {
            data.append(contentsOf: repeatElement(UInt8(0), count: padCount))
        }
        return data
    }

    public static func encodeMessage(address: String, floatValue: Float) -> Data {
        var packet = encodeOSCString(address)
        packet.append(encodeOSCString(",f"))
        var bigEndianBits = floatValue.bitPattern.bigEndian
        withUnsafeBytes(of: &bigEndianBits) { rawBuffer in
            packet.append(contentsOf: rawBuffer)
        }
        return packet
    }

    public static func encodeMessage(address: String, intValue: Int32) -> Data {
        var packet = encodeOSCString(address)
        packet.append(encodeOSCString(",i"))
        var bigEndianVal = intValue.bigEndian
        withUnsafeBytes(of: &bigEndianVal) { rawBuffer in
            packet.append(contentsOf: rawBuffer)
        }
        return packet
    }

    public static func encodeMessage(address: String, stringValue: String) -> Data {
        var packet = encodeOSCString(address)
        packet.append(encodeOSCString(",s"))
        packet.append(encodeOSCString(stringValue))
        return packet
    }

    public static func encodeQuery(address: String) -> Data {
        var packet = encodeOSCString(address)
        packet.append(encodeOSCString(","))
        return packet
    }

    // MARK: - OSC Binary Decoding

    public static func decodeFloatMessage(_ data: Data) -> (address: String, value: Float)? {
        guard let (address, afterAddr) = readPaddedString(data, offset: 0),
              let (typeTag, afterTag) = readPaddedString(data, offset: afterAddr) else {
            return nil
        }
        if typeTag == ",f", afterTag + 4 <= data.count {
            let bits = data.subdata(in: afterTag..<(afterTag + 4)).withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            return (address, Float(bitPattern: bits))
        } else if typeTag == ",i", afterTag + 4 <= data.count {
            let intVal = data.subdata(in: afterTag..<(afterTag + 4)).withUnsafeBytes {
                Int32(bigEndian: $0.load(as: Int32.self))
            }
            return (address, Float(intVal))
        }
        return nil
    }

    private static func readPaddedString(_ data: Data, offset: Int) -> (String, Int)? {
        guard offset < data.count else { return nil }
        var end = offset
        while end < data.count && data[end] != 0 {
            end += 1
        }
        guard end < data.count,
              let str = String(data: data.subdata(in: offset..<end), encoding: .utf8) else {
            return nil
        }
        let rawLen = (end - offset) + 1
        let aligned = ((rawLen + 3) / 4) * 4
        return (str, offset + aligned)
    }

    // MARK: - UDP Dispatch

    @discardableResult
    public func sendRaw(_ packet: Data) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }

        if sendSocket < 0 {
            sendSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sendSocket >= 0 else { return false }
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let fd = sendSocket
        let sent = packet.withUnsafeBytes { rawBuf -> Int in
            guard let baseAddress = rawBuf.baseAddress else { return -1 }
            return withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(fd, baseAddress, packet.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            close(sendSocket)
            sendSocket = -1
            return false
        }
        return sent == packet.count
    }

    // MARK: - Non-Blocking UDP Feedback Listener

    @discardableResult
    public func startListening(port: UInt16 = 9001, onUpdate: @escaping (String, Float) -> Void) -> Bool {
        stopListening()

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return false
        }

        listenSocket = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: listenQueue)
        source.setEventHandler { [weak self] in
            guard let self = self, self.listenSocket >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                let bytesRead = recv(self.listenSocket, &buf, buf.count, 0)
                if bytesRead <= 0 { break }
                let packet = Data(buf[0..<bytesRead])
                if let decoded = Self.decodeFloatMessage(packet) {
                    DispatchQueue.main.async {
                        onUpdate(decoded.address, decoded.value)
                    }
                }
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        listenSource = source
        source.resume()
        return true
    }

    public func stopListening() {
        if let src = listenSource {
            src.cancel()
            listenSource = nil
            listenSocket = -1
        } else if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
    }

    // MARK: - Element Node Controls

    public func setNodeBypass(bus: AudioBusType, nodeId: Int, slug: String, bypass: Bool) {
        let val: Float = bypass ? 1.0 : 0.0
        sendRaw(Self.encodeMessage(address: "/element/graph/\(bus.graphIndex)/node/\(nodeId)/bypass", floatValue: val))
        sendRaw(Self.encodeMessage(address: "/element/node/\(slug)/bypass", floatValue: val))
    }

    public func setNodeGain(bus: AudioBusType, nodeId: Int, slug: String, gain: Float) {
        let clamped = max(0.0, min(1.0, gain))
        sendRaw(Self.encodeMessage(address: "/element/graph/\(bus.graphIndex)/node/\(nodeId)/outputgain", floatValue: clamped))
        sendRaw(Self.encodeMessage(address: "/element/node/\(slug)/outputgain", floatValue: clamped))
    }

    public func queryNodeBypass(bus: AudioBusType, nodeId: Int) {
        sendRaw(Self.encodeQuery(address: "/element/graph/\(bus.graphIndex)/node/\(nodeId)/bypass"))
    }

    public func sendCommand(_ command: String) {
        sendRaw(Self.encodeMessage(address: "/element/command", stringValue: command))
    }
}

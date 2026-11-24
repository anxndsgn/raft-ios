import Foundation

/// Engine.IO v4 over WebSocket: one packet per text frame, `<type digit><payload>`.
/// Types: 0 open, 1 close, 2 ping, 3 pong, 4 message, 5 upgrade, 6 noop.
enum EnginePacket: Sendable, Hashable {
    case open(EngineOpenInfo)
    case close
    case ping(String)
    case pong(String)
    case message(String)
    case upgrade
    case noop

    static func parse(_ frame: String) -> EnginePacket? {
        guard let first = frame.first else { return nil }
        let payload = String(frame.dropFirst())
        switch first {
        case "0": return EngineOpenInfo.parse(payload).map(EnginePacket.open)
        case "1": return .close
        case "2": return .ping(payload)
        case "3": return .pong(payload)
        case "4": return .message(payload)
        case "5": return .upgrade
        case "6": return .noop
        default: return nil
        }
    }

    var encoded: String {
        switch self {
        case .open(let info): "0" + info.json.jsonString()
        case .close: "1"
        case .ping(let payload): "2" + payload
        case .pong(let payload): "3" + payload
        case .message(let payload): "4" + payload
        case .upgrade: "5"
        case .noop: "6"
        }
    }
}

/// The open packet `0{"sid","upgrades","pingInterval","pingTimeout","maxPayload"}`. Missing
/// timing fields fall back to the socket.io server defaults (25 s / 20 s / 1 MB).
struct EngineOpenInfo: Sendable, Hashable {
    static let defaultPingInterval: Double = 25
    static let defaultPingTimeout: Double = 20
    static let defaultMaxPayload = 1_000_000

    var sid: String
    var upgrades: [String]
    /// Seconds.
    var pingInterval: Double
    /// Seconds.
    var pingTimeout: Double
    var maxPayload: Int
    /// Fields that were missing and defaulted (diagnostics).
    var defaulted: [String]

    static func parse(_ payload: String) -> EngineOpenInfo? {
        guard let object = JSONValue.parse(payload)?.objectValue, let sid = object["sid"]?.stringValue, !sid.isEmpty else { return nil }
        var defaulted: [String] = []
        func millis(_ key: String, _ fallback: Double) -> Double {
            if let value = object[key]?.doubleValue, value > 0 { return value / 1000 }
            defaulted.append(key)
            return fallback
        }
        let interval = millis("pingInterval", defaultPingInterval)
        let timeout = millis("pingTimeout", defaultPingTimeout)
        let maxPayload: Int
        if let value = object["maxPayload"]?.int64Value, value > 0 { maxPayload = Int(value) } else {
            defaulted.append("maxPayload")
            maxPayload = defaultMaxPayload
        }
        return EngineOpenInfo(
            sid: sid,
            upgrades: object["upgrades"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            pingInterval: interval,
            pingTimeout: timeout,
            maxPayload: maxPayload,
            defaulted: defaulted
        )
    }

    var json: JSONValue {
        [
            "sid": .string(sid),
            "upgrades": .array(upgrades.map(JSONValue.string)),
            "pingInterval": .number(pingInterval * 1000),
            "pingTimeout": .number(pingTimeout * 1000),
            "maxPayload": .number(Double(maxPayload)),
        ]
    }
}

/// Socket.IO v5 packet, carried in an Engine.IO message:
/// `<type>[<attachments>-][<namespace>,][<ack id>][<JSON data>]`.
struct SocketPacket: Sendable, Hashable {
    enum Kind: Int, Sendable, Hashable {
        case connect = 0
        case disconnect = 1
        case event = 2
        case ack = 3
        case connectError = 4
        case binaryEvent = 5
        case binaryAck = 6
    }

    var kind: Kind
    /// `/` is the main namespace and is omitted on the wire.
    var namespace: String = "/"
    var id: Int?
    var data: JSONValue?
    var attachments: Int = 0

    static func connect(auth: JSONValue?, namespace: String = "/") -> SocketPacket {
        SocketPacket(kind: .connect, namespace: namespace, data: auth)
    }

    static func event(_ name: String, _ args: [JSONValue] = [], id: Int? = nil, namespace: String = "/") -> SocketPacket {
        SocketPacket(kind: .event, namespace: namespace, id: id, data: .array([.string(name)] + args))
    }

    static func ack(id: Int, _ args: [JSONValue] = [], namespace: String = "/") -> SocketPacket {
        SocketPacket(kind: .ack, namespace: namespace, id: id, data: .array(args))
    }

    /// The event name of an EVENT packet.
    var eventName: String? {
        guard kind == .event || kind == .binaryEvent, let first = data?.arrayValue?.first else { return nil }
        return first.stringValue
    }

    /// EVENT arguments after the name, or ACK arguments.
    var arguments: [JSONValue] {
        guard let array = data?.arrayValue else { return [] }
        switch kind {
        case .event, .binaryEvent: return Array(array.dropFirst())
        default: return array
        }
    }

    var encoded: String {
        var out = String(kind.rawValue)
        if kind == .binaryEvent || kind == .binaryAck { out += "\(attachments)-" }
        if namespace != "/" { out += namespace + "," }
        if let id { out += String(id) }
        if let data { out += data.jsonString() }
        return out
    }

    static func parse(_ text: String) -> SocketPacket? {
        var index = text.startIndex
        guard index < text.endIndex, let typeDigit = text[index].wholeNumberValue, let kind = Kind(rawValue: typeDigit) else { return nil }
        index = text.index(after: index)
        var packet = SocketPacket(kind: kind)
        if kind == .binaryEvent || kind == .binaryAck {
            guard let dash = text[index...].firstIndex(of: "-"), let count = Int(text[index..<dash]) else { return nil }
            packet.attachments = count
            index = text.index(after: dash)
        }
        if index < text.endIndex, text[index] == "/" {
            let end = text[index...].firstIndex(of: ",") ?? text.endIndex
            packet.namespace = String(text[index..<end])
            index = end < text.endIndex ? text.index(after: end) : end
        }
        var digitsEnd = index
        while digitsEnd < text.endIndex, text[digitsEnd].isASCII, text[digitsEnd].isNumber { digitsEnd = text.index(after: digitsEnd) }
        if digitsEnd > index {
            guard let id = Int(text[index..<digitsEnd]) else { return nil }
            packet.id = id
            index = digitsEnd
        }
        if index < text.endIndex {
            guard let data = JSONValue.parse(String(text[index...])) else { return nil }
            packet.data = data
        }
        switch kind {
        case .event, .binaryEvent:
            guard packet.eventName != nil else { return nil }
        case .ack, .binaryAck:
            guard packet.id != nil else { return nil }
        default:
            break
        }
        return packet
    }
}

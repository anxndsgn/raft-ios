import Foundation
import Testing
@testable import Raft

struct SocketProtocolTests {
    @Test func engineOpenPacketReadsTimingInSeconds() throws {
        let packet = try #require(EnginePacket.parse(#"0{"sid":"abc","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#))
        guard case .open(let info) = packet else { Issue.record("not open"); return }
        #expect(info.sid == "abc")
        #expect(info.pingInterval == 25)
        #expect(info.pingTimeout == 20)
        #expect(info.maxPayload == 1_000_000)
        #expect(info.defaulted.isEmpty)
    }

    @Test func engineOpenPacketDefaultsMissingFields() throws {
        let packet = try #require(EnginePacket.parse(#"0{"sid":"abc"}"#))
        guard case .open(let info) = packet else { Issue.record("not open"); return }
        #expect(info.pingInterval == EngineOpenInfo.defaultPingInterval)
        #expect(info.pingTimeout == EngineOpenInfo.defaultPingTimeout)
        #expect(info.maxPayload == EngineOpenInfo.defaultMaxPayload)
        #expect(Set(info.defaulted) == ["pingInterval", "pingTimeout", "maxPayload"])
        #expect(EnginePacket.parse(#"0{"nosid":1}"#) == nil)
    }

    @Test func enginePingPongAndMessage() {
        #expect(EnginePacket.parse("2") == .ping(""))
        #expect(EnginePacket.parse("2probe") == .ping("probe"))
        #expect(EnginePacket.pong("").encoded == "3")
        #expect(EnginePacket.parse("1") == .close)
        #expect(EnginePacket.parse("6") == .noop)
        #expect(EnginePacket.parse("42[\"x\"]") == .message("2[\"x\"]"))
        #expect(EnginePacket.message("2[\"x\"]").encoded == "42[\"x\"]")
        #expect(EnginePacket.parse("") == nil)
        #expect(EnginePacket.parse("9") == nil)
    }

    @Test func socketEventEncodesWithoutDefaultNamespace() {
        let packet = SocketPacket.event("sync:resume", [["lastSeq": 5, "sinceHorizon": "123"]])
        #expect(packet.encoded == #"2["sync:resume",{"lastSeq":5,"sinceHorizon":"123"}]"#)
        #expect(EnginePacket.message(packet.encoded).encoded == #"42["sync:resume",{"lastSeq":5,"sinceHorizon":"123"}]"#)
    }

    @Test func socketEventWithAckIdAndAckRoundTrip() throws {
        #expect(SocketPacket.event("sync:horizon", id: 7).encoded == #"27["sync:horizon"]"#)
        let ack = try #require(SocketPacket.parse(#"37[{"horizon":"9001"}]"#))
        #expect(ack.kind == .ack)
        #expect(ack.id == 7)
        #expect(ack.arguments.first?["horizon"]?.stringValue == "9001")
        #expect(SocketPacket.ack(id: 12, [["socketId": "s"]]).encoded == #"312[{"socketId":"s"}]"#)
    }

    @Test func socketParsesServerEventWithAckId() throws {
        let packet = try #require(SocketPacket.parse(#"215["notification:desktop",{"a":1}]"#))
        #expect(packet.kind == .event)
        #expect(packet.id == 15)
        #expect(packet.eventName == "notification:desktop")
        #expect(packet.arguments == [["a": 1]])
    }

    @Test func socketConnectAndConnectError() throws {
        let connect = SocketPacket.connect(auth: ["token": "t", "serverId": "s"])
        #expect(connect.encoded == #"0{"serverId":"s","token":"t"}"#)
        let ok = try #require(SocketPacket.parse(#"0{"sid":"xyz"}"#))
        #expect(ok.kind == .connect)
        #expect(ok.data?["sid"]?.stringValue == "xyz")
        let refused = try #require(SocketPacket.parse(#"4{"message":"Not a member of this server"}"#))
        #expect(refused.kind == .connectError)
        #expect(SocketHandshakeError.classify(refused.data) == .notMember)
    }

    @Test func socketNamespaceAndBinaryHeader() throws {
        let packet = try #require(SocketPacket.parse(#"2/admin,3["x",1]"#))
        #expect(packet.namespace == "/admin")
        #expect(packet.id == 3)
        #expect(packet.encoded == #"2/admin,3["x",1]"#)
        let binary = try #require(SocketPacket.parse(#"51-["file",{"_placeholder":true,"num":0}]"#))
        #expect(binary.kind == .binaryEvent)
        #expect(binary.attachments == 1)
        #expect(binary.eventName == "file")
    }

    @Test func socketRejectsMalformedPackets() {
        #expect(SocketPacket.parse("") == nil)
        #expect(SocketPacket.parse("9") == nil)
        #expect(SocketPacket.parse("2{}") == nil, "an event needs a name array")
        #expect(SocketPacket.parse("3[]") == nil, "an ack needs an id")
        #expect(SocketPacket.parse("2[\"x\"") == nil, "broken JSON")
        #expect(SocketPacket.parse("1") != nil)
    }

    @Test func handshakeErrorsClassify() {
        #expect(SocketHandshakeError.classify(["message": "SSO_REQUIRED"]) == .ssoRequired)
        #expect(SocketHandshakeError.classify(["message": "x", "data": ["code": "SSO_REQUIRED"]]) == .ssoRequired)
        for message in ["Authentication required", "Invalid token type", "Invalid or expired token", "Authentication changed; reconnect required"] {
            #expect(SocketHandshakeError.classify(["message": .string(message)]) == .authRejected(message))
        }
        #expect(SocketHandshakeError.classify(["message": "boom"]) == .other("boom"))
        #expect(SocketHandshakeError.notMember.isTerminal)
        #expect(!SocketHandshakeError.authRejected("x").isTerminal)
    }

    @Test func reconnectPolicyDoublesWithJitterAndCaps() {
        let policy = ReconnectPolicy()
        #expect(policy.delay(failures: 1, random: 0.5) == 1)
        #expect(policy.delay(failures: 2, random: 0.5) == 2)
        #expect(policy.delay(failures: 3, random: 0.5) == 4)
        #expect(policy.delay(failures: 6, random: 0.5) == 30)
        #expect(policy.delay(failures: 50, random: 0.5) == 30)
        #expect(policy.delay(failures: 1, random: 0) == 0.5, "−50 % with the 0.5 s floor")
        #expect(policy.delay(failures: 1, random: 1) == 1.5)
        #expect(policy.delay(failures: 4, random: 0) == 4)
        #expect(policy.delay(failures: 10, random: 1) == 30, "never over the cap")
        for failures in 1...12 {
            let value = policy.delay(failures: failures)
            #expect(value >= 0.5 && value <= 30)
        }
    }

    @Test func realtimeEventsDecode() {
        let message: JSONValue = ["id": "m1", "seq": "41", "channelId": "c1", "senderType": "user", "senderId": "u", "content": "hi"]
        if case .messageNew(let decoded) = RealtimeEvent.decode(name: "message:new", args: [message]) {
            #expect(decoded.seq == 41)
        } else { Issue.record("bare message") }
        if case .messageNew(let decoded) = RealtimeEvent.decode(name: "message:new", args: [["message": message]]) {
            #expect(decoded.id == "m1")
        } else { Issue.record("wrapped message") }
        #expect(RealtimeEvent.decode(name: "dm:new", args: [["channelId": "d1"]]) == .directMessageNew(channelId: "d1"))
        #expect(RealtimeEvent.decode(name: "channel:joined", args: [["channelId": "c9"]]) == .channelJoined(channelId: "c9"))
        #expect(RealtimeEvent.decode(name: "heartbeat", args: [["seq": 99, "ts": 1]]) == .heartbeat(seq: 99))
        if case .readStateUpdatedBulk(let scopes) = RealtimeEvent.decode(
            name: "read_state:updated_bulk",
            args: [["scopes": [["scopeId": "a", "maxReadSeq": 3, "readStateVersion": 2], ["bad": true]]]]
        ) {
            #expect(scopes.map(\.scopeId) == ["a"])
        } else { Issue.record("bulk") }
        if case .other(let name, _) = RealtimeEvent.decode(name: "message:new", args: [["nope": 1]]) {
            #expect(name == "message:new", "undecodable payloads stay raw")
        } else { Issue.record("fallback") }
    }

    @Test func socketURLUsesWebSocketTransport() {
        let url = RealtimeClient.socketURL(URL(string: "https://api.raft.build")!)
        #expect(url.absoluteString == "wss://api.raft.build/socket.io/?EIO=4&transport=websocket")
        #expect(RealtimeClient.socketURL(URL(string: "http://localhost:3000")!).absoluteString == "ws://localhost:3000/socket.io/?EIO=4&transport=websocket")
    }
}

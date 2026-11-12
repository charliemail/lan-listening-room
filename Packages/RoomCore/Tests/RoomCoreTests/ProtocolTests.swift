import Foundation
import Testing
@testable import RoomCore

@Suite struct Framing {
    @Test func roundTripAcrossSplitAndCoalescedReads() throws {
        let a = try FrameCodec.encode(ClientMessage.heartbeat)
        let b = try FrameCodec.encode(ClientMessage.join(version: 1, nickname: "小明 🎧", code: "123456"))
        var stream = a + b
        var decoder = FrameCodec.Decoder()
        var out: [Data] = []
        while !stream.isEmpty { // one byte at a time: worst-case split
            out += try decoder.push(stream.prefix(1))
            stream = stream.dropFirst()
        }
        var whole = FrameCodec.Decoder()
        let coalesced = try whole.push(a + b)
        #expect(out == coalesced)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: out[1]) == .join(version: 1, nickname: "小明 🎧", code: "123456"))
    }

    @Test func oversizedLengthRejected() {
        var length = UInt32(RoomProtocol.maxFrameBytes + 1).bigEndian
        let header = Data(bytes: &length, count: 4)
        #expect(throws: FrameCodec.Failure.frameTooLarge(RoomProtocol.maxFrameBytes + 1)) {
            var decoder = FrameCodec.Decoder()
            _ = try decoder.push(header)
        }
    }

    @Test func zeroLengthRejected() {
        #expect(throws: FrameCodec.Failure.emptyFrame) {
            var decoder = FrameCodec.Decoder()
            _ = try decoder.push(Data([0, 0, 0, 0]))
        }
    }

    @Test func malformedJSONIsADecodeErrorNotACrash() throws {
        var decoder = FrameCodec.Decoder()
        let garbage = Data("{not json".utf8)
        var length = UInt32(garbage.count).bigEndian
        let frames = try decoder.push(Data(bytes: &length, count: 4) + garbage)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ClientMessage.self, from: frames[0]) }
    }
}

@Suite struct Names {
    @Test func trimsAndCountsCharacters() {
        #expect(NameRules.nickname("  小明  ") == "小明")
        #expect(NameRules.nickname(String(repeating: "👨‍👩‍👧", count: 24)) != nil, "family emoji is one Character")
        #expect(NameRules.nickname(String(repeating: "👨🏻‍👩🏻‍👧🏻‍👦🏻", count: 24)) != nil, "41-byte skin-toned family still fits")
        #expect(NameRules.nickname("a" + String(repeating: "\u{0301}", count: 2000)) == nil, "one Character, but too many bytes")
        #expect(NameRules.nickname(String(repeating: "a", count: 25)) == nil)
        #expect(NameRules.nickname(" \n ") == nil)
        #expect(NameRules.roomName(String(repeating: "房", count: 40)) != nil)
        #expect(NameRules.roomName(String(repeating: "房", count: 41)) == nil)
    }
}

@Suite struct Limits {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func locksAfterFiveFailuresThenUnlocks() {
        var g = GuessLimiter()
        for _ in 0..<4 { g.recordFailure("10.0.0.2", now: t0) }
        #expect(!g.isLocked("10.0.0.2", now: t0))
        g.recordFailure("10.0.0.2", now: t0)
        #expect(g.isLocked("10.0.0.2", now: t0.addingTimeInterval(29)))
        #expect(!g.isLocked("10.0.0.2", now: t0.addingTimeInterval(30)))
        #expect(!g.isLocked("10.0.0.3", now: t0), "other sources unaffected")
    }

    @Test func successResetsCount() {
        var g = GuessLimiter()
        for _ in 0..<4 { g.recordFailure("h", now: t0) }
        g.recordSuccess("h")
        g.recordFailure("h", now: t0)
        #expect(!g.isLocked("h", now: t0))
    }

    @Test func heartbeatTimeoutAt12s() {
        var l = Liveness<String>()
        l.touch("a", now: t0)
        l.touch("b", now: t0.addingTimeInterval(10))
        #expect(l.expired(now: t0.addingTimeInterval(12)).isEmpty)
        #expect(l.expired(now: t0.addingTimeInterval(12.1)) == ["a"])
    }
}

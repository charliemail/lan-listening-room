import Foundation
import Testing
@testable import RoomCore

private let t0 = Date(timeIntervalSince1970: 1_000)
private let creator = Member(id: MemberID("CREATOR"), nickname: "建房者")
private let bob = MemberID("BOB")
private let cat = MemberID("CAT")

private func room() -> RoomState {
    var r = RoomState(roomName: "房", creator: creator, makeCode: { "111111" })
    _ = try! r.join(id: bob, nickname: "Bob", code: "111111")
    _ = try! r.join(id: cat, nickname: "Cat", code: "111111")
    return r
}

private func offer(_ s: StreamInfo) -> SignalPayload { SignalPayload(streamID: s.id, kind: .offer, sdp: "v=0") }
private func answer(_ s: StreamInfo) -> SignalPayload { SignalPayload(streamID: s.id, kind: .answer, sdp: "v=0") }

@Suite struct Streams {
    @Test func onlyPresenterStartsAndStops() throws {
        var r = room()
        #expect(throws: RoomError.notPresenter) { try r.startStream(by: bob) }
        let s = try r.startStream(by: creator.id)
        #expect(r.snapshot(for: bob).stream == s)
        #expect(throws: RoomError.notPresenter) { try r.stopStream(by: bob) }
        try r.stopStream(by: creator.id)
        #expect(r.stream == nil)
    }

    @Test func startIsIdempotentSoSourceSwitchKeepsListeners() throws {
        var r = room()
        let first = try r.startStream(by: creator.id)
        let again = try r.startStream(by: creator.id)
        #expect(first == again)
    }

    @Test func presenterHandoverClearsStream() throws {
        var r = room()
        _ = try r.startStream(by: creator.id)
        let o = try r.offerTransfer(.presenter, to: bob, by: creator.id, now: t0)
        try r.acceptTransfer(o.id, by: bob, now: t0)
        #expect(r.stream == nil, "new presenter must press start; old stream must die")
        let next = try r.startStream(by: bob)
        #expect(next.presenterID == bob && next.epoch == r.presenterEpoch)
    }

    @Test func presenterLeavingClearsStream() throws {
        var r = room()
        let o = try r.offerTransfer(.presenter, to: bob, by: creator.id, now: t0)
        try r.acceptTransfer(o.id, by: bob, now: t0)
        _ = try r.startStream(by: bob)
        r.remove(bob)
        #expect(r.stream == nil && r.presenterID == creator.id)
    }

    /// Phase 3 exit, as logic: ten hand-overs back and forth; after each one exactly one presenter,
    /// a fresh stream id, and every earlier stream's offers refused.
    @Test func tenHandoversNeverLeaveTwoPresenters() throws {
        var r = room()
        var oldStreams: [StreamInfo] = []
        var current = creator.id
        for _ in 0..<10 {
            oldStreams.append(try r.startStream(by: current))
            let next = current == creator.id ? bob : creator.id
            let o = try r.offerTransfer(.presenter, to: next, by: current, now: t0)
            try r.acceptTransfer(o.id, by: next, now: t0)
            #expect(r.presenterID == next)
            #expect(r.stream == nil, "new presenter stays silent until they press start")
            for old in oldStreams {
                #expect(throws: RoomError.streamNotActive) { try r.validateSignal(from: current, to: cat, offer(old)) }
            }
            current = next
        }
        #expect(Set(oldStreams.map(\.id)).count == 10)
        #expect(r.presenterEpoch == 10)
    }

    @Test func hostTransferDoesNotTouchStream() throws {
        var r = room()
        let s = try r.startStream(by: creator.id)
        let o = try r.offerTransfer(.host, to: bob, by: creator.id, now: t0)
        try r.acceptTransfer(o.id, by: bob, now: t0)
        #expect(r.stream == s)
    }
}

@Suite struct Signals {
    @Test func presenterOfferAndListenerAnswerAllowed() throws {
        var r = room()
        let s = try r.startStream(by: creator.id)
        try r.validateSignal(from: creator.id, to: bob, offer(s))
        try r.validateSignal(from: bob, to: creator.id, answer(s))
    }

    @Test func nonPresenterCannotOffer() throws {
        var r = room()
        let s = try r.startStream(by: creator.id)
        #expect(throws: RoomError.invalidSignal) { try r.validateSignal(from: bob, to: cat, offer(s)) }
    }

    @Test func answerMustGoToPresenter() throws {
        var r = room()
        let s = try r.startStream(by: creator.id)
        #expect(throws: RoomError.invalidSignal) { try r.validateSignal(from: bob, to: cat, answer(s)) }
    }

    @Test func staleStreamRejected() throws {
        var r = room()
        let old = try r.startStream(by: creator.id)
        try r.stopStream(by: creator.id)
        _ = try r.startStream(by: creator.id)
        #expect(throws: RoomError.streamNotActive) { try r.validateSignal(from: creator.id, to: bob, offer(old)) }
    }

    @Test func formerPresenterCannotKeepFeeding() throws {
        var r = room()
        let s = try r.startStream(by: creator.id)
        let o = try r.offerTransfer(.presenter, to: bob, by: creator.id, now: t0)
        try r.acceptTransfer(o.id, by: bob, now: t0)
        #expect(throws: RoomError.streamNotActive) { try r.validateSignal(from: creator.id, to: cat, offer(s)) }
    }

    @Test func noStreamRejected() {
        let r = room()
        let fake = SignalPayload(streamID: UUID(), kind: .offer, sdp: "v=0")
        #expect(throws: RoomError.streamNotActive) { try r.validateSignal(from: creator.id, to: bob, fake) }
    }

    @Test func oversizedOrSelfOrUnknownTargetRejected() throws {
        var r = room()
        let s = try r.startStream(by: creator.id)
        let huge = SignalPayload(streamID: s.id, kind: .offer, sdp: String(repeating: "a", count: RoomProtocol.maxSDPBytes + 1))
        #expect(throws: RoomError.invalidSignal) { try r.validateSignal(from: creator.id, to: bob, huge) }
        #expect(throws: RoomError.invalidSignal) { try r.validateSignal(from: creator.id, to: creator.id, offer(s)) }
        #expect(throws: RoomError.invalidSignal) { try r.validateSignal(from: creator.id, to: MemberID("GONE"), offer(s)) }
    }
}

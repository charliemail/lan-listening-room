import Foundation
import Testing
@testable import RoomCore

private let t0 = Date(timeIntervalSince1970: 1_000)
private let creator = Member(id: MemberID("CREATOR"), nickname: "建房者")
private let bob = MemberID("BOB")
private let cat = MemberID("CAT")

/// Codes come from a fixed sequence so tests know the current and next code.
private func room() -> RoomState {
    let codes = CodeSequence(["111111", "222222", "333333"])
    var r = RoomState(roomName: "測試房", creator: creator, makeCode: { codes.next() })
    _ = try! r.join(id: bob, nickname: "Bob", code: "111111")
    _ = try! r.join(id: cat, nickname: "Cat", code: "111111")
    return r
}

private final class CodeSequence: @unchecked Sendable {
    private var codes: [String]
    private let lock = NSLock()
    init(_ codes: [String]) { self.codes = codes }
    func next() -> String { lock.withLock { codes.removeFirst() } }
}

@Suite struct JoinAndCode {
    @Test func wrongCodeRejected() {
        var r = room()
        #expect(throws: RoomError.wrongCode) { try r.join(id: MemberID("X"), nickname: "X", code: "000000") }
    }

    @Test func sameNicknameAllowedWithDistinctIDs() throws {
        var r = room()
        _ = try r.join(id: MemberID("BOB2"), nickname: "Bob", code: "111111")
        #expect(r.members.filter { $0.nickname == "Bob" }.count == 2)
    }

    @Test func refreshInvalidatesOldCodeButKeepsMembers() throws {
        var r = room()
        try r.refreshCode(by: creator.id)
        #expect(r.code == "222222")
        #expect(r.contains(bob) && r.contains(cat))
        #expect(throws: RoomError.wrongCode) { try r.join(id: MemberID("X"), nickname: "X", code: "111111") }
        _ = try r.join(id: MemberID("X"), nickname: "X", code: "222222")
    }

    @Test func onlyHostRefreshesAndSeesCode() {
        var r = room()
        #expect(throws: RoomError.notHost) { try r.refreshCode(by: bob) }
        #expect(r.snapshot(for: creator.id).code == "111111")
        #expect(r.snapshot(for: bob).code == nil)
    }

    @Test func roomFullAtTen() throws {
        var r = room()
        for i in 0..<7 { _ = try r.join(id: MemberID("M\(i)"), nickname: "M", code: "111111") }
        #expect(r.members.count == RoomProtocol.maxMembers)
        #expect(throws: RoomError.roomFull) { try r.join(id: MemberID("ELEVEN"), nickname: "M", code: "111111") }
    }

    @Test func invalidNicknameRejected() {
        var r = room()
        #expect(throws: RoomError.invalidNickname) { try r.join(id: MemberID("X"), nickname: "   ", code: "111111") }
    }
}

@Suite struct Kick {
    @Test func hostKicksMember() throws {
        var r = room()
        try r.kick(bob, by: creator.id)
        #expect(!r.contains(bob))
    }

    @Test func nonHostCannotKick() {
        var r = room()
        #expect(throws: RoomError.notHost) { try r.kick(cat, by: bob) }
    }

    @Test func cannotKickSelf() {
        var r = room()
        #expect(throws: RoomError.cannotKickSelf) { try r.kick(creator.id, by: creator.id) }
    }

    @Test func newHostCannotKickCreator() throws {
        var r = room()
        try handOver(.host, to: bob, in: &r)
        #expect(throws: RoomError.cannotKickCreator) { try r.kick(creator.id, by: bob) }
        #expect(r.contains(creator.id))
    }

    @Test func kickingPresenterReturnsPresenterToHost() throws {
        var r = room()
        try handOver(.presenter, to: cat, in: &r)
        let epoch = r.presenterEpoch
        try r.kick(cat, by: creator.id)
        #expect(r.presenterID == creator.id)
        #expect(r.presenterEpoch == epoch + 1)
    }
}

@Suite struct Transfers {
    @Test func hostTransferAccepted() throws {
        var r = room()
        try handOver(.host, to: bob, in: &r)
        #expect(r.hostID == bob)
        #expect(r.presenterID == creator.id, "host transfer must not move the presenter")
        #expect(r.snapshot(for: bob).code != nil)
        #expect(r.snapshot(for: creator.id).code == nil)
    }

    @Test func presenterPassedByPresenterNotHost() throws {
        var r = room()
        try handOver(.host, to: bob, in: &r) // bob is host, creator still presenter
        #expect(throws: RoomError.notPresenter) { try r.offerTransfer(.presenter, to: cat, by: bob, now: t0) }
        try handOver(.presenter, to: cat, in: &r, from: creator.id)
        #expect(r.presenterID == cat)
    }

    @Test func rejectKeepsHolder() throws {
        var r = room()
        let offer = try r.offerTransfer(.host, to: bob, by: creator.id, now: t0)
        try r.rejectTransfer(offer.id, by: bob)
        #expect(r.hostID == creator.id)
        #expect(r.pendingTransfers.isEmpty)
    }

    @Test func expiredOfferCannotBeAccepted() throws {
        var r = room()
        let offer = try r.offerTransfer(.host, to: bob, by: creator.id, now: t0)
        #expect(throws: RoomError.offerExpired) {
            try r.acceptTransfer(offer.id, by: bob, now: t0.addingTimeInterval(RoomProtocol.transferOfferTimeout + 1))
        }
        #expect(r.hostID == creator.id)
    }

    @Test func expireTransfersClearsAfterTimeout() throws {
        var r = room()
        _ = try r.offerTransfer(.presenter, to: bob, by: creator.id, now: t0)
        let early = r.expireTransfers(now: t0.addingTimeInterval(1))
        let due = r.expireTransfers(now: t0.addingTimeInterval(RoomProtocol.transferOfferTimeout))
        #expect(!early)
        #expect(due)
        #expect(r.pendingTransfers.isEmpty)
    }

    @Test func onlyTargetCanAccept() throws {
        var r = room()
        let offer = try r.offerTransfer(.host, to: bob, by: creator.id, now: t0)
        #expect(throws: RoomError.offerNotFound) { try r.acceptTransfer(offer.id, by: cat, now: t0) }
        #expect(r.hostID == creator.id)
    }

    @Test func doubleAcceptIsRejected() throws {
        var r = room()
        let offer = try r.offerTransfer(.host, to: bob, by: creator.id, now: t0)
        try r.acceptTransfer(offer.id, by: bob, now: t0)
        #expect(throws: RoomError.offerNotFound) { try r.acceptTransfer(offer.id, by: bob, now: t0) }
    }

    @Test func offerVoidWhenTargetLeaves() throws {
        var r = room()
        let offer = try r.offerTransfer(.host, to: bob, by: creator.id, now: t0)
        r.remove(bob)
        #expect(r.pendingTransfers.isEmpty)
        #expect(throws: RoomError.offerNotFound) { try r.acceptTransfer(offer.id, by: bob, now: t0) }
    }

    @Test func newerOfferReplacesOlder() throws {
        var r = room()
        let first = try r.offerTransfer(.host, to: bob, by: creator.id, now: t0)
        _ = try r.offerTransfer(.host, to: cat, by: creator.id, now: t0)
        #expect(throws: RoomError.offerNotFound) { try r.acceptTransfer(first.id, by: bob, now: t0) }
    }

    @Test func hostAndPresenterOffersAreIndependent() throws {
        var r = room()
        let host = try r.offerTransfer(.host, to: bob, by: creator.id, now: t0)
        let presenter = try r.offerTransfer(.presenter, to: cat, by: creator.id, now: t0)
        try r.acceptTransfer(host.id, by: bob, now: t0)
        try r.acceptTransfer(presenter.id, by: cat, now: t0)
        #expect(r.hostID == bob && r.presenterID == cat)
    }

    @Test func cannotOfferToSelf() {
        var r = room()
        #expect(throws: RoomError.cannotTransferToSelf) { try r.offerTransfer(.host, to: creator.id, by: creator.id, now: t0) }
    }
}

@Suite struct Departures {
    @Test func creatorLeavingClosesRoomEvenWhenNotHost() throws {
        var r = room()
        try handOver(.host, to: bob, in: &r)
        try handOver(.presenter, to: cat, in: &r, from: creator.id)
        #expect(r.remove(creator.id) == .roomClosed)
    }

    @Test func hostLeavingReturnsHostToCreator() throws {
        var r = room()
        try handOver(.host, to: bob, in: &r)
        #expect(r.remove(bob) == .memberLeft)
        #expect(r.hostID == creator.id)
    }

    @Test func presenterLeavingReturnsPresenterToCurrentHost() throws {
        var r = room()
        try handOver(.host, to: bob, in: &r)
        try handOver(.presenter, to: cat, in: &r, from: creator.id)
        r.remove(cat)
        #expect(r.presenterID == bob)
    }

    @Test func hostAndPresenterLeavingTogetherFallBackToCreator() throws {
        var r = room()
        try handOver(.host, to: bob, in: &r)
        try handOver(.presenter, to: bob, in: &r, from: creator.id)
        r.remove(bob)
        #expect(r.hostID == creator.id && r.presenterID == creator.id)
    }
}

private func handOver(_ role: RoomRole, to target: MemberID, in r: inout RoomState, from actor: MemberID? = nil) throws {
    let offer = try r.offerTransfer(role, to: target, by: actor ?? (role == .host ? r.hostID : r.presenterID), now: t0)
    try r.acceptTransfer(offer.id, by: target, now: t0)
}

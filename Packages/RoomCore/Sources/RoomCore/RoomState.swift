import Foundation

/// The coordinator's single source of truth. Only the coordinator mutates it, one message at a time,
/// so every rule below is checked against the current state (no races between members).
public struct RoomState: Sendable {
    public enum Departure: Equatable, Sendable {
        /// The creator's Mac hosts the room; without it there is no room.
        case roomClosed
        case memberLeft
    }

    public let roomName: String
    public let creatorID: MemberID
    public private(set) var members: [Member]
    public private(set) var hostID: MemberID
    public private(set) var presenterID: MemberID
    public private(set) var presenterEpoch = 0
    public private(set) var code: String
    public private(set) var revision = 0
    public private(set) var pendingTransfers: [RoomRole: TransferOffer] = [:]
    public private(set) var stream: StreamInfo?

    private let makeCode: @Sendable () -> String

    public init(roomName: String, creator: Member, makeCode: @escaping @Sendable () -> String = RoomState.randomCode) {
        self.roomName = roomName
        self.creatorID = creator.id
        self.members = [creator]
        self.hostID = creator.id
        self.presenterID = creator.id
        self.makeCode = makeCode
        self.code = makeCode()
    }

    public static func randomCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    public func contains(_ id: MemberID) -> Bool { members.contains { $0.id == id } }

    public func snapshot(for id: MemberID) -> RoomSnapshot {
        RoomSnapshot(
            roomName: roomName, revision: revision, members: members,
            creatorID: creatorID, hostID: hostID, presenterID: presenterID, presenterEpoch: presenterEpoch,
            you: id, code: id == hostID ? code : nil,
            pendingTransfers: RoomRole.allCases.compactMap { pendingTransfers[$0] },
            stream: stream
        )
    }

    // MARK: audio stream (presenter only)

    /// Idempotent: switching source while sharing keeps the same stream, so listeners stay connected.
    public mutating func startStream(by actor: MemberID) throws(RoomError) -> StreamInfo {
        guard actor == presenterID else { throw .notPresenter }
        if let stream { return stream }
        let started = StreamInfo(id: UUID(), presenterID: actor, epoch: presenterEpoch)
        stream = started
        revision += 1
        return started
    }

    public mutating func stopStream(by actor: MemberID) throws(RoomError) {
        guard actor == presenterID else { throw .notPresenter }
        guard stream != nil else { return }
        stream = nil
        revision += 1
    }

    /// Only offers from the current presenter to a member, and answers back to the presenter,
    /// for the current stream. Everything else is dropped so a former presenter can't keep feeding audio.
    public func validateSignal(from sender: MemberID, to target: MemberID, _ payload: SignalPayload) throws(RoomError) {
        guard let stream, stream.id == payload.streamID else { throw .streamNotActive }
        guard sender != target, contains(sender), contains(target),
              payload.sdp.utf8.count <= RoomProtocol.maxSDPBytes else { throw .invalidSignal }
        switch payload.kind {
        case .offer: guard sender == stream.presenterID else { throw .invalidSignal }
        case .answer: guard target == stream.presenterID else { throw .invalidSignal }
        }
    }

    // MARK: membership

    /// Code check and rate limiting happen before this (see `GuessLimiter`); here only room rules apply.
    public mutating func join(id: MemberID, nickname raw: String, code attempt: String) throws(RoomError) -> Member {
        guard let nickname = NameRules.nickname(raw) else { throw .invalidNickname }
        guard attempt == code else { throw .wrongCode }
        guard !contains(id) else { throw .alreadyJoined }
        guard members.count < RoomProtocol.maxMembers else { throw .roomFull }
        let member = Member(id: id, nickname: nickname)
        members.append(member)
        revision += 1
        return member
    }

    /// Leaving, timing out and being kicked all end here.
    @discardableResult
    public mutating func remove(_ id: MemberID) -> Departure {
        guard contains(id) else { return .memberLeft }
        if id == creatorID { return .roomClosed }
        members.removeAll { $0.id == id }
        pendingTransfers = pendingTransfers.filter { $0.value.from != id && $0.value.to != id }
        if hostID == id { hostID = creatorID }
        if presenterID == id { setPresenter(hostID) }
        revision += 1
        return .memberLeft
    }

    // MARK: host actions

    public mutating func refreshCode(by actor: MemberID) throws(RoomError) {
        guard actor == hostID else { throw .notHost }
        var next = makeCode()
        while next == code { next = makeCode() }
        code = next
        revision += 1
    }

    public mutating func kick(_ target: MemberID, by actor: MemberID) throws(RoomError) {
        guard actor == hostID else { throw .notHost }
        guard target != actor else { throw .cannotKickSelf }
        guard target != creatorID else { throw .cannotKickCreator }
        guard contains(target) else { throw .memberNotFound }
        remove(target)
    }

    // MARK: transfers (host by the host, presenter by the presenter)

    public mutating func offerTransfer(_ role: RoomRole, to target: MemberID, by actor: MemberID, now: Date) throws(RoomError) -> TransferOffer {
        guard actor == holder(of: role) else { throw role == .host ? .notHost : .notPresenter }
        guard target != actor else { throw .cannotTransferToSelf }
        guard contains(target) else { throw .memberNotFound }
        let offer = TransferOffer(id: UUID(), role: role, from: actor, to: target,
                                  expiresAt: now.addingTimeInterval(RoomProtocol.transferOfferTimeout))
        pendingTransfers[role] = offer // a newer offer replaces the older one
        revision += 1
        return offer
    }

    public mutating func acceptTransfer(_ offerID: UUID, by actor: MemberID, now: Date) throws(RoomError) {
        let offer = try pendingOffer(offerID, for: actor)
        // Consumed even when the checks below fail (mutations before a throw persist), so a stale
        // offer can never be accepted later.
        pendingTransfers[offer.role] = nil
        revision += 1
        guard now < offer.expiresAt else { throw .offerExpired }
        // The offer is only valid while its sender still holds the role.
        guard offer.from == holder(of: offer.role), contains(offer.to) else { throw .offerNotFound }
        switch offer.role {
        case .host: hostID = offer.to
        case .presenter: setPresenter(offer.to)
        }
    }

    public mutating func rejectTransfer(_ offerID: UUID, by actor: MemberID) throws(RoomError) {
        let offer = try pendingOffer(offerID, for: actor)
        pendingTransfers[offer.role] = nil
        revision += 1
    }

    /// Returns true if anything expired (caller then broadcasts a new snapshot).
    public mutating func expireTransfers(now: Date) -> Bool {
        let before = pendingTransfers.count
        pendingTransfers = pendingTransfers.filter { now < $0.value.expiresAt }
        guard pendingTransfers.count != before else { return false }
        revision += 1
        return true
    }

    // MARK: helpers

    private func holder(of role: RoomRole) -> MemberID {
        role == .host ? hostID : presenterID
    }

    private func pendingOffer(_ offerID: UUID, for actor: MemberID) throws(RoomError) -> TransferOffer {
        guard let offer = pendingTransfers.values.first(where: { $0.id == offerID }), offer.to == actor else {
            throw .offerNotFound
        }
        return offer
    }

    private mutating func setPresenter(_ id: MemberID) {
        guard presenterID != id else { return }
        presenterID = id
        presenterEpoch += 1
        // Handing over is eligibility only: the new presenter must press start themselves.
        stream = nil
    }
}

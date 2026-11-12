import Foundation

public enum RoomProtocol {
    public static let version = 1
    public static let maxFrameBytes = 64 * 1024
    public static let maxMembers = 10
    public static let heartbeatInterval: TimeInterval = 3
    public static let heartbeatTimeout: TimeInterval = 12
    public static let transferOfferTimeout: TimeInterval = 15
    public static let bonjourType = "_lanlisten._tcp"
    /// Real offers/answers are a few KB; anything far larger is not a legitimate SDP.
    public static let maxSDPBytes = 32 * 1024
}

/// The presenter's current audio session. A new presenter always means a new (or no) stream,
/// so a listener can reject media from anyone else by comparing ids.
public struct StreamInfo: Codable, Equatable, Sendable {
    public let id: UUID
    public let presenterID: MemberID
    public let epoch: Int
}

/// WebRTC offer/answer relayed by the coordinator (non-trickle: candidates are inside the SDP).
public struct SignalPayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case offer, answer }
    public let streamID: UUID
    public let kind: Kind
    public let sdp: String

    public init(streamID: UUID, kind: Kind, sdp: String) {
        self.streamID = streamID
        self.kind = kind
        self.sdp = sdp
    }
}

public struct MemberID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public static func random() -> MemberID { MemberID(UUID().uuidString) }
    /// Shown next to nicknames so same-named members can be told apart. Never used for permissions.
    public var short: String { String(raw.prefix(4)).uppercased() }
    public var description: String { short }
}

public struct Member: Codable, Equatable, Sendable, Identifiable {
    public let id: MemberID
    public let nickname: String
    public init(id: MemberID, nickname: String) {
        self.id = id
        self.nickname = nickname
    }
}

/// Host: admin (code, kick, pass host). Presenter: the one member who may share audio, passes it on themselves.
public enum RoomRole: String, Codable, Sendable, CaseIterable {
    case host, presenter
}

public struct TransferOffer: Codable, Equatable, Sendable {
    public let id: UUID
    public let role: RoomRole
    public let from: MemberID
    public let to: MemberID
    public let expiresAt: Date
}

/// What one member sees. `code` is filled only for the current host.
public struct RoomSnapshot: Codable, Equatable, Sendable {
    public let roomName: String
    public let revision: Int
    public let members: [Member]
    public let creatorID: MemberID
    public let hostID: MemberID
    public let presenterID: MemberID
    /// Bumps on every presenter change; Phase 3 uses it to reject audio from a previous presenter.
    public let presenterEpoch: Int
    public let you: MemberID
    public let code: String?
    public let pendingTransfers: [TransferOffer]
    public let stream: StreamInfo?
}

public enum RoomError: String, Codable, Error, Sendable {
    case unsupportedVersion
    case invalidNickname
    case wrongCode
    case tooManyAttempts
    case roomFull
    case notJoined
    case alreadyJoined
    case notHost
    case notPresenter
    case cannotKickSelf
    case cannotKickCreator
    case memberNotFound
    case cannotTransferToSelf
    case offerNotFound
    case offerExpired
    case streamNotActive
    case invalidSignal
    case malformedMessage
}

public enum ClientMessage: Codable, Equatable, Sendable {
    case join(version: Int, nickname: String, code: String)
    case refreshCode
    case kick(MemberID)
    case offerTransfer(role: RoomRole, to: MemberID)
    case acceptTransfer(offerID: UUID)
    case rejectTransfer(offerID: UUID)
    case startStream
    case stopStream
    case signal(to: MemberID, SignalPayload)
    case heartbeat
    case leave
}

public enum ServerMessage: Codable, Equatable, Sendable {
    /// Sent after every change; with ≤10 members a full snapshot is cheaper than a delta protocol.
    case snapshot(RoomSnapshot)
    /// Relayed offer/answer; `from` is set by the coordinator from the sender's connection, never trusted from the client.
    case signal(from: MemberID, SignalPayload)
    case error(RoomError)
    case kicked
    case roomClosed
    case heartbeat
}

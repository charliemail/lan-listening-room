import Foundation
import Network
import RoomCore

/// Runs on the creator's Mac. Owns the only writable `RoomState`; applies member messages one at a
/// time and broadcasts a fresh per-member snapshot after each change.
@MainActor
final class CoordinatorServer {
    /// Unjoined connections get this long to send `join`, so idle sockets can't pile up.
    static let joinDeadline: TimeInterval = 10
    static let maxConnections = 32

    let creatorID: MemberID
    private(set) var state: RoomState
    /// The creator's own UI is fed directly, not over a socket.
    var onLocalMessage: ((ServerMessage) -> Void)?
    var onListenerError: ((String) -> Void)?
    var onListening: ((UInt16) -> Void)?

    private struct Peer {
        let connection: FramedConnection
        var memberID: MemberID?
        let openedAt: Date
    }

    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var limiter = GuessLimiter()
    private var liveness = Liveness<MemberID>()
    private var tickTask: Task<Void, Never>?

    init(roomName: String, creatorNickname: String) {
        creatorID = .random()
        state = RoomState(roomName: roomName, creator: Member(id: creatorID, nickname: creatorNickname))
    }

    /// `port` nil lets the system pick one; a fixed port makes manual IP joins predictable.
    func start(port: UInt16?) throws {
        let listener = try port.flatMap(NWEndpoint.Port.init(rawValue:)).map { try NWListener(using: .tcp, on: $0) }
            ?? NWListener(using: .tcp)
        listener.service = service(port: port)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    guard let self, let listener, let port = listener.port?.rawValue else { return }
                    // An auto-picked port is only known now; re-advertising updates the TXT record
                    // (verified: browsers see the new TXT).
                    listener.service = self.service(port: port)
                    self.onListening?(port)
                case .failed(let error):
                    let inUse = if case .posix(.EADDRINUSE) = error { true } else { false }
                    self?.onListenerError?(inUse ? "連接埠已被其他程式使用，請換一個或留空自動選擇" : "無法開房：\(error)")
                default: break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(RoomProtocol.heartbeatInterval))
                self?.tick()
            }
        }
        broadcast()
    }

    /// Actions taken in the creator's own UI.
    func applyLocal(_ message: ClientMessage) {
        if case .leave = message {
            closeRoom()
        } else {
            apply(message, from: creatorID)
        }
    }

    func closeRoom() {
        tickTask?.cancel()
        tickTask = nil
        listener?.cancel()
        listener = nil
        for peer in peers.values { peer.connection.sendAndClose(ServerMessage.roomClosed) }
        peers = [:]
        onLocalMessage?(.roomClosed)
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        guard peers.count < Self.maxConnections else { connection.cancel(); return }
        let framed = FramedConnection(connection)
        let key = ObjectIdentifier(framed)
        peers[key] = Peer(connection: framed, memberID: nil, openedAt: Date())
        framed.onFrame = { [weak self] frame in self?.receive(frame, from: key) }
        framed.onClose = { [weak self] _ in self?.connectionClosed(key) }
        framed.start()
    }

    private func receive(_ frame: Data, from key: ObjectIdentifier) {
        guard let peer = peers[key] else { return }
        guard let message = try? JSONDecoder().decode(ClientMessage.self, from: frame) else {
            drop(key, with: .error(.malformedMessage))
            return
        }
        guard let memberID = peer.memberID else {
            join(message, peer: peer, key: key)
            return
        }
        apply(message, from: memberID)
    }

    private func join(_ message: ClientMessage, peer: Peer, key: ObjectIdentifier) {
        guard case .join(let version, let nickname, let code) = message else {
            drop(key, with: .error(.notJoined))
            return
        }
        guard version == RoomProtocol.version else {
            drop(key, with: .error(.unsupportedVersion))
            return
        }
        let source = peer.connection.remoteHost
        let now = Date()
        guard !limiter.isLocked(source, now: now) else {
            drop(key, with: .error(.tooManyAttempts))
            return
        }
        let id = MemberID.random()
        do {
            _ = try state.join(id: id, nickname: nickname, code: code)
        } catch {
            if error == .wrongCode { limiter.recordFailure(source, now: now) }
            drop(key, with: .error(error))
            return
        }
        limiter.recordSuccess(source)
        peers[key]?.memberID = id
        liveness.touch(id, now: now)
        broadcast()
    }

    private func apply(_ message: ClientMessage, from actor: MemberID) {
        let now = Date()
        if actor != creatorID { liveness.touch(actor, now: now) }
        do {
            switch message {
            case .heartbeat:
                return
            case .join:
                throw RoomError.alreadyJoined
            case .leave:
                memberLeft(actor)
                return
            case .refreshCode:
                try state.refreshCode(by: actor)
            case .kick(let target):
                try state.kick(target, by: actor)
                disconnect(target, with: .kicked)
            case .offerTransfer(let role, let target):
                _ = try state.offerTransfer(role, to: target, by: actor, now: now)
            case .acceptTransfer(let offerID):
                try state.acceptTransfer(offerID, by: actor, now: now)
            case .rejectTransfer(let offerID):
                try state.rejectTransfer(offerID, by: actor)
            case .startStream:
                _ = try state.startStream(by: actor)
            case .stopStream:
                try state.stopStream(by: actor)
            case .signal(let target, let payload):
                try state.validateSignal(from: actor, to: target, payload)
                send(.signal(from: actor, payload), to: target)
                return // relay only, no state change to broadcast
            }
        } catch let error as RoomError {
            send(.error(error), to: actor)
        } catch {
            send(.error(.malformedMessage), to: actor)
        }
        // Also after errors: a failed accept still consumes the offer.
        broadcast()
    }

    private func memberLeft(_ id: MemberID) {
        if state.remove(id) == .roomClosed {
            closeRoom()
            return
        }
        disconnect(id, with: nil)
        broadcast()
    }

    private func connectionClosed(_ key: ObjectIdentifier) {
        guard let peer = peers.removeValue(forKey: key) else { return }
        if let id = peer.memberID {
            liveness.forget(id)
            memberLeft(id)
        }
    }

    /// Closes a member's connection after the state already dropped them.
    private func disconnect(_ id: MemberID, with final: ServerMessage?) {
        liveness.forget(id)
        guard let key = peers.first(where: { $0.value.memberID == id })?.key,
              let peer = peers.removeValue(forKey: key) else { return }
        if let final { peer.connection.sendAndClose(final) } else { peer.connection.close() }
    }

    private func drop(_ key: ObjectIdentifier, with final: ServerMessage) {
        guard let peer = peers.removeValue(forKey: key) else { return }
        peer.connection.sendAndClose(final)
        if let id = peer.memberID { memberLeft(id) }
    }

    private func send(_ message: ServerMessage, to id: MemberID) {
        if id == creatorID {
            onLocalMessage?(message)
        } else {
            peers.values.first { $0.memberID == id }?.connection.send(message)
        }
    }

    private func broadcast() {
        for peer in peers.values {
            guard let id = peer.memberID else { continue }
            peer.connection.send(ServerMessage.snapshot(state.snapshot(for: id)))
        }
        onLocalMessage?(.snapshot(state.snapshot(for: creatorID)))
    }

    private func tick() {
        let now = Date()
        for peer in peers.values where peer.memberID != nil { peer.connection.send(ServerMessage.heartbeat) }
        for (key, peer) in peers where peer.memberID == nil && now.timeIntervalSince(peer.openedAt) > Self.joinDeadline {
            peers.removeValue(forKey: key)
            peer.connection.close()
        }
        for id in liveness.expired(now: now) {
            liveness.forget(id)
            memberLeft(id)
        }
        if state.expireTransfers(now: now) { broadcast() }
    }

    /// TXT values are capped at 255 bytes; the full name travels in the snapshot.
    /// `addrs` + `port` let joiners fall back to direct addresses when the Bonjour-resolved one is
    /// unreachable (e.g. a full-tunnel VPN sends LAN traffic into the tunnel, but the VPN address works).
    private func service(port: UInt16?) -> NWListener.Service {
        var txt = [
            "v": String(RoomProtocol.version),
            "room": Self.txtSafe(state.roomName),
            "creator": creatorID.short,
        ]
        if let port {
            txt["port"] = String(port)
            txt["addrs"] = Self.advertisedAddresses()
        }
        return NWListener.Service(name: "LANListen-\(creatorID.short)", type: RoomProtocol.bonjourType,
                                  domain: nil, txtRecord: NWTXTRecord(txt))
    }

    /// LAN interfaces first, then the rest (VPN); virtual bridges are skipped (not reachable from other Macs).
    /// Capped well under the 255-byte TXT value limit.
    private static func advertisedAddresses() -> String {
        let usable = WebRTCSupport.localIPv4Interfaces().filter { !$0.name.hasPrefix("bridge") && !$0.name.hasPrefix("vmnet") }
        let ordered = usable.filter { $0.name.hasPrefix("en") } + usable.filter { !$0.name.hasPrefix("en") }
        var out: [String] = []
        for entry in ordered where (out + [entry.address]).joined(separator: ",").utf8.count <= 200 {
            out.append(entry.address)
        }
        return out.joined(separator: ",")
    }

    private static func txtSafe(_ name: String) -> String {
        var out = ""
        for ch in name {
            guard out.utf8.count + String(ch).utf8.count <= 200 else { break }
            out.append(ch)
        }
        return out
    }
}

import AppKit
import Foundation
import Network
import RoomCore

/// What the room screen binds to. The creator talks to its in-process coordinator; everyone else
/// goes over TCP. Both feed the same snapshot/phase, so the UI has one code path.
@MainActor @Observable
final class RoomSession {
    enum Phase: Equatable {
        case connecting
        case joined
        case ended(String)
    }

    private(set) var phase = Phase.connecting
    private(set) var snapshot: RoomSnapshot?
    var lastError: String?
    /// Creator only: the port others use for manual joins. Stored (not derived from the server)
    /// so the view refreshes when the listener becomes ready.
    private(set) var listenPort: UInt16?

    /// Signals and stream commands go out raw (no `lastError` reset) so background traffic doesn't hide errors.
    @ObservationIgnored private(set) lazy var audio = RoomAudio { [weak self] in self?.transmit($0) }
    @ObservationIgnored private var server: CoordinatorServer?
    @ObservationIgnored private var connection: FramedConnection?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?

    var isCreator: Bool { server != nil }

    static func host(roomName: String, nickname: String, port: UInt16?) throws -> RoomSession {
        let session = RoomSession()
        let server = CoordinatorServer(roomName: roomName, creatorNickname: nickname)
        server.onLocalMessage = { [weak session] in session?.handle($0) }
        server.onListenerError = { [weak session] in session?.end($0) }
        server.onListening = { [weak session] in session?.listenPort = $0 }
        session.server = server
        session.observeSleep()
        try server.start(port: port)
        return session
    }

    /// Tries each candidate in order until one answers. A blocked TCP connect hangs instead of failing,
    /// so each attempt gets `attemptTimeout`; an answer that rejects us (wrong code…) ends the join, no retry.
    static func join(_ candidates: [NWEndpoint], nickname: String, code: String) -> RoomSession {
        let session = RoomSession()
        session.candidates = candidates
        session.joinRequest = .join(version: RoomProtocol.version, nickname: nickname, code: code)
        session.tryNextCandidate()
        session.startHeartbeat()
        session.observeSleep()
        return session
    }

    static let attemptTimeout: TimeInterval = 3
    /// Shown while joining, e.g. "10.75.5.7:47900".
    private(set) var currentAttempt: String?
    @ObservationIgnored private var candidates: [NWEndpoint] = []
    @ObservationIgnored private var joinRequest: ClientMessage?
    @ObservationIgnored private var attemptStarted = Date()

    private func tryNextCandidate() {
        let previous = connection
        connection = nil
        previous?.close() // its onClose sees it's no longer current and does nothing
        guard phase == .connecting, let request = joinRequest else { return }
        guard !candidates.isEmpty else {
            end("無法連到房間：所有位址都連不上。通常是公司 Wi-Fi 的裝置隔離、不同網段或防火牆；開著全通道 VPN 時，請確認房主也在同一個 VPN。")
            return
        }
        let endpoint = candidates.removeFirst()
        currentAttempt = Self.label(endpoint)
        attemptStarted = Date()

        let attempt = FramedConnection(NWConnection(to: endpoint, using: .tcp))
        attempt.onFrame = { [weak self, weak attempt] frame in
            guard let self, let attempt, self.connection === attempt,
                  let message = try? JSONDecoder().decode(ServerMessage.self, from: frame) else { return }
            self.handle(message)
        }
        attempt.onClose = { [weak self, weak attempt] error in
            guard let self, let attempt, self.connection === attempt else { return }
            if self.phase == .connecting {
                self.tryNextCandidate()
            } else {
                self.end(error.map { "連線中斷：\($0)" } ?? "與房間的連線已關閉")
            }
        }
        connection = attempt
        attempt.start()
        attempt.send(request)
    }

    private static func label(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port): "\(host):\(port)"
        case .service(let name, _, _, _): "\(name)（區網搜尋）"
        default: "\(endpoint)"
        }
    }

    func send(_ message: ClientMessage) {
        lastError = nil
        transmit(message)
    }

    private func transmit(_ message: ClientMessage) {
        if let server { server.applyLocal(message) } else { connection?.send(message) }
    }

    /// A sleeping Mac can't answer heartbeats; leaving explicitly lets others know right away instead of
    /// after the 12 s timeout, and on wake the user starts from the room list (no stale second coordinator).
    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.leave(reason: self.isCreator ? "電腦進入睡眠，房間已關閉" : "電腦進入睡眠，已離開房間")
            }
        }
    }

    func leave(reason: String = "你已離開房間") {
        if case .ended = phase { return }
        if server == nil {
            // Let `leave` reach the coordinator before the socket goes away; otherwise it only
            // notices via the closed connection (same outcome, but slower and less explicit).
            connection?.sendAndClose(ClientMessage.leave)
            connection = nil
        }
        end(reason) // for the creator, end() closes the room and tells everyone
    }

    // MARK: -

    private func handle(_ message: ServerMessage) {
        lastHeard = Date()
        switch message {
        case .snapshot(let snapshot):
            self.snapshot = snapshot
            if phase == .connecting { phase = .joined }
            audio.update(snapshot)
        case .signal(let from, let payload):
            audio.receive(from: from, payload)
        case .error(let error):
            switch error {
            case .streamNotActive, .invalidSignal:
                break // a signal raced a stream change; the next snapshot already corrects it
            default:
                if phase == .joined { lastError = error.message } else { end(error.message) }
            }
        case .kicked:
            end("你已被房主移出房間")
        case .roomClosed:
            end(isCreator ? "房間已關閉" : "建房者已離開，房間已結束")
        case .heartbeat:
            break
        }
    }

    private func startHeartbeat() {
        let started = Date()
        heartbeatTask = Task { [weak self] in
            var lastSent = started
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = Date()
                if self.phase == .connecting {
                    if now.timeIntervalSince(self.attemptStarted) > Self.attemptTimeout { self.tryNextCandidate() }
                    continue
                }
                if now.timeIntervalSince(self.lastHeard) > RoomProtocol.heartbeatTimeout {
                    self.end("與房間失去連線（超過 \(Int(RoomProtocol.heartbeatTimeout)) 秒沒有回應）")
                    return
                }
                if now.timeIntervalSince(lastSent) >= RoomProtocol.heartbeatInterval {
                    self.connection?.send(ClientMessage.heartbeat)
                    lastSent = now
                }
            }
        }
    }

    private func end(_ reason: String) {
        if case .ended = phase { return }
        phase = .ended(reason)
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        audio.shutdown()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        connection?.close()
        connection = nil
        if let server {
            self.server = nil
            server.closeRoom()
        }
    }
}

extension RoomError {
    var message: String {
        switch self {
        case .unsupportedVersion: "對方的 App 版本不相容，請更新到相同版本"
        case .invalidNickname: "暱稱需為 1～24 個字"
        case .wrongCode: "驗證碼錯誤"
        case .tooManyAttempts: "嘗試太多次，請 30 秒後再試"
        case .roomFull: "房間已滿（最多 \(RoomProtocol.maxMembers) 人）"
        case .notJoined, .alreadyJoined, .malformedMessage: "連線資料異常，請重新加入"
        case .notHost: "只有房主可以這麼做"
        case .notPresenter: "只有播歌者可以交棒"
        case .cannotKickSelf: "不能踢出自己"
        case .cannotKickCreator: "不能踢出建房者"
        case .memberNotFound: "對方已不在房間裡"
        case .cannotTransferToSelf: "不能轉給自己"
        case .offerNotFound: "邀請已失效"
        case .offerExpired: "邀請已逾時"
        case .streamNotActive, .invalidSignal: "音訊連線資料已過期"
        }
    }
}

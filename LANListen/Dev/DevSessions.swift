import CoreAudio
import Foundation
import Network
import RTCAudioDeviceShim
@preconcurrency import WebRTC

/// Our own count of PeerConnections opened minus closed. Non-zero while the UI says "disconnected"
/// means a connection leaked (the bug this exists to catch).
@MainActor @Observable
final class LiveConnections {
    static let shared = LiveConnections()
    private(set) var count = 0
    func opened() { count += 1 }
    func closed(_ n: Int = 1) { count = max(0, count - n) }
}

// MARK: - Sharer (Mac A)

/// Captures one app and sends it to every listener that connects to `port`. One PeerConnection per listener,
/// all fed by the same audio track, so a slow listener only affects its own connection.
@MainActor @Observable
final class ShareSession {
    struct Peer {
        let link: SignalingLink
        let pc: RTCPeerConnection
        let observer: PeerObserver
        var ice = "new"
    }

    var isSharing = false
    var selectedBundleID: String?
    var port = String(WebRTCSupport.defaultPort)
    var peers: [UUID: Peer] = [:]
    var stats = RTPStats()
    var kbps = 0.0
    var startedAt: Date?
    var errorMessage: String?

    private let device = CaptureAudioDevice()
    private let capture = AudioCaptureService()
    @ObservationIgnored private lazy var factory: RTCPeerConnectionFactory = {
        _ = WebRTCSupport.sslOnce
        return LLMakeFactory(device)
    }()
    private var track: RTCAudioTrack?
    private var listener: NWListener?
    private var statsTask: Task<Void, Never>?

    func start(bundleID: String, port: UInt16) async {
        guard !isSharing else { return }
        errorMessage = nil
        track = factory.audioTrack(with: factory.audioSource(with: WebRTCSupport.music), trackId: "music")

        let device = device
        capture.onAudio = { [weak self] buffer in
            do { try device.deliver(buffer) } catch {
                Task { @MainActor in self?.errorMessage = "\(error)" }
            }
        }
        capture.onStop = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = "擷取已停止：" + AudioCaptureService.describe(error)
                await self?.stop()
            }
        }

        do {
            try await capture.start(bundleID: bundleID)
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor in self?.errorMessage = "無法在連接埠 \(port) 監聽：\(error)" }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            errorMessage = AudioCaptureService.describe(error)
            await capture.stop()
            return
        }

        isSharing = true
        startedAt = Date()
        statsTask = Task { [weak self] in await self?.pollStats() }
    }

    func stop() async {
        statsTask?.cancel()
        statsTask = nil
        listener?.cancel()
        listener = nil
        for peer in peers.values {
            peer.pc.close()
            peer.link.close()
        }
        LiveConnections.shared.closed(peers.count)
        peers = [:]
        await capture.stop()
        track = nil
        isSharing = false
        startedAt = nil
        kbps = 0
    }

    private func accept(_ connection: NWConnection) {
        guard isSharing, let track else { connection.cancel(); return }
        let id = UUID()
        let link = SignalingLink(connection)
        let observer = PeerObserver()
        guard let pc = factory.peerConnection(with: WebRTCSupport.configuration(), constraints: WebRTCSupport.none, delegate: observer) else {
            connection.cancel()
            return
        }
        pc.add(track, streamIds: ["room"])
        peers[id] = Peer(link: link, pc: pc, observer: observer)
        LiveConnections.shared.opened()

        observer.onIceState = { [weak self] state in
            Task { @MainActor in self?.peers[id]?.ice = state.label }
        }
        observer.onGatheringComplete = { [weak pc] in
            guard let sdp = pc?.localDescription?.sdp else { return }
            link.send(SignalMessage(kind: .offer, sdp: sdp))
        }
        link.onMessage = { [weak pc] message in
            guard message.kind == .answer else { return }
            pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: message.sdp)) { _ in }
        }
        link.onClose = { [weak self] _ in
            Task { @MainActor in self?.drop(id) }
        }
        link.start()

        pc.offer(for: WebRTCSupport.none) { offer, error in
            guard let offer else { link.close(); return }
            pc.setLocalDescription(WebRTCSupport.preferStereoOpus(offer)) { error in
                if error != nil { link.close() }
            }
        }
    }

    private func drop(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.pc.close()
        LiveConnections.shared.closed()
    }

    private func pollStats() async {
        var lastBytes = 0.0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            var total = RTPStats()
            for peer in peers.values {
                let s = await RTPStats.read(peer.pc, inbound: false)
                total.bytes += s.bytes
                total.packets += s.packets
                total.codec = s.codec
            }
            kbps = max(0, total.bytes - lastBytes) * 8 / 1000
            lastBytes = total.bytes
            stats = total
        }
    }
}


// MARK: - Listener (Mac B)

@MainActor @Observable
final class ListenSession {
    static let warmUpSeconds = 10.0

    var host = ""
    var port = String(WebRTCSupport.defaultPort)
    var isConnected = false
    var ice = "—"
    var status = "未連線"
    var stats = RTPStats()
    var startedAt: Date?
    /// Concealment % during the first `warmUpSeconds`, frozen once that window ends, and the rest since.
    var warmUpConcealedPercent: Double?
    var steadyConcealedPercent: Double?
    var volume: Float = 1 { didSet { device.volume = isMuted ? 0 : volume } }
    var isMuted = false { didSet { device.volume = isMuted ? 0 : volume } }
    var outputDevices: [AudioOutputDevice] = []
    /// nil = system default. Lets this Mac's source audio and the received stream use different devices.
    var outputDeviceID: AudioDeviceID? { didSet { applyOutputDevice() } }
    var outputError: String?

    private let device = PlaybackAudioDevice()

    func refreshOutputDevices() {
        outputDevices = AudioOutputDevices.all()
        if let id = outputDeviceID, !outputDevices.contains(where: { $0.id == id }) {
            outputDeviceID = nil
        }
    }

    private func applyOutputDevice() {
        do {
            try device.setOutputDevice(outputDeviceID)
            outputError = nil
        } catch {
            outputError = "無法切換輸出裝置：\(error.localizedDescription)"
        }
    }
    @ObservationIgnored private lazy var factory: RTCPeerConnectionFactory = {
        _ = WebRTCSupport.sslOnce
        return LLMakeFactory(device)
    }()
    private var link: SignalingLink?
    private var pc: RTCPeerConnection?
    private var observer: PeerObserver?
    private var statsTask: Task<Void, Never>?
    /// Callbacks from an earlier connection carry their own id and are ignored once it no longer matches.
    private var connectionID: UUID?

    func connect() {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !isConnected, !host.isEmpty, let p = UInt16(port), let nwPort = NWEndpoint.Port(rawValue: p) else { return }
        let observer = PeerObserver()
        guard let pc = factory.peerConnection(with: WebRTCSupport.configuration(), constraints: WebRTCSupport.none, delegate: observer) else {
            status = "無法建立 PeerConnection"
            return
        }
        let id = UUID()
        let link = SignalingLink(NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp))

        observer.onIceState = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.ice = state.label
                if state == .failed { self.disconnect(reason: "ICE 連線失敗（區網不可達或被阻擋）") }
            }
        }
        observer.onGatheringComplete = { [weak pc] in
            guard let sdp = pc?.localDescription?.sdp else { return }
            link.send(SignalMessage(kind: .answer, sdp: sdp))
        }
        link.onMessage = { [weak pc] message in
            guard message.kind == .offer, let pc else { return }
            pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: message.sdp)) { error in
                guard error == nil else { link.close(); return }
                pc.answer(for: WebRTCSupport.none) { answer, _ in
                    guard let answer else { link.close(); return }
                    pc.setLocalDescription(WebRTCSupport.preferStereoOpus(answer)) { _ in }
                }
            }
        }
        link.onClose = { [weak self] error in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.disconnect(reason: error.map { "連線中斷：\($0)" } ?? "主持人已停止分享")
            }
        }

        connectionID = id
        self.observer = observer
        self.pc = pc
        self.link = link
        LiveConnections.shared.opened()
        link.start()
        device.volume = isMuted ? 0 : volume
        isConnected = true
        status = "連線中…"
        stats = RTPStats()
        warmUpConcealedPercent = nil
        steadyConcealedPercent = nil
        startedAt = Date()
        statsTask = Task { [weak self] in await self?.pollStats(pc: pc, id: id) }
    }

    func disconnect(reason: String = "已離開") {
        guard isConnected else { return }
        connectionID = nil
        statsTask?.cancel()
        statsTask = nil
        pc?.close()
        link?.close()
        pc = nil
        link = nil
        observer = nil
        LiveConnections.shared.closed()
        isConnected = false
        ice = "—"
        status = reason
        startedAt = nil
    }

    private func pollStats(pc: RTCPeerConnection, id: UUID) async {
        var warmUp: RTPStats?
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let next = await RTPStats.read(pc, inbound: true)
            guard connectionID == id, let startedAt else { return }
            stats = next
            if next.packets > 0 { status = "收聽中" }
            if warmUp == nil, Date().timeIntervalSince(startedAt) >= Self.warmUpSeconds {
                warmUp = next
                warmUpConcealedPercent = Self.percent(next.concealedSamples, next.totalSamples)
            }
            if let warmUp {
                steadyConcealedPercent = Self.percent(next.concealedSamples - warmUp.concealedSamples,
                                                      next.totalSamples - warmUp.totalSamples)
            }
        }
    }

    private static func percent(_ part: Double, _ whole: Double) -> Double { whole > 0 ? part / whole * 100 : 0 }
}

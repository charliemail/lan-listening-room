import CoreAudio
import Foundation
import RoomCore
import RTCAudioDeviceShim
@preconcurrency import WebRTC

/// Audio inside a room. Everything follows the coordinator's snapshot:
/// - presenter: capture runs and offers go out only while `snapshot.stream` belongs to us;
/// - listener: only an offer matching the current stream id and presenter is accepted.
/// Losing the stream (stop, hand-over, presenter left) tears the matching side down.
@MainActor @Observable
final class RoomAudio {
    enum ListenState: Equatable {
        case idle
        case waitingForPresenter
        case connecting
        case playing
        case failed
    }

    // Presenter
    var sources: [SourceApp] = []
    var selectedSource: String?
    private(set) var isCapturing = false
    private(set) var listenerStates: [MemberID: String] = [:]
    private(set) var sendKbps = 0.0
    var shareError: String?

    // Listener
    private(set) var listenState = ListenState.idle
    private(set) var receiveStats = RTPStats()
    var volume: Float = 1 { didSet { applyVolume() } }
    var isMuted = false { didSet { applyVolume() } }
    private(set) var pausedReason: String?
    private(set) var outputDevices: [AudioOutputDevice] = []
    var outputDeviceID: AudioDeviceID? { didSet { applyOutputDevice() } }
    var outputError: String?

    @ObservationIgnored private let send: (ClientMessage) -> Void
    @ObservationIgnored private var snapshot: RoomSnapshot?

    @ObservationIgnored private let captureDevice = CaptureAudioDevice()
    @ObservationIgnored private lazy var captureFactory: RTCPeerConnectionFactory = {
        _ = WebRTCSupport.sslOnce
        return LLMakeFactory(captureDevice)
    }()
    @ObservationIgnored private let capture = AudioCaptureService()
    @ObservationIgnored private var captureStarting = false
    @ObservationIgnored private var track: RTCAudioTrack?
    @ObservationIgnored private var outgoing: [MemberID: Link] = [:]

    @ObservationIgnored private let playbackDevice = PlaybackAudioDevice()
    @ObservationIgnored private lazy var playbackFactory: RTCPeerConnectionFactory = {
        _ = WebRTCSupport.sslOnce
        return LLMakeFactory(playbackDevice)
    }()
    @ObservationIgnored private var incoming: Link?

    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var deviceWatcher: OutputDeviceWatcher?

    private struct Link {
        let streamID: UUID
        let pc: RTCPeerConnection
        let observer: PeerObserver
    }

    init(send: @escaping (ClientMessage) -> Void) {
        self.send = send
        outputDevices = AudioOutputDevices.all()
        deviceWatcher = OutputDeviceWatcher { [weak self] in self?.outputDevicesChanged() }
        capture.onStop = { [weak self] error in
            Task { @MainActor in self?.captureStopped(error) }
        }
        statsTask = Task { [weak self] in
            var lastBytes = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if let incoming = self.incoming {
                    self.receiveStats = await RTPStats.read(incoming.pc, inbound: true)
                }
                var bytes = 0.0
                for link in self.outgoing.values { bytes += await RTPStats.read(link.pc, inbound: false).bytes }
                self.sendKbps = max(0, bytes - lastBytes) * 8 / 1000
                lastBytes = bytes
            }
        }
    }

    // MARK: inputs from the room

    func update(_ s: RoomSnapshot) {
        snapshot = s
        let me = s.you
        let myStream = s.stream?.presenterID == me ? s.stream : nil

        if let myStream {
            syncOutgoing(myStream, listeners: s.members.map(\.id).filter { $0 != me })
            if !isCapturing, !captureStarting, let source = selectedSource { Task { await startCapture(source) } }
        } else {
            closeOutgoing()
            if isCapturing { Task { await stopCapture() } }
        }

        if let stream = s.stream, stream.presenterID != me {
            if let incoming, incoming.streamID != stream.id { closeIncoming() }
            if incoming == nil { listenState = .connecting }
        } else {
            closeIncoming()
            listenState = s.presenterID == me ? .idle : .waitingForPresenter
        }
    }

    func receive(from sender: MemberID, _ payload: SignalPayload) {
        guard let s = snapshot, let stream = s.stream, stream.id == payload.streamID else { return }
        switch payload.kind {
        case .answer:
            guard stream.presenterID == s.you, let link = outgoing[sender], link.streamID == payload.streamID else { return }
            link.pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: payload.sdp)) { _ in }
        case .offer:
            guard sender == stream.presenterID, sender != s.you else { return }
            acceptOffer(from: sender, payload)
        }
    }

    func shutdown() {
        statsTask?.cancel()
        statsTask = nil
        deviceWatcher = nil
        closeOutgoing()
        closeIncoming()
        if isCapturing { Task { await stopCapture() } }
    }

    // MARK: presenter

    func loadSources() async {
        do {
            sources = try await AudioCaptureService.shareableApps()
            if selectedSource == nil || !sources.contains(where: { $0.bundleID == selectedSource }) {
                selectedSource = sources.first?.bundleID
            }
        } catch {
            shareError = AudioCaptureService.describe(error)
        }
    }

    func startSharing() {
        guard selectedSource != nil else { return }
        shareError = nil
        send(.startStream) // capture starts when the snapshot confirms the stream
    }

    func stopSharing() {
        send(.stopStream)
    }

    /// Same stream, new source: listeners keep their connection.
    func switchSource(to bundleID: String) {
        selectedSource = bundleID
        guard isCapturing else { return }
        Task {
            await stopCapture()
            await startCapture(bundleID)
        }
    }

    private func startCapture(_ bundleID: String) async {
        captureStarting = true
        defer { captureStarting = false }
        let device = captureDevice
        capture.onAudio = { buffer in try? device.deliver(buffer) }
        do {
            try await capture.start(bundleID: bundleID)
            isCapturing = true
            // The stream may have ended while the capture was starting.
            if snapshot?.stream?.presenterID != snapshot?.you { await stopCapture() }
        } catch {
            shareError = AudioCaptureService.describe(error)
            send(.stopStream)
        }
    }

    private func stopCapture() async {
        isCapturing = false
        await capture.stop()
    }

    private func captureStopped(_ error: Error) {
        isCapturing = false
        shareError = "擷取已停止（來源 App 關閉或權限被撤銷）：" + AudioCaptureService.describe(error)
        send(.stopStream)
    }

    private func syncOutgoing(_ stream: StreamInfo, listeners: [MemberID]) {
        for (id, link) in outgoing where link.streamID != stream.id || !listeners.contains(id) {
            link.pc.close()
            outgoing[id] = nil
            listenerStates[id] = nil
        }
        let track = track ?? captureFactory.audioTrack(with: captureFactory.audioSource(with: WebRTCSupport.music), trackId: "music")
        self.track = track
        for id in listeners where outgoing[id] == nil {
            offer(to: id, stream: stream, track: track)
        }
    }

    private func offer(to id: MemberID, stream: StreamInfo, track: RTCAudioTrack) {
        let observer = PeerObserver()
        guard let pc = captureFactory.peerConnection(with: WebRTCSupport.configuration(), constraints: WebRTCSupport.none, delegate: observer) else {
            listenerStates[id] = "無法建立連線"
            return
        }
        pc.add(track, streamIds: ["room"])
        outgoing[id] = Link(streamID: stream.id, pc: pc, observer: observer)
        listenerStates[id] = "連線中"

        // WebRTC calls back on its own thread; only the (Sendable) identity crosses to the main actor,
        // which then resolves the live connection itself. Callbacks from a replaced connection are ignored.
        let pcID = ObjectIdentifier(pc)
        observer.onIceState = { [weak self] state in
            Task { @MainActor in
                guard let self, let link = self.outgoing[id], ObjectIdentifier(link.pc) == pcID else { return }
                self.listenerStates[id] = state.label
            }
        }
        observer.onGatheringComplete = { [weak self] in
            Task { @MainActor in
                guard let self, let link = self.outgoing[id], ObjectIdentifier(link.pc) == pcID,
                      let sdp = link.pc.localDescription?.sdp else { return }
                self.send(.signal(to: id, SignalPayload(streamID: stream.id, kind: .offer, sdp: sdp)))
            }
        }
        pc.offer(for: WebRTCSupport.none) { offer, _ in
            guard let offer else { return }
            pc.setLocalDescription(WebRTCSupport.preferStereoOpus(offer)) { _ in }
        }
    }

    private func closeOutgoing() {
        for link in outgoing.values { link.pc.close() }
        outgoing = [:]
        listenerStates = [:]
        track = nil
    }

    // MARK: listener

    private func acceptOffer(from presenter: MemberID, _ payload: SignalPayload) {
        closeIncoming()
        let observer = PeerObserver()
        guard let pc = playbackFactory.peerConnection(with: WebRTCSupport.configuration(), constraints: WebRTCSupport.none, delegate: observer) else {
            listenState = .failed
            return
        }
        incoming = Link(streamID: payload.streamID, pc: pc, observer: observer)
        listenState = .connecting
        applyVolume()

        let pcID = ObjectIdentifier(pc)
        observer.onIceState = { [weak self] state in
            Task { @MainActor in
                guard let self, let link = self.incoming, ObjectIdentifier(link.pc) == pcID else { return }
                switch state {
                case .connected, .completed: self.listenState = .playing
                case .failed: self.listenState = .failed
                default: break
                }
            }
        }
        observer.onGatheringComplete = { [weak self] in
            Task { @MainActor in
                guard let self, let link = self.incoming, ObjectIdentifier(link.pc) == pcID,
                      let sdp = link.pc.localDescription?.sdp else { return }
                self.send(.signal(to: presenter, SignalPayload(streamID: payload.streamID, kind: .answer, sdp: sdp)))
            }
        }
        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: payload.sdp)) { error in
            guard error == nil else { return }
            pc.answer(for: WebRTCSupport.none) { answer, _ in
                guard let answer else { return }
                pc.setLocalDescription(WebRTCSupport.preferStereoOpus(answer)) { _ in }
            }
        }
    }

    private func closeIncoming() {
        incoming?.pc.close()
        incoming = nil
        receiveStats = RTPStats()
    }

    // MARK: output

    func refreshOutputDevices() {
        outputDevices = AudioOutputDevices.all()
    }

    func resumeAfterDeviceChange() {
        pausedReason = nil
        do {
            try playbackDevice.setOutputDevice(outputDeviceID)
            try playbackDevice.restartIfStopped()
            outputError = nil
        } catch {
            outputError = "無法恢復播放：\(error.localizedDescription)"
        }
        applyVolume()
    }

    private func applyVolume() {
        playbackDevice.volume = isMuted || pausedReason != nil ? 0 : volume
    }

    private func applyOutputDevice() {
        do {
            try playbackDevice.setOutputDevice(outputDeviceID)
            outputError = nil
        } catch {
            outputError = "無法切換輸出裝置：\(error.localizedDescription)"
        }
    }

    /// Headphones unplugged or the default output changed: don't let music jump to the speakers.
    private func outputDevicesChanged() {
        outputDevices = AudioOutputDevices.all()
        guard incoming != nil else { return }
        let selectedGone = outputDeviceID.map { id in !outputDevices.contains { $0.id == id } } ?? false
        guard outputDeviceID == nil || selectedGone else { return } // a still-present chosen device is unaffected
        if selectedGone { outputDeviceID = nil }
        pausedReason = "輸出裝置已變更（例如耳機拔除），已暫停本機播放以免外放。確認輸出後按「繼續播放」。"
        applyVolume()
    }
}

/// Core Audio change notifications for the default output device and the device list.
final class OutputDeviceWatcher {
    private let block: AudioObjectPropertyListenerBlock
    private var addresses = [
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
    ]

    @MainActor
    init(onChange: @escaping @MainActor () -> Void) {
        block = { _, _ in MainActor.assumeIsolated { onChange() } }
        for i in addresses.indices {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], .main, block)
        }
    }

    deinit {
        for i in addresses.indices {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], .main, block)
        }
    }
}

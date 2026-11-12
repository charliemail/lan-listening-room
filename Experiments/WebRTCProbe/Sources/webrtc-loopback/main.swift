// Phase 0 WebRTC probe: generated stereo PCM -> custom RTCAudioDevice -> real PeerConnection
// (host candidates only, no STUN/TURN) -> second PeerConnection -> playout pulled by our device.
// The tone is LEFT channel only, so the received right channel tells us whether stereo survives.
import AudioToolbox
import Foundation
import RTCAudioDeviceShim
import WebRTC

let sampleRate = 48_000.0
let channelCount = 2
let framesPerTick = 480 // 10 ms
let toneAmplitude = 0.5
let measureSeconds = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 12

/// The ObjC ADM expects every record/playout callback on one fixed IO thread.
final class PacedThread {
    private let lock = NSLock()
    private var running = false
    private var isRunning: Bool { lock.withLock { running } }

    func start(_ tick: @escaping () -> Void) {
        lock.withLock { running = true }
        let thread = Thread { [self] in
            var next = ProcessInfo.processInfo.systemUptime
            while isRunning {
                tick()
                // ponytail: sleep pacing drifts a little; fine for a probe, real capture is clocked by SCK.
                next += Double(framesPerTick) / sampleRate
                let wait = next - ProcessInfo.processInfo.systemUptime
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { lock.withLock { running = false } }
}

final class LevelMeter {
    private let lock = NSLock()
    private var sumL = 0.0, sumR = 0.0, frames = 0

    func add(_ pcm: UnsafeBufferPointer<Int16>) {
        var l = 0.0, r = 0.0
        for i in stride(from: 0, to: pcm.count, by: 2) {
            let a = Double(pcm[i]) / 32768, b = Double(pcm[i + 1]) / 32768
            l += a * a; r += b * b
        }
        lock.withLock { sumL += l; sumR += r; frames += pcm.count / 2 }
    }

    /// Returns (rmsL, rmsR, frames) since last call.
    func drain() -> (Double, Double, Int) {
        lock.withLock {
            defer { sumL = 0; sumR = 0; frames = 0 }
            guard frames > 0 else { return (0, 0, 0) }
            return ((sumL / Double(frames)).squareRoot(), (sumR / Double(frames)).squareRoot(), frames)
        }
    }
}

final class ProbeDevice: NSObject, RTCAudioDevice {
    let name: String
    let sendsTone: Bool
    let playoutMeter = LevelMeter()
    private var delegate: RTCAudioDeviceDelegate?
    private let recordLoop = PacedThread()
    private let playoutLoop = PacedThread()
    private var phase = 0.0
    private var playoutBuffer = [Int16](repeating: 0, count: framesPerTick * channelCount)

    init(name: String, sendsTone: Bool) {
        self.name = name
        self.sendsTone = sendsTone
    }

    var deviceInputSampleRate: Double { sampleRate }
    var inputIOBufferDuration: TimeInterval { Double(framesPerTick) / sampleRate }
    var inputNumberOfChannels: Int { channelCount }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { sampleRate }
    var outputIOBufferDuration: TimeInterval { Double(framesPerTick) / sampleRate }
    var outputNumberOfChannels: Int { channelCount }
    var outputLatency: TimeInterval { 0 }

    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopRecording(); _ = stopPlayout()
        delegate = nil
        isInitialized = false
        return true
    }

    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    func initializeRecording() -> Bool { isRecordingInitialized = true; return true }

    func startRecording() -> Bool {
        log("\(name) startRecording")
        isRecording = true
        recordLoop.start { [weak self] in self?.deliverTone() }
        return true
    }

    func stopRecording() -> Bool { recordLoop.stop(); isRecording = false; return true }

    func startPlayout() -> Bool {
        log("\(name) startPlayout")
        isPlaying = true
        playoutLoop.start { [weak self] in self?.pullPlayout() }
        return true
    }

    func stopPlayout() -> Bool { playoutLoop.stop(); isPlaying = false; return true }

    private func deliverTone() {
        guard let delegate else { return }
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mHostTime = mach_absolute_time()
        ts.mFlags = .hostTimeValid
        // inputData must stay nil: the ADM's direct-buffer path forwards only `frames` samples,
        // which drops half of an interleaved stereo buffer. The render-block path sizes by channels.
        _ = delegate.deliverRecordedData(&flags, &ts, 1, UInt32(framesPerTick), nil, nil) { _, _, _, frames, abl, _ in
            let buffer = UnsafeMutableAudioBufferListPointer(abl)[0]
            let out = buffer.mData!.assumingMemoryBound(to: Int16.self)
            let step = 2 * Double.pi * 440 / sampleRate
            for i in 0..<Int(frames) {
                out[i * 2] = self.sendsTone ? Int16(sin(self.phase) * toneAmplitude * 32767) : 0
                out[i * 2 + 1] = 0
                self.phase += step
            }
            return noErr
        }
    }

    private func pullPlayout() {
        guard let delegate else { return }
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mHostTime = mach_absolute_time()
        ts.mFlags = .hostTimeValid
        playoutBuffer.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channelCount), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            _ = delegate.getPlayoutData(&flags, &ts, 0, UInt32(framesPerTick), &abl)
        }
        playoutBuffer.withUnsafeBufferPointer { playoutMeter.add($0) }
    }
}

final class PCObserver: NSObject, RTCPeerConnectionDelegate {
    let gatheringDone = DispatchSemaphore(value: 0)
    let connected = DispatchSemaphore(value: 0)
    let name: String
    init(name: String) { self.name = name }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        log("\(name) candidate \(candidate.sdp)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { gatheringDone.signal() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log("\(name) ice \(newState.rawValue)")
        if newState == .connected || newState == .completed { connected.signal() }
    }
}

func log(_ s: String) { print("[\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime))] \(s)") }

func fail(_ s: String) -> Never { print("FAIL: \(s)"); exit(1) }

func wait<T>(_ what: String, _ body: (@escaping (T) -> Void) -> Void) -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: T?
    body { result = $0; sem.signal() }
    if sem.wait(timeout: .now() + 10) == .timedOut { fail("timeout: \(what)") }
    return result!
}

/// Opus stereo is opt-in per SDP: `stereo=1` asks the remote to send stereo, `sprop-stereo=1` says we send it.
func preferStereoOpus(_ sdp: String) -> String {
    var lines = sdp.components(separatedBy: "\r\n")
    guard let rtpmap = lines.first(where: { $0.hasPrefix("a=rtpmap:") && $0.contains(" opus/48000/2") }),
          let pt = rtpmap.dropFirst("a=rtpmap:".count).split(separator: " ").first
    else { return sdp }
    if let i = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(pt) ") }) {
        lines[i] += ";stereo=1;sprop-stereo=1;maxaveragebitrate=160000"
    }
    return lines.joined(separator: "\r\n")
}

func munged(_ d: RTCSessionDescription) -> RTCSessionDescription {
    RTCSessionDescription(type: d.type, sdp: preferStereoOpus(d.sdp))
}

func negotiate(_ a: RTCPeerConnection, _ obsA: PCObserver, _ b: RTCPeerConnection, _ obsB: PCObserver) {
    let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    let offer: RTCSessionDescription = wait("offer") { done in a.offer(for: none) { sdp, err in
        if let err { fail("offer \(err)") }; done(sdp!) } }
    let e1: Error? = wait("A setLocal") { done in a.setLocalDescription(munged(offer)) { done($0) } }
    if let e1 { fail("A setLocal \(e1)") }
    if obsA.gatheringDone.wait(timeout: .now() + 10) == .timedOut { fail("A gathering") }

    let e2: Error? = wait("B setRemote") { done in b.setRemoteDescription(a.localDescription!) { done($0) } }
    if let e2 { fail("B setRemote \(e2)") }
    let answer: RTCSessionDescription = wait("answer") { done in b.answer(for: none) { sdp, err in
        if let err { fail("answer \(err)") }; done(sdp!) } }
    let e3: Error? = wait("B setLocal") { done in b.setLocalDescription(munged(answer)) { done($0) } }
    if let e3 { fail("B setLocal \(e3)") }
    if obsB.gatheringDone.wait(timeout: .now() + 10) == .timedOut { fail("B gathering") }

    let e4: Error? = wait("A setRemote") { done in a.setRemoteDescription(b.localDescription!) { done($0) } }
    if let e4 { fail("A setRemote \(e4)") }
}

func printStats(_ label: String, _ pc: RTCPeerConnection, types: Set<String>, keys: [String]) {
    let report: RTCStatisticsReport = wait("stats \(label)") { done in pc.statistics { done($0) } }
    for s in report.statistics.values where types.contains(s.type) {
        let fields = keys.compactMap { k in s.values[k].map { "\(k)=\($0)" } }.joined(separator: " ")
        print("  \(label) \(s.type): \(fields)")
    }
}

// MARK: - run

RTCInitializeSSL()
let sender = ProbeDevice(name: "A(sender)", sendsTone: true)
let receiver = ProbeDevice(name: "B(receiver)", sendsTone: false)
let factoryA = LLMakeFactory(sender)
let factoryB = LLMakeFactory(receiver)

let config = RTCConfiguration()
config.iceServers = [] // LAN only: host candidates, no STUN/TURN
config.sdpSemantics = .unifiedPlan
let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

let obsA = PCObserver(name: "A"), obsB = PCObserver(name: "B")
guard let pcA = factoryA.peerConnection(with: config, constraints: none, delegate: obsA),
      let pcB = factoryB.peerConnection(with: config, constraints: none, delegate: obsB)
else { fail("peerConnection creation") }

// Voice processing (AEC/AGC/NS/HPF) damages music; ask for it off and verify by tone stability below.
let musicConstraints = RTCMediaConstraints(mandatoryConstraints: [
    "googEchoCancellation": "false", "googAutoGainControl": "false",
    "googNoiseSuppression": "false", "googHighpassFilter": "false",
], optionalConstraints: nil)
let track = factoryA.audioTrack(with: factoryA.audioSource(with: musicConstraints), trackId: "music")
pcA.add(track, streamIds: ["room"])

negotiate(pcA, obsA, pcB, obsB)
if obsB.connected.wait(timeout: .now() + 10) == .timedOut { fail("ICE did not connect") }
log("ICE connected; measuring \(measureSeconds)s. Sent tone: L rms≈\(String(format: "%.3f", toneAmplitude / 2.0.squareRoot())), R=0")

var perSecond: [(Double, Double)] = []
for sec in 1...measureSeconds {
    Thread.sleep(forTimeInterval: 1)
    let (l, r, frames) = receiver.playoutMeter.drain()
    perSecond.append((l, r))
    print(String(format: "  t=%2ds  recv L=%.4f  R=%.4f  frames=%d", sec, l, r, frames))
}

printStats("A", pcA, types: ["outbound-rtp", "codec"], keys: ["mimeType", "channels", "sdpFmtpLine", "bytesSent", "packetsSent"])
printStats("B", pcB, types: ["inbound-rtp", "codec"], keys: ["mimeType", "channels", "sdpFmtpLine", "packetsReceived", "packetsLost", "jitter", "concealedSamples", "totalSamplesReceived"])

// Skip the first 2 s (jitter buffer warm-up).
let steady = perSecond.dropFirst(2)
let avgL = steady.map(\.0).reduce(0, +) / Double(steady.count)
let avgR = steady.map(\.1).reduce(0, +) / Double(steady.count)
let firstL = steady.first?.0 ?? 0, lastL = steady.last?.0 ?? 0
let driftDB = firstL > 0 && lastL > 0 ? 20 * log10(lastL / firstL) : .infinity

print("RESULT")
print(String(format: "  audio flowed (L rms > 0.05):        %@  (avg L=%.4f)", avgL > 0.05 ? "PASS" : "FAIL", avgL))
print(String(format: "  stereo kept (R/L < 0.1):            %@  (R/L=%.3f)", avgL > 0 && avgR / avgL < 0.1 ? "PASS" : "FAIL", avgL > 0 ? avgR / avgL : 0))
print(String(format: "  level stable, no NS/AGC (|drift|<3dB): %@  (%.2f dB)", abs(driftDB) < 3 ? "PASS" : "FAIL", driftDB))

pcA.close(); pcB.close()
RTCCleanupSSL()

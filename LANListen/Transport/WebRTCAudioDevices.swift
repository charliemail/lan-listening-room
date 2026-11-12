import AVFoundation
import CoreMedia
import RTCAudioDeviceShim
@preconcurrency import WebRTC

/// RTCAudioDevice boilerplate for the WebRTC ObjC ADM: 48 kHz stereo, Int16 interleaved on both paths.
/// Subclasses override only the side they implement; the other side is a no-op.
class AudioDeviceBase: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let channels = 2

    private let lock = NSLock()
    private var _delegate: RTCAudioDeviceDelegate?
    private var _isRecording = false
    var delegate: RTCAudioDeviceDelegate? { lock.withLock { _delegate } }

    var deviceInputSampleRate: Double { Self.sampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { Self.channels }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.sampleRate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { Self.channels }
    var outputLatency: TimeInterval { 0 }

    var isInitialized = false
    var isPlayoutInitialized = false
    var isPlaying = false
    var isRecordingInitialized = false
    var isRecording: Bool { lock.withLock { _isRecording } }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.withLock { _delegate = delegate }
        isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopRecording()
        _ = stopPlayout()
        lock.withLock { _delegate = nil }
        isInitialized = false
        return true
    }

    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    func startPlayout() -> Bool { isPlaying = true; return true }
    func stopPlayout() -> Bool { isPlaying = false; return true }
    func initializeRecording() -> Bool { isRecordingInitialized = true; return true }
    func startRecording() -> Bool { lock.withLock { _isRecording = true }; return true }
    func stopRecording() -> Bool { lock.withLock { _isRecording = false }; return true }

    static func hostTimeStamp() -> AudioTimeStamp {
        var ts = AudioTimeStamp()
        ts.mHostTime = mach_absolute_time()
        ts.mFlags = .hostTimeValid
        return ts
    }
}

/// Sender side: SCK sample buffers are pushed straight into WebRTC; its FineAudioBuffer re-chunks to 10 ms.
/// Nothing is delivered until WebRTC calls startRecording (i.e. a listener is connected and sending).
final class CaptureAudioDevice: AudioDeviceBase, @unchecked Sendable {
    enum DeliveryError: Error, CustomStringConvertible {
        case unsupportedFormat(String)
        var description: String {
            switch self { case .unsupportedFormat(let f): "不支援的擷取格式：\(f)（預期 48 kHz、2 ch、Float32 non-interleaved）" }
        }
    }

    /// Call on the SCK sample-handler queue.
    func deliver(_ sampleBuffer: CMSampleBuffer) throws {
        guard isRecording, let delegate else { return }
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        // ponytail: SCK honours the 48k/2ch config today; guard instead of an AVAudioConverter until a real source proves otherwise.
        guard asbd.mSampleRate == Self.sampleRate, asbd.mChannelsPerFrame == 2, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        else {
            throw DeliveryError.unsupportedFormat("\(asbd.mSampleRate) Hz \(asbd.mChannelsPerFrame) ch flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel)")
        }

        let frames = sampleBuffer.numSamples
        var flags = AudioUnitRenderActionFlags()
        var ts = Self.hostTimeStamp()
        try sampleBuffer.withAudioBufferList { abl, _ in
            guard abl.count >= 2,
                  let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            // inputData stays nil: the ADM's direct path counts only `frames` samples and would drop half of stereo.
            _ = delegate.deliverRecordedData(&flags, &ts, 1, UInt32(frames), nil, nil) { _, _, _, n, out, _ in
                guard let dst = UnsafeMutableAudioBufferListPointer(out)[0].mData?.assumingMemoryBound(to: Int16.self) else { return noErr }
                for i in 0..<Int(n) {
                    dst[2 * i] = Self.int16(left[i])
                    dst[2 * i + 1] = Self.int16(right[i])
                }
                return noErr
            }
        }
    }

    private static func int16(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
}

/// Listener side: AVAudioEngine's output clock pulls decoded PCM from WebRTC.
/// Volume/mute is local (mainMixer) and never reaches other members.
final class PlaybackAudioDevice: AudioDeviceBase, @unchecked Sendable {
    private static let maxFrames = 8192
    /// ponytail: fade-in hides NetEq's warm-up underruns (it starts with a small jitter target and grows it).
    /// Real fix is a minimum jitter-buffer delay, which the M156 ObjC SDK doesn't expose.
    private static let fadeInFrames = Int(sampleRate * 1.5)

    private let engine = AVAudioEngine()
    /// Touched only on the render thread after startPlayout resets it.
    private var renderedFrames = 0
    private var sourceNode: AVAudioSourceNode?
    /// WebRTC starts/stops playout on its worker thread while the UI switches devices on main;
    /// every engine graph change goes through this lock (never taken on the render thread).
    private let engineLock = NSLock()
    /// nil = follow the system default output.
    private var outputDeviceID: AudioDeviceID?
    private let pcm: UnsafeMutablePointer<Int16> = {
        let p = UnsafeMutablePointer<Int16>.allocate(capacity: PlaybackAudioDevice.maxFrames * 2)
        p.initialize(repeating: 0, count: PlaybackAudioDevice.maxFrames * 2)
        return p
    }()

    deinit { pcm.deallocate() }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Safe while playing: the engine is briefly stopped, re-pointed and restarted.
    func setOutputDevice(_ id: AudioDeviceID?) throws {
        engineLock.lock()
        defer { engineLock.unlock() }
        outputDeviceID = id
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        try applyOutputDevice()
        if wasRunning { try engine.start() }
    }

    /// macOS stops AVAudioEngine by itself when the output device changes underneath it.
    /// No-op unless playout is active (WebRTC started it) and the engine is down.
    func restartIfStopped() throws {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard sourceNode != nil, !engine.isRunning else { return }
        try applyOutputDevice()
        try engine.start()
    }

    /// Caller holds `engineLock` and the engine is stopped.
    private func applyOutputDevice() throws {
        guard var id = outputDeviceID ?? AudioOutputDevices.systemDefault(),
              let unit = engine.outputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        // The new device may run at another sample rate; let the engine re-negotiate mixer -> output.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    }

    override func startPlayout() -> Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard sourceNode == nil, let delegate else { return isPlaying }
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let pcm = pcm
        renderedFrames = 0
        // Render thread: no locks, no allocation; the delegate is captured once here.
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, outputList in
            let out = UnsafeMutableAudioBufferListPointer(outputList)
            let n = Int(min(frameCount, UInt32(Self.maxFrames)))
            var flags = AudioUnitRenderActionFlags()
            var ts = Self.hostTimeStamp()
            var interleaved = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 2 * MemoryLayout<Int16>.size), mData: pcm)
            )
            _ = delegate.getPlayoutData(&flags, &ts, 0, UInt32(n), &interleaved)
            guard out.count >= 2,
                  let l = out[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = out[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<Int(frameCount) {
                let gain = min(1, Float(renderedFrames + i) / Float(Self.fadeInFrames)) / 32768
                l[i] = i < n ? Float(pcm[2 * i]) * gain : 0
                r[i] = i < n ? Float(pcm[2 * i + 1]) * gain : 0
            }
            renderedFrames = min(renderedFrames + Int(frameCount), Self.fadeInFrames)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try applyOutputDevice()
            try engine.start()
        } catch {
            engine.detach(node)
            return false
        }
        sourceNode = node
        isPlaying = true
        return true
    }

    override func stopPlayout() -> Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        engine.stop()
        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil
        isPlaying = false
        return true
    }
}

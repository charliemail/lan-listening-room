import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

struct SourceApp: Identifiable, Hashable, Sendable {
    let name: String
    let bundleID: String
    var id: String { bundleID }
}

struct AudioLevels: Sendable {
    var rms: [Float] = []
    var peak: [Float] = []
    var frames = 0
    var callbacks = 0
    var format = "—"
}

enum CaptureError: LocalizedError {
    case noDisplay, appNotFound, permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "沒有螢幕與系統錄音權限。請到「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」允許 LAN Listen，然後完全結束（⌘Q）並重新開啟 App。"
        case .noDisplay: "找不到可用的顯示器，ScreenCaptureKit 需要以顯示器建立擷取範圍。"
        case .appNotFound: "來源 App 已關閉或不再可擷取，請重新整理清單。"
        }
    }
}

/// Every SCShareableContent call re-triggers the system prompt while access is missing,
/// so check first and ask at most once per launch; afterwards only show guidance.
@MainActor
enum ScreenCapturePermission {
    private static var requested = false

    static func ensure() throws {
        if CGPreflightScreenCaptureAccess() { return }
        if !requested {
            requested = true
            if CGRequestScreenCaptureAccess() { return }
        }
        throw CaptureError.permissionDenied
    }
}

/// Captures one application's audio output. Video is never consumed or stored:
/// no `.screen` output is attached, so SCK drops those frames.
final class AudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onStop: (@Sendable (Error) -> Void)?
    /// Raw buffers on the capture queue, for the transport. Must not block.
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)?

    private let queue = DispatchQueue(label: "lanlisten.capture.audio", qos: .userInteractive)
    private var stream: SCStream?
    private let lock = NSLock()
    private var pending = AudioLevels()
    private var sumSquares: [Float] = []

    static func shareableApps() async throws -> [SourceApp] {
        try await ScreenCapturePermission.ensure()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = Bundle.main.bundleIdentifier
        // SCK lists every windowed process (helpers, autofill agents, input methods, Control Center…).
        // ponytail: keep Dock apps only; menu-bar-only players won't show — add an "all processes" toggle if one matters.
        var seen = Set<String>()
        return content.applications
            .filter { $0.bundleIdentifier != me && !$0.applicationName.isEmpty }
            .filter { NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular }
            .filter { seen.insert($0.bundleIdentifier).inserted }
            .map { SourceApp(name: $0.applicationName, bundleID: $0.bundleIdentifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(bundleID: String) async throws {
        try await ScreenCapturePermission.ensure()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        // One bundle ID can own several processes; include all so the one actually playing isn't missed.
        let apps = content.applications.filter { $0.bundleIdentifier == bundleID }
        guard !apps.isEmpty else { throw CaptureError.appNotFound }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // Video can't be switched off; keep it as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        lock.withLock { pending = AudioLevels(); sumSquares = [] }
    }

    /// Levels accumulated since the previous call.
    func drainLevels() -> AudioLevels {
        lock.withLock {
            var out = pending
            if out.frames > 0 {
                out.rms = sumSquares.map { ($0 / Float(out.frames)).squareRoot() }
            }
            pending = AudioLevels(format: pending.format)
            sumSquares = []
            return out
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        onAudio?(sampleBuffer)

        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let format = "\(Int(asbd.mSampleRate)) Hz · \(channels) ch · \(isFloat ? "Float" : "Int")\(asbd.mBitsPerChannel) · "
            + (nonInterleaved ? "non-interleaved" : "interleaved")

        // ponytail: only Float32 is metered (what SCK delivers today); other formats show up in `format` instead of being guessed at.
        var squares = [Float](repeating: 0, count: channels)
        var peaks = [Float](repeating: 0, count: channels)
        let frames = sampleBuffer.numSamples
        if isFloat, asbd.mBitsPerChannel == 32 {
            try? sampleBuffer.withAudioBufferList { abl, _ in
                for c in 0..<channels {
                    let buffer = nonInterleaved ? abl[c] : abl[0]
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let stride = nonInterleaved ? 1 : channels
                    let offset = nonInterleaved ? 0 : c
                    for i in 0..<frames {
                        let v = data[i * stride + offset]
                        squares[c] += v * v
                        peaks[c] = max(peaks[c], abs(v))
                    }
                }
            }
        }

        lock.withLock {
            pending.format = format
            pending.callbacks += 1
            guard isFloat, asbd.mBitsPerChannel == 32 else { return }
            if sumSquares.count != channels {
                sumSquares = squares
                pending.peak = peaks
            } else {
                for c in 0..<channels {
                    sumSquares[c] += squares[c]
                    pending.peak[c] = max(pending.peak[c], peaks[c])
                }
            }
            pending.frames += frames
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}

extension AudioCaptureService {
    /// User-facing text for capture failures; permission denial gets settings guidance instead of a raw error.
    static func describe(_ error: Error) -> String {
        if let scError = error as? SCStreamError, scError.code == .userDeclined {
            return "沒有螢幕與系統錄音權限。請到「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」允許 LAN Listen，然後完全結束（⌘Q）並重新開啟 App。"
        }
        return error.localizedDescription
    }
}

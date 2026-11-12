import CoreAudio
import Foundation
import Network
import RTCAudioDeviceShim
@preconcurrency import WebRTC

enum WebRTCSupport {
    static let defaultPort: UInt16 = 47_800
    static let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    /// Voice processing (AEC/AGC/NS/HPF) damages music; loopback probe showed these constraints take effect.
    static let music = RTCMediaConstraints(mandatoryConstraints: [
        "googEchoCancellation": "false", "googAutoGainControl": "false",
        "googNoiseSuppression": "false", "googHighpassFilter": "false",
    ], optionalConstraints: nil)

    static let sslOnce: Void = { RTCInitializeSSL() }()

    static func configuration() -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = [] // LAN only: host candidates, no STUN/TURN
        config.sdpSemantics = .unifiedPlan
        return config
    }

    /// Opus stereo is opt-in per SDP: `stereo=1` asks the remote to send stereo, `sprop-stereo=1` says we send it.
    static func preferStereoOpus(_ description: RTCSessionDescription) -> RTCSessionDescription {
        var lines = description.sdp.components(separatedBy: "\r\n")
        guard let rtpmap = lines.first(where: { $0.hasPrefix("a=rtpmap:") && $0.contains(" opus/48000/2") }),
              let pt = rtpmap.dropFirst("a=rtpmap:".count).split(separator: " ").first,
              let i = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(pt) ") })
        else { return description }
        lines[i] += ";stereo=1;sprop-stereo=1;maxaveragebitrate=160000"
        return RTCSessionDescription(type: description.type, sdp: lines.joined(separator: "\r\n"))
    }

    static func localIPv4Addresses() -> [String] {
        localIPv4Interfaces().map { "\($0.name): \($0.address)" }
    }

    static func localIPv4Interfaces() -> [(name: String, address: String)] {
        var result: [(name: String, address: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append((String(cString: ifa.ifa_name),
                               String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
            }
        }
        return result
    }
}

struct RTPStats: Sendable {
    var bytes = 0.0
    var packets = 0.0
    var packetsLost = 0.0
    var concealedSamples = 0.0
    var totalSamples = 0.0
    var audioLevel = 0.0
    var jitterBufferMs = 0.0
    var codec = "—"

    static func read(_ pc: RTCPeerConnection, inbound: Bool) async -> RTPStats {
        await withCheckedContinuation { continuation in
            pc.statistics { report in
                var s = RTPStats()
                let rtpType = inbound ? "inbound-rtp" : "outbound-rtp"
                for stat in report.statistics.values {
                    let v = stat.values
                    func num(_ key: String) -> Double { (v[key] as? NSNumber)?.doubleValue ?? 0 }
                    if stat.type == rtpType, (v["kind"] as? String) == "audio" {
                        s.bytes += num(inbound ? "bytesReceived" : "bytesSent")
                        s.packets += num(inbound ? "packetsReceived" : "packetsSent")
                        s.packetsLost += num("packetsLost")
                        s.concealedSamples += num("concealedSamples")
                        s.totalSamples += num("totalSamplesReceived")
                        s.audioLevel = max(s.audioLevel, num("audioLevel"))
                        let emitted = num("jitterBufferEmittedCount")
                        if emitted > 0 { s.jitterBufferMs = num("jitterBufferDelay") / emitted * 1000 }
                    } else if stat.type == "codec", let mime = v["mimeType"] as? String, mime.hasPrefix("audio/") {
                        s.codec = "\(mime) \(Int(num("channels"))) ch"
                    }
                }
                continuation.resume(returning: s)
            }
        }
    }
}

final class PeerObserver: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    var onGatheringComplete: (@Sendable () -> Void)?
    var onIceState: (@Sendable (RTCIceConnectionState) -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { onGatheringComplete?() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onIceState?(newState)
    }
}

extension RTCIceConnectionState {
    var label: String {
        switch self {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        case .count: "count"
        @unknown default: "unknown"
        }
    }
}


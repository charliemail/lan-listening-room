import Foundation
import Network

struct SignalMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case offer, answer }
    let kind: Kind
    let sdp: String
}

/// Phase 0 experiment signaling: one JSON object per line over TCP.
/// ponytail: plaintext and unauthenticated on purpose — Phase 1 replaces it with the coordinator's
/// TLS + fingerprint/PIN pairing. Do not ship this path.
final class SignalingLink: @unchecked Sendable {
    static let maxBufferedBytes = 256 * 1024

    var onMessage: (@Sendable (SignalMessage) -> Void)?
    var onClose: (@Sendable (Error?) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "lanlisten.signaling")
    private var buffer = Data()
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ message: SignalMessage) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let message = try? JSONDecoder().decode(SignalMessage.self, from: line) {
                        onMessage?(message)
                    }
                }
                if buffer.count > Self.maxBufferedBytes {
                    connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive()
        }
    }

    /// Always invoked on `queue` (state handler and send completions), so `closed` needs no lock.
    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
    }
}

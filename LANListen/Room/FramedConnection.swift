import Foundation
import Network
import RoomCore

/// One TCP connection speaking RoomCore frames. Runs on the main queue so the room state has a
/// single writer (the main actor) without extra locking; traffic is a few small messages per second.
@MainActor
final class FramedConnection {
    var onFrame: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let connection: NWConnection
    private var decoder = FrameCodec.Decoder()
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    var remoteHost: String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let error), .waiting(let error): self?.finish(error)
                case .cancelled: self?.finish(nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func send<T: Encodable>(_ message: T) {
        guard !closed, let data = try? FrameCodec.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.finish(error) }
        })
    }

    /// For final messages (kicked, roomClosed, errors): cancel only after the bytes are handed off,
    /// otherwise the peer may never learn why it was dropped.
    func sendAndClose<T: Encodable>(_ message: T) {
        guard !closed, let data = try? FrameCodec.encode(message) else { close(); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: RoomProtocol.maxFrameBytes) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data {
                    do {
                        for frame in try self.decoder.push(data) { self.onFrame?(frame) }
                    } catch {
                        self.finish(error) // bad length: no resync, drop the peer
                        return
                    }
                }
                if isComplete || error != nil {
                    self.finish(error)
                    return
                }
                self.receive()
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
    }
}

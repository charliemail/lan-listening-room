import Foundation

/// 4-byte big-endian length prefix + JSON payload. TCP has no message boundaries, so the
/// decoder buffers partial frames and may yield several frames from one read.
public enum FrameCodec {
    public enum Failure: Error, Equatable {
        case emptyFrame
        case frameTooLarge(Int)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= RoomProtocol.maxFrameBytes else { throw Failure.frameTooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    public struct Decoder {
        private var buffer = Data()
        public init() {}

        /// Appends bytes and returns every complete payload. Throws on a length the peer must not send;
        /// the caller then drops the connection instead of trying to resync.
        public mutating func push(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var frames: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard length > 0 else { throw Failure.emptyFrame }
                guard length <= RoomProtocol.maxFrameBytes else { throw Failure.frameTooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                frames.append(Data(buffer.dropFirst(4).prefix(length)))
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return frames
        }
    }
}

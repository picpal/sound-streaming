import Foundation

public enum FrameType: UInt8 { case audio = 0x01, marker = 0x02 }
public enum MarkerCause: String, Codable { case command, natural, encoder }
public struct Marker: Codable, Equatable {
    public let seq: UInt64; public let trackId: String; public let cause: MarkerCause
    public init(seq: UInt64, trackId: String, cause: MarkerCause) {
        self.seq = seq; self.trackId = trackId; self.cause = cause
    }
}

public enum Envelope {
    public static func encode(type: FrameType, payload: Data) -> Data {
        precondition(payload.count <= 0xFFFF)
        var d = Data(capacity: payload.count + 3)
        d.append(type.rawValue)
        d.append(UInt8(payload.count >> 8)); d.append(UInt8(payload.count & 0xFF))
        d.append(payload)
        return d
    }
    public static func encodeMarker(_ m: Marker) -> Data {
        encode(type: .marker, payload: try! JSONEncoder().encode(m))
    }
}

public final class EnvelopeParser {
    private var buf = Data()
    public var onAudio: ((Data) -> Void)?
    public var onMarker: ((Marker) -> Void)?
    public init() {}
    public func feed(_ data: Data) {
        buf.append(data)
        while buf.count >= 3 {
            let type = buf[buf.startIndex]
            let len = Int(buf[buf.startIndex + 1]) << 8 | Int(buf[buf.startIndex + 2])
            guard buf.count >= 3 + len else { return }
            let payload = buf.subdata(in: buf.startIndex + 3 ..< buf.startIndex + 3 + len)
            buf.removeFirst(3 + len)
            switch type {
            case FrameType.audio.rawValue: onAudio?(payload)
            case FrameType.marker.rawValue:
                if let m = try? JSONDecoder().decode(Marker.self, from: payload) { onMarker?(m) }
            default: break  // PoC: TLS 위 신뢰 스트림이므로 resync 없이 무시
            }
        }
    }
    public func reset() { buf.removeAll() }
}

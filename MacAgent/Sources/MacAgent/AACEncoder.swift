import AVFoundation
import YoutumuKit

final class AACEncoder {
    private let converter: AVAudioConverter
    private let aacFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat) {
        var desc = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let f = AVAudioFormat(streamDescription: &desc),
              let c = AVAudioConverter(from: inputFormat, to: f) else { return nil }
        c.bitRate = 96_000
        aacFormat = f; converter = c
    }

    /// PCM 버퍼 하나를 ADTS AAC 프레임들로 인코딩
    func encode(_ pcm: AVAudioPCMBuffer) -> [Data] {
        var out: [Data] = []
        var fed = false
        while true {
            let comp = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 8, maximumPacketSize: 1536)
            var err: NSError?
            let st = converter.convert(to: comp, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return pcm
            }
            guard st != .error, comp.packetCount > 0 else { break }
            for i in 0 ..< Int(comp.packetCount) {
                let d = comp.packetDescriptions![i]
                let pkt = Data(bytes: comp.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
                out.append(adtsHeader(payloadLength: pkt.count) + pkt)
            }
            if st != .haveData { break }
        }
        return out
    }
}

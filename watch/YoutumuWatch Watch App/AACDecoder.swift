import AVFAudio

final class AACDecoder {
    let outFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var converter: AVAudioConverter?

    func decode(adtsFrame: Data) -> AVAudioPCMBuffer? {
        let payload = Data(adtsFrame.dropFirst(7))          // ADTS 7바이트 헤더 제거 (no-CRC 고정, Task 2)
        if converter == nil {
            var desc = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            let inFmt = AVAudioFormat(streamDescription: &desc)!
            converter = AVAudioConverter(from: inFmt, to: outFormat)
        }
        guard let conv = converter else { return nil }
        let inBuf = AVAudioCompressedBuffer(format: conv.inputFormat, packetCapacity: 1,
                                            maximumPacketSize: max(payload.count, 1))
        payload.withUnsafeBytes { raw in
            inBuf.data.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
        }
        inBuf.byteLength = UInt32(payload.count)
        inBuf.packetCount = 1
        inBuf.packetDescriptions![0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1024) else { return nil }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        return out.frameLength > 0 ? out : nil
    }

    func reset() { converter?.reset() }
}

import Foundation

/// AAC-LC, 48kHz(index 3), stereo 고정
public func adtsHeader(payloadLength: Int) -> Data {
    let len = payloadLength + 7
    var h = [UInt8](repeating: 0, count: 7)
    h[0] = 0xFF
    h[1] = 0xF1                                    // MPEG-4, no CRC
    h[2] = UInt8((0b01 << 6) | (3 << 2))           // profile AAC-LC(2)-1=1, sr index 3, ch 상위비트 0
    h[3] = UInt8((2 << 6) | ((len >> 11) & 0x03))  // channels 2
    h[4] = UInt8((len >> 3) & 0xFF)
    h[5] = UInt8(((len & 0x07) << 5) | 0x1F)
    h[6] = 0xFC
    return Data(h)
}

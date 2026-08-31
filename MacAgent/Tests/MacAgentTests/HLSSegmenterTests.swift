import XCTest
import AVFoundation
@testable import MacAgentCore

final class HLSSegmenterTests: XCTestCase {
    /// 48kHz 스테레오 float PCM CMSampleBuffer (frames 프레임, pts초 시작)
    private func pcmSample(frames: Int, pts: Double) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fmt)
        let byteCount = frames * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: byteCount, flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: fmt!,
            sampleCount: frames, presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sb)
        return sb!
    }

    /// 4초 분량 투입 → init + 미디어 세그먼트 ≥3, 플레이리스트 형식 검증
    func testProducesSegmentsAndPlaylist() {
        let seg = HLSSegmenter()
        let exp = expectation(description: "segments")
        exp.expectedFulfillmentCount = 3
        exp.assertForOverFulfill = false
        seg.onSegment = { exp.fulfill() }
        // 0.1초(4800프레임) 단위로 4초 투입 — 실시간 아님, writer는 PTS 기준으로 세그먼트를 자른다
        for i in 0..<40 { seg.append(pcmSample(frames: 4_800, pts: Double(i) * 0.1)) }
        wait(for: [exp], timeout: 10)

        XCTAssertNotNil(seg.initSegment())
        let pl = try! XCTUnwrap(seg.playlist())
        XCTAssertTrue(pl.contains("#EXT-X-VERSION:7"))
        XCTAssertTrue(pl.contains("#EXT-X-TARGETDURATION:1"))
        XCTAssertTrue(pl.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(pl.contains("#EXT-X-START:TIME-OFFSET=-2.0,PRECISE=YES"))
        XCTAssertTrue(pl.contains("seg0.m4s"))
        XCTAssertFalse(pl.contains("#EXT-X-ENDLIST"))       // 라이브
        XCTAssertNotNil(seg.segment(seq: 0))
    }

    /// 윈도우(8개) 초과 시 오래된 세그먼트 퇴출 + MEDIA-SEQUENCE 전진
    func testWindowEviction() {
        let seg = HLSSegmenter()
        let exp = expectation(description: "many segments")
        exp.expectedFulfillmentCount = 11
        exp.assertForOverFulfill = false
        seg.onSegment = { exp.fulfill() }
        for i in 0..<130 { seg.append(pcmSample(frames: 4_800, pts: Double(i) * 0.1)) }   // 13초
        wait(for: [exp], timeout: 15)

        XCTAssertNil(seg.segment(seq: 0))                    // 퇴출됨
        let pl = try! XCTUnwrap(seg.playlist())
        let seqLine = pl.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }!
        let firstSeq = UInt64(seqLine.split(separator: ":")[1])!
        XCTAssertGreaterThan(firstSeq, 0)
        XCTAssertNotNil(seg.segment(seq: firstSeq))
    }
}

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

    /// stop() 직후 재시작(새 PTS epoch, 0부터)해도 이전 writer의 지연 콜백과 충돌하지 않고
    /// 안전하게 다시 플레이리스트가 나와야 한다. 또한 #EXT-X-MEDIA-SEQUENCE는 세대가 바뀌어도
    /// 절대 감소하면 안 되고(감소하면 AVPlayer가 깨진 피드로 보고 자동 복구를 포기한다),
    /// 재시작 경계에는 #EXT-X-DISCONTINUITY가 정확히 한 번, 새 epoch의 첫 세그먼트 바로 앞에 있어야 한다.
    /// writer lifecycle thread-safety + HLS 시퀀스 단조성 회귀 테스트.
    func testStopThenRestartMonotonicSequenceWithDiscontinuity() {
        let seg = HLSSegmenter()
        let exp1 = expectation(description: "first epoch segments")
        exp1.expectedFulfillmentCount = 2
        exp1.assertForOverFulfill = false
        seg.onSegment = { exp1.fulfill() }
        for i in 0..<20 { seg.append(pcmSample(frames: 4_800, pts: Double(i) * 0.1)) }   // 2초
        wait(for: [exp1], timeout: 10)
        XCTAssertNotNil(seg.initSegment())

        // 첫 epoch 종료 시점의 마지막 seq를 기록해둔다 — 재시작 후 시퀀스가 이보다 커야(단조 증가) 한다.
        let pl1 = try! XCTUnwrap(seg.playlist())
        XCTAssertFalse(pl1.contains("#EXT-X-DISCONTINUITY"))   // 첫 epoch에는 불연속이 없어야 함
        let seg0Lines = pl1.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
        let lastSeqEpoch1 = seg0Lines.compactMap { line -> UInt64? in
            let s = line.dropFirst(3).dropLast(4)   // "seg" 접두, ".m4s" 접미 제거
            return UInt64(s)
        }.max()!

        seg.stop()
        XCTAssertNil(seg.initSegment())
        XCTAssertNil(seg.playlist())

        let exp2 = expectation(description: "second epoch segments")
        exp2.expectedFulfillmentCount = 2
        exp2.assertForOverFulfill = false
        seg.onSegment = { exp2.fulfill() }
        for i in 0..<20 { seg.append(pcmSample(frames: 4_800, pts: Double(i) * 0.1)) }   // 새 epoch, pts 0부터 재시작
        wait(for: [exp2], timeout: 10)

        XCTAssertNotNil(seg.initSegment())
        let pl2 = try! XCTUnwrap(seg.playlist())
        let lines2 = pl2.split(separator: "\n").map(String.init)

        // MEDIA-SEQUENCE 헤더도 이전 epoch의 마지막 seq보다 커야 한다(단조 증가, 절대 감소 금지).
        let seqLine = lines2.first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }!
        let headerFirstSeq = UInt64(seqLine.split(separator: ":")[1])!
        XCTAssertGreaterThan(headerFirstSeq, lastSeqEpoch1)

        // #EXT-X-DISCONTINUITY가 정확히 한 번, 새 epoch 첫 세그먼트의 EXTINF 바로 앞에 있어야 한다.
        let discontinuityCount = lines2.filter { $0 == "#EXT-X-DISCONTINUITY" }.count
        XCTAssertEqual(discontinuityCount, 1)
        let dIdx = try! XCTUnwrap(lines2.firstIndex(of: "#EXT-X-DISCONTINUITY"))
        XCTAssertTrue(lines2[dIdx + 1].hasPrefix("#EXTINF:"))
        let segLine = lines2[dIdx + 2]
        XCTAssertTrue(segLine.hasPrefix("seg") && segLine.hasSuffix(".m4s"))
        let newEpochFirstSeq = UInt64(segLine.dropFirst(3).dropLast(4))!
        XCTAssertGreaterThan(newEpochFirstSeq, lastSeqEpoch1)   // 새 epoch 첫 세그먼트도 단조 증가 구간에 있음
    }
}

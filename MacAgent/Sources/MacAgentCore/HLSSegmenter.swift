import AVFoundation
import Foundation

/// SCK 오디오 CMSampleBuffer(PCM) → fMP4 HLS 라이브 세그먼트 (메모리 서빙).
/// AVAssetWriter(.mpeg4AppleHLS)가 AAC 인코딩과 세그먼트 분할을 담당한다 (지연 목표: Global Constraints).
public final class HLSSegmenter: NSObject, AVAssetWriterDelegate {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var initData: Data?
    private var segments: [(seq: UInt64, data: Data, duration: Double)] = []
    private var nextSeq: UInt64 = 0
    static let window = 8                                    // 라이브 윈도우 (Global Constraints)
    public var onSegment: (() -> Void)?

    /// writer 생성은 첫 샘플에서 — sourceFormatHint와 initialSegmentStartTime에 실제 값이 필요
    public func append(_ sb: CMSampleBuffer) {
        if writer == nil { startWriter(firstSample: sb) }
        guard let input, input.isReadyForMoreMediaData else { return }   // 실시간 인코딩이 밀리면 드랍 (라이브)
        input.append(sb)
    }

    private func startWriter(firstSample: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(firstSample) else { return }
        let w = try! AVAssetWriter(contentType: .mpeg4Movie)
        w.outputFileTypeProfile = .mpeg4AppleHLS
        w.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        w.initialSegmentStartTime = CMSampleBufferGetPresentationTimeStamp(firstSample)
        w.delegate = self
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: desc)
        inp.expectsMediaDataInRealTime = true
        w.add(inp)
        w.startWriting()
        w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(firstSample))
        writer = w; input = inp
    }

    public func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                            segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock()
        switch segmentType {
        case .initialization:
            initData = segmentData
        case .separable:
            let dur = segmentReport?.trackReports.first?.duration.seconds ?? 1.0
            segments.append((nextSeq, segmentData, dur))
            nextSeq += 1
            if segments.count > Self.window { segments.removeFirst() }
        @unknown default: break
        }
        lock.unlock()
        onSegment?()
    }

    public func playlist() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard initData != nil, let first = segments.first else { return nil }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:1",
            "#EXT-X-MEDIA-SEQUENCE:\(first.seq)",
            "#EXT-X-START:TIME-OFFSET=-2.0,PRECISE=YES",     // 라이브 엣지 -2초에서 시작 (지연 목표)
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for s in segments {
            lines.append(String(format: "#EXTINF:%.5f,", s.duration))
            lines.append("seg\(s.seq).m4s")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func initSegment() -> Data? { lock.lock(); defer { lock.unlock() }; return initData }
    public func segment(seq: UInt64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return segments.first { $0.seq == seq }?.data
    }
    public func stop() {
        input?.markAsFinished()
        writer?.finishWriting {}
        lock.lock(); writer = nil; input = nil; initData = nil; segments = []; nextSeq = 0; lock.unlock()
    }
}

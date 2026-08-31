import AVFoundation
import Foundation

/// SCK 오디오 CMSampleBuffer(PCM) → fMP4 HLS 라이브 세그먼트 (메모리 서빙).
/// AVAssetWriter(.mpeg4AppleHLS)가 AAC 인코딩과 세그먼트 분할을 담당한다 (지연 목표: Global Constraints).
public final class HLSSegmenter: NSObject, AVAssetWriterDelegate {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var initData: Data?
    private var segments: [(seq: UInt64, data: Data, duration: Double, discontinuityBefore: Bool)] = []
    private var nextSeq: UInt64 = 0
    /// stop() 이후 재시작된 writer의 첫 세그먼트에 #EXT-X-DISCONTINUITY를 붙이기 위한 1회성 플래그.
    private var pendingDiscontinuity = false
    static let window = 8                                    // 라이브 윈도우 (Global Constraints)
    public var onSegment: (() -> Void)?

    /// writer 생성은 첫 샘플에서 — sourceFormatHint와 initialSegmentStartTime에 실제 값이 필요
    /// writer/input 필드는 append(캡처 스레드)와 stop(제어 스레드)이 동시에 건드릴 수 있으므로
    /// 모든 읽기/쓰기를 lock 아래서 수행하고, append 로 넘길 로컬 참조만 lock 밖으로 꺼낸다.
    public func append(_ sb: CMSampleBuffer) {
        lock.lock()
        let needsWriter = (writer == nil)
        lock.unlock()
        if needsWriter { startWriter(firstSample: sb) }

        // readiness 체크와 append를 lock을 쥔 채로 한 번에 끝낸다. stop()도 input을 nil로 만드는 것과
        // markAsFinished 호출을 같은 lock으로 분리해두었으므로(reset은 lock 안, markAsFinished는 lock 밖),
        // 여기서 lock을 놓지 않으면 markAsFinished가 진행 중인 append와 절대 겹칠 수 없다 — 겹치면 크래시.
        // delegate의 didOutputSegmentData는 writer 내부 큐에서 비동기로 전달되므로 여기서 lock을 쥐고 있어도
        // 같은 스레드에서 재진입하며 데드락이 나는 경로는 없다.
        lock.lock()
        defer { lock.unlock() }
        guard let inp = input, inp.isReadyForMoreMediaData else { return }   // 실시간 인코딩이 밀리면 드랍 (라이브)
        inp.append(sb)
    }

    private func startWriter(firstSample: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(firstSample) else { return }
        guard let w = try? AVAssetWriter(contentType: .mpeg4Movie) else { return }   // 실패해도 장시간 실행 중인 에이전트를 크래시시키지 않는다
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
        lock.lock()
        if writer == nil { writer = w; input = inp }   // 동시 진입한 다른 스레드가 이미 만들었다면 이걸 버린다
        lock.unlock()
    }

    public func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                            segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock()
        // stop() 이후 지연 도착한 콜백이거나, 새 writer가 이미 시작된 뒤 도착한 이전 writer의 콜백이면 버린다.
        guard writer === self.writer else { lock.unlock(); return }
        switch segmentType {
        case .initialization:
            // 세대가 바뀌어도 오디오 인코딩 설정(48kHz AAC 스테레오 128k)은 항상 동일하므로
            // init.mp4 URI를 버전별로 나눌 필요가 없다 — 캐시된 init 세그먼트가 계속 디코딩 가능하다.
            initData = segmentData
        case .separable:
            let dur = segmentReport?.trackReports.first?.duration.seconds ?? 1.0
            let isDiscontinuity = pendingDiscontinuity
            if isDiscontinuity { pendingDiscontinuity = false }   // 새 writer의 첫 세그먼트에만 표시
            segments.append((nextSeq, segmentData, dur, isDiscontinuity))
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
            if s.discontinuityBefore { lines.append("#EXT-X-DISCONTINUITY") }
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
        lock.lock()
        let oldInput = input
        let oldWriter = writer
        // nextSeq는 리셋하지 않는다 — writer 세대가 바뀌어도 #EXT-X-MEDIA-SEQUENCE는 단조 증가해야 한다.
        // (감소하면 AVPlayer가 깨진 피드로 간주해 자동 복구를 포기한다.) 최소 한 세그먼트가 나온 적
        // 있을 때만(nextSeq > 0) 재시작 표시가 의미 있으므로 그 경우에만 discontinuity를 예약한다.
        if nextSeq > 0 { pendingDiscontinuity = true }
        writer = nil; input = nil; initData = nil; segments = []
        lock.unlock()
        // writer/input을 먼저 nil로 리셋한 뒤(위) 캡처해둔 참조에 대해 종료를 요청한다.
        // 늦게 도착하는 didOutputSegmentData 콜백은 self.writer가 이미 바뀌었으므로 위의 identity 가드에서 버려진다.
        oldInput?.markAsFinished()
        oldWriter?.finishWriting {}
    }
}

import ScreenCaptureKit
import AVFoundation

enum CaptureError: Error { case chromeNotFound, noDisplay }

public final class ChromeAudioCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    public var onPCM: ((AVAudioPCMBuffer) -> Void)?
    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?   // HLS 세그먼터용 원본 탭

    public override init() {}

    public func start() async throws {
        let content = try await SCShareableContent.current
        // Chrome 인스턴스는 복수일 수 있다 (개인 + 전용 프로필 --user-data-dir, spec §11) — 전부 포함해야 전용 인스턴스 오디오가 잡힌다
        let apps = content.applications.filter { $0.bundleIdentifier == "com.google.Chrome" }
        guard !apps.isEmpty else { throw CaptureError.chromeNotFound }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2                       // 영상은 버림
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "cap.audio"))
        try await s.startCapture()
        stream = s
    }

    public func stop() async { try? await stream?.stopCapture(); stream = nil }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let fmt = AVAudioFormat(streamDescription: asbd) else { return }
        onSampleBuffer?(sb)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                     into: buf.mutableAudioBufferList)
        onPCM?(buf)
    }
}

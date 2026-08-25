import ScreenCaptureKit
import AVFoundation

enum CaptureError: Error { case chromeNotFound, noDisplay }

final class ChromeAudioCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    var onPCM: ((AVAudioPCMBuffer) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let app = content.applications.first(where: { $0.bundleIdentifier == "com.google.Chrome" })
        else { throw CaptureError.chromeNotFound }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
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

    func stop() async { try? await stream?.stopCapture(); stream = nil }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let fmt = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                     into: buf.mutableAudioBufferList)
        onPCM?(buf)
    }
}

import Foundation
import AVFoundation

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "capture-wav":
    let seconds = args.count > 2 ? Int(args[2]) ?? 10 : 10
    let sem = DispatchSemaphore(value: 0)
    Task {
        let cap = ChromeAudioCapture()
        var file: AVAudioFile?
        cap.onPCM = { pcm in
            if file == nil {
                file = try? AVAudioFile(forWriting: URL(fileURLWithPath: "/tmp/capture.wav"),
                                        settings: pcm.format.settings)
            }
            try? file?.write(from: pcm)
        }
        try await cap.start()
        print("capturing \(seconds)s... (Chrome에서 소리 재생 중이어야 함)")
        try await Task.sleep(for: .seconds(seconds))
        await cap.stop()
        sem.signal()
    }
    sem.wait()
    print("saved /tmp/capture.wav")
case "record-aac":
    let seconds = args.count > 2 ? Int(args[2]) ?? 10 : 10
    let sem = DispatchSemaphore(value: 0)
    Task {
        let cap = ChromeAudioCapture()
        var enc: AACEncoder?
        FileManager.default.createFile(atPath: "/tmp/capture.aac", contents: nil)
        let fh = FileHandle(forWritingAtPath: "/tmp/capture.aac")!
        cap.onPCM = { pcm in
            if enc == nil { enc = AACEncoder(inputFormat: pcm.format) }
            for frame in enc?.encode(pcm) ?? [] { fh.write(frame) }
        }
        try await cap.start()
        try await Task.sleep(for: .seconds(seconds))
        await cap.stop(); try? fh.close(); sem.signal()
    }
    sem.wait()
    print("saved /tmp/capture.aac")
default:
    print("usage: MacAgent capture-wav <sec> | record-aac <sec> | serve | enroll <code>")
    exit(1)
}

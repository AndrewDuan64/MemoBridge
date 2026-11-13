import AVFoundation
import Foundation

/// Standalone macOS test using synthetic data, without recording or external dependencies.
@main
struct AudioConverterTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoBridgeAudioTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.wav")
        let destination = directory.appendingPathComponent("result.wav")
        try writeSineWave(to: source)
        try AudioConverter.convertToWAV(source: source, destination: destination)
        try checkOutput(at: destination)
        print("AudioConverter: 44.1 kHz stereo → 16 kHz mono, 16-bit, 1 s, non-silent: passed")
    }

    private static func writeSineWave(to url: URL) throws {
        let sampleRate = 44_100.0
        let frames: AVAudioFrameCount = 44_100
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw Failure("Unable to create the test audio buffer")
        }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 0.5)
            channels[0][frame] = value
            channels[1][frame] = value
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private static func checkOutput(at url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.fileFormat.sampleRate == 16_000,
              file.fileFormat.channelCount == 1,
              file.fileFormat.streamDescription.pointee.mBitsPerChannel == 16,
              file.length == 16_000 else {
            throw Failure("Unexpected output format or duration: \(file.fileFormat), \(file.length) frames")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000) else {
            throw Failure("Unable to read the output buffer")
        }
        try file.read(into: buffer, frameCount: 16_000)
        guard buffer.frameLength == 16_000, let channel = buffer.floatChannelData?[0] else {
            throw Failure("The output contains fewer frames than expected")
        }
        let peak = (0..<Int(buffer.frameLength)).map { abs(channel[$0]) }.max() ?? 0
        guard peak > 0.3 else { throw Failure("The output audio is silent or unexpectedly quiet") }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

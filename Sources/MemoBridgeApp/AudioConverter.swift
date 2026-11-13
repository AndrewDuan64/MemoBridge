import AVFoundation
import Foundation

/// Converts a locally available recording to the PCM format used by whisper.cpp.
/// The caller invokes this off the main thread and owns the temporary destination.
enum AudioConverter {
    static func convertToWAV(source: URL, destination: URL, checkCancelled: () throws -> Void = {}) throws {
        try checkCancelled()
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioConversionError.message("Cannot read the recording. Ensure it is downloaded and its format is supported by macOS.")
        }
        let rate = input.processingFormat.sampleRate
        let channels = Int(input.processingFormat.channelCount)
        let inputFrames = input.length
        guard inputFrames > 0, rate.isFinite, rate > 0, channels > 0 else {
            throw AudioConversionError.message("The recording is empty or its audio format is unsupported.")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioConversionError.message("Unable to create a temporary audio file.")
        }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 4096),
              let outputSamples = outputBuffer.floatChannelData?[0] else {
            throw AudioConversionError.message("Unable to allocate an audio processing buffer.")
        }

        // A windowed-sinc low-pass resampler preserves duration and suppresses aliasing.
        // Coefficients are precomputed for fractional phases and the source is read in chunks,
        // so even long meetings do not need to be held in memory.
        let radius = 32
        let phases = 256
        let cutoff = min(1.0, 16_000.0 / rate) * 0.94
        func sinc(_ x: Double) -> Double {
            if abs(x) < 1e-12 { return 1 }
            return sin(.pi * x) / (.pi * x)
        }
        let coefficients: [[Float]] = (0..<phases).map { phase in
            let fraction = Double(phase) / Double(phases)
            let raw = (-radius + 1...radius).map { tap -> Double in
                let offset = Double(tap) - fraction
                return cutoff * sinc(cutoff * offset) * sinc(offset / Double(radius))
            }
            let sum = raw.reduce(0, +)
            return raw.map { Float($0 / sum) }
        }
        var samples: [Float] = []
        var base: Int64 = 0
        var eof = false
        var readFrames: Int64 = 0
        var written: Int64 = 0
        let expectedDouble = (Double(inputFrames) * 16_000 / rate).rounded(.up)
        guard expectedDouble.isFinite, expectedDouble > 0, expectedDouble <= Double(Int64.max) else {
            throw AudioConversionError.message("The recording is too long.")
        }
        let expected = Int64(expectedDouble)
        var outputLength: AVAudioFrameCount = 0

        func readMore() throws {
            guard readFrames < inputFrames else { eof = true; return }
            let remaining = inputFrames - readFrames
            let count = AVAudioFrameCount(min(Int64(inputBuffer.frameCapacity), remaining))
            do { try input.read(into: inputBuffer, frameCount: count) }
            catch { throw AudioConversionError.message("Could not read the recording: \(error.localizedDescription)") }
            let length = Int(inputBuffer.frameLength)
            guard length > 0, let inputChannels = inputBuffer.floatChannelData else {
                throw AudioConversionError.message("The recording data is incomplete. No transcript was saved.")
            }
            readFrames += Int64(length)
            for frame in 0..<length {
                var sum: Float = 0
                for channel in 0..<channels { sum += inputChannels[channel][frame] }
                samples.append(sum / Float(channels))
            }
        }
        func flush() throws {
            guard outputLength > 0 else { return }
            outputBuffer.frameLength = outputLength
            do { try output.write(from: outputBuffer) }
            catch { throw AudioConversionError.message("Unable to save temporary audio: \(error.localizedDescription)") }
            outputLength = 0
        }

        while written < expected {
            if written % 1024 == 0 { try checkCancelled() }
            let position = Double(written) * rate / 16_000
            let center = Int64(position.rounded(.down))
            while !eof && base + Int64(samples.count) <= center + Int64(radius) {
                try readMore()
            }
            let fraction = position - Double(center)
            let phase = min(phases - 1, Int(fraction * Double(phases)))
            let weights = coefficients[phase]
            var value: Float = 0
            for index in 0..<(radius * 2) {
                let sourceIndex = center + Int64(index - radius + 1)
                let offset = sourceIndex - base
                if offset >= 0 && offset < Int64(samples.count) {
                    value += samples[Int(offset)] * weights[index]
                }
            }
            outputSamples[Int(outputLength)] = value
            outputLength += 1
            written += 1
            if outputLength == outputBuffer.frameCapacity { try flush() }
            let discard = center - Int64(radius) - base
            if discard >= 8192 {
                let count = min(Int(discard), samples.count)
                samples.removeFirst(count)
                base += Int64(count)
            }
        }
        try checkCancelled()
        try flush()
        guard written == expected else { throw AudioConversionError.message("Audio conversion was incomplete. Please try again.") }
    }
}

private enum AudioConversionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

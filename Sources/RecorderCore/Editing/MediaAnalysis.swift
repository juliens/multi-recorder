import AVFoundation
import Accelerate

/// Data used to draw tracks on the timeline.
public enum MediaAnalysis {
    /// Peak level (0...1) of an audio file, split into `buckets` equal parts.
    public static func waveform(url: URL, buckets: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = Int(file.length)
        guard buckets > 0, totalFrames > 0 else { return [] }

        let format = file.processingFormat
        let chunkSize: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else { return [] }

        var peaks = [Float](repeating: 0, count: buckets)
        let framesPerBucket = Double(totalFrames) / Double(buckets)
        var position = 0

        while position < totalFrames {
            try file.read(into: buffer, frameCount: chunkSize)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }

            for channel in 0..<Int(format.channelCount) {
                var offset = 0
                while offset < frames {
                    let bucket = min(buckets - 1, Int(Double(position + offset) / framesPerBucket))
                    let bucketEnd = Int((Double(bucket + 1) * framesPerBucket).rounded(.up))
                    let count = max(1, min(frames - offset, bucketEnd - position - offset))
                    var peak: Float = 0
                    vDSP_maxmgv(data[channel] + offset, 1, &peak, vDSP_Length(count))
                    peaks[bucket] = max(peaks[bucket], peak)
                    offset += count
                }
            }
            position += frames
        }
        return peaks.map { min($0, 1) }
    }

    /// Evenly spaced pictures of a video file, in time order.
    public static func thumbnails(url: URL, count: Int, maxHeight: CGFloat) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard count > 0, let duration = try? await asset.load(.duration), duration.seconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxHeight * 4, height: maxHeight)
        // Nearest key frame is enough for a strip of thumbnails and much faster.
        let tolerance = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let step = duration.seconds / Double(count)
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * step, preferredTimescale: 600) }

        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                images.append(image)
            }
        }
        return images
    }
}

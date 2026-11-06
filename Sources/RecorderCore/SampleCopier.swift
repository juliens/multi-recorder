import AVFoundation

/// Copies samples from sources (reader outputs or renderers) to writer inputs.
enum SampleCopier {
    struct Pair {
        /// Returns the next sample, or nil at the end. Called on one queue only.
        let next: () -> CMSampleBuffer?
        let input: AVAssetWriterInput

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
            next = { output.copyNextSampleBuffer() }
            self.input = input
        }

        init(input: AVAssetWriterInput, next: @escaping () -> CMSampleBuffer?) {
            self.next = next
            self.input = input
        }
    }

    /// Feeds every writer input in parallel so the writer can interleave the tracks.
    /// Returns when every source is empty or a write fails.
    static func copyAll(_ pairs: [Pair], onSample: (@Sendable (CMSampleBuffer) -> Void)? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (index, pair) in pairs.enumerated() {
                group.enter()
                let queue = DispatchQueue(label: "copy.\(index)")
                var finished = false
                pair.input.requestMediaDataWhenReady(on: queue) {
                    while !finished, pair.input.isReadyForMoreMediaData {
                        if let sample = pair.next(), pair.input.append(sample) {
                            onSample?(sample)
                            continue
                        }
                        finished = true
                        pair.input.markAsFinished()
                        group.leave()
                    }
                }
            }
            group.notify(queue: .global()) { continuation.resume() }
        }
    }
}

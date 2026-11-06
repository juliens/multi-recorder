import CoreMedia
import Foundation

/// Pure helpers used to cut every track at the same start and end instants.
public enum Timing {
    /// Returns the frames of an audio buffer that fall inside [start, end).
    /// `bufferStart` is the timestamp of the first frame of the buffer.
    public static func frameRange(
        bufferStart: CMTime,
        frameCount: Int,
        sampleRate: Double,
        start: CMTime,
        end: CMTime?
    ) -> Range<Int> {
        guard frameCount > 0, sampleRate > 0 else { return 0..<0 }

        let lowOffset = (start - bufferStart).seconds * sampleRate
        let low = clamp(Int(lowOffset.rounded()), 0, frameCount)

        var high = frameCount
        if let end {
            let highOffset = (end - bufferStart).seconds * sampleRate
            high = clamp(Int(highOffset.rounded()), 0, frameCount)
        }

        return high > low ? low..<high : low..<low
    }

    /// Time just after the last frame of a buffer.
    public static func bufferEnd(bufferStart: CMTime, frameCount: Int, sampleRate: Double) -> CMTime {
        bufferStart + CMTime(seconds: Double(frameCount) / sampleRate, preferredTimescale: 1_000_000_000)
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }
}

/// File and folder names used for a recording.
public enum FileNaming {
    public static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let parts = name.unicodeScalars.split { !allowed.contains($0) }
        let joined = parts.map { String(String.UnicodeScalarView($0)) }.joined(separator: "-")
        return joined.isEmpty ? "device" : joined
    }

    public static func sessionFolderName(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    public static func cameraFileName(index: Int, deviceName: String) -> String {
        "cam\(index)_\(sanitize(deviceName)).mov"
    }

    /// `channel` is 0-based; the file name is 1-based like the labels on audio interfaces.
    public static func audioFileName(channel: Int) -> String {
        String(format: "audio_ch%02d.wav", channel + 1)
    }

    public static let combinedFileName = "combined.mov"
    public static let manifestFileName = "session.json"

    public static let phonePrefix = "phone"

    /// The clip downloaded from a phone, and the sound taken out of it.
    public static func phoneFileNames(index: Int, phoneName: String) -> (video: String, audio: String) {
        let base = "\(phonePrefix)\(index)_\(sanitize(phoneName))"
        return ("\(base).mp4", "\(base).m4a")
    }
}

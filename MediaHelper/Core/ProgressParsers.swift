import Foundation

/// Turns the downloader's output lines into one smooth 0…1 number.
///
/// A video download fetches the picture and the sound separately (each counting 0 to
/// 100%), so the percentages are combined: with two streams, 50% of the second one is
/// 75% overall. The number never goes backwards.
struct DownloadProgressTracker {
    enum Stage: Equatable { case downloading, merging, converting, fixing }

    private(set) var expectedStreams = 1
    private(set) var streamsStarted = 0
    private(set) var fraction = 0.0
    private(set) var stage: Stage = .downloading

    /// Feeds one output line. Returns true when `fraction` or `stage` changed.
    @discardableResult
    mutating func handle(line: String) -> Bool {
        let before = (fraction, stage)
        if let n = Self.streamCount(in: line) { expectedStreams = n }
        if line.hasPrefix("[download] Destination:") { streamsStarted += 1 }
        else if line.hasPrefix("[download]"), let pct = YouTubeDownloader.lastPercent(in: line) {
            let index = Double(max(streamsStarted, 1) - 1)
            let overall = (index + min(max(pct, 0), 100) / 100) / Double(max(expectedStreams, 1))
            fraction = max(fraction, min(overall, 1))
        }
        if line.hasPrefix("[Merger]") { stage = .merging }
        else if line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[VideoConvertor]") { stage = .converting }
        else if line.hasPrefix("[Fixup") || line.hasPrefix("[VideoRemuxer]") { stage = .fixing }
        return before.0 != fraction || before.1 != stage
    }

    /// "[info] abc: Downloading 1 format(s): 137+140" → 2 (two streams are fetched and joined).
    static func streamCount(in line: String) -> Int? {
        guard line.contains("Downloading"), let r = line.range(of: "format(s):") else { return nil }
        let ids = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !ids.isEmpty else { return nil }
        return max(1, ids.split(separator: "+").count)
    }
}

/// Reads `ffmpeg -progress pipe:1` output.
enum FFmpegProgress {
    /// The position in the media, in seconds, if this line reports one.
    static func seconds(inLine line: String) -> Double? {
        let l = line.trimmingCharacters(in: .whitespaces)
        // out_time_us is microseconds. (out_time_ms is also microseconds despite its name.)
        for key in ["out_time_us=", "out_time_ms="] where l.hasPrefix(key) {
            let v = l.dropFirst(key.count)
            guard let n = Double(v), n >= 0 else { return nil }
            return n / 1_000_000
        }
        if l.hasPrefix("out_time=") {
            let parts = l.dropFirst("out_time=".count).split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        }
        return nil
    }

    static func isEnd(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces) == "progress=end" }

    /// 0…1 given the position and the total length; nil when the length is unknown.
    static func fraction(seconds: Double, duration: Double?) -> Double? {
        guard let d = duration, d > 0 else { return nil }
        return min(max(seconds / d, 0), 1)
    }
}

import Foundation

struct StreamInfo: Equatable {
    let type: String      // "video", "audio", ...
    let codec: String     // "h264", "aac", "mp3", ...
}

struct MediaInfo: Equatable {
    let streams: [StreamInfo]
    let duration: Double?
    let formatName: String?

    var videoCodec: String? { streams.first { $0.type == "video" && $0.codec != "mjpeg" && $0.codec != "png" }?.codec }
    var audioCodec: String? { streams.first { $0.type == "audio" }?.codec }
    var hasAudio: Bool { audioCodec != nil }
}

enum MediaProbe {
    static func probe(_ file: URL, token: CancelToken? = nil) async throws -> MediaInfo {
        guard let ffprobe = Tools.path(for: "ffprobe") else { throw HelperError.message("The converter isn't ready yet.") }
        let r = try await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", file.path], token: token)
        guard r.succeeded, let info = parse(json: Data(r.stdout.utf8)) else {
            throw HelperError.message("That file couldn't be read. It may be damaged, or it may not be a video.")
        }
        return info
    }

    static func parse(json: Data) -> MediaInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let streams = ((root["streams"] as? [[String: Any]]) ?? []).compactMap { s -> StreamInfo? in
            guard let t = s["codec_type"] as? String, let c = s["codec_name"] as? String else { return nil }
            return StreamInfo(type: t, codec: c)
        }
        let format = root["format"] as? [String: Any]
        let duration = (format?["duration"] as? String).flatMap(Double.init) ?? (format?["duration"] as? Double)
        guard !streams.isEmpty || format != nil else { return nil }
        return MediaInfo(streams: streams, duration: duration, formatName: format?["format_name"] as? String)
    }
}

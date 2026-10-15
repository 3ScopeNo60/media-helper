// Unit-style tests for Media Helper's pure logic. Built by tests/run-tests.sh together
// with MediaHelper/Core/*.swift (no Xcode project needed).
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO

var passed = 0, failed = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name) \(detail())") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) { check(a == b, name, "got \(a), expected \(b)") }

// MARK: Filename sanitizing
eq(Naming.sanitize("Hello World"), "Hello World", "sanitize: plain title unchanged")
eq(Naming.sanitize("AC/DC - Back In Black"), "AC-DC - Back In Black", "sanitize: slash becomes dash")
eq(Naming.sanitize("Title: The Subtitle"), "Title - The Subtitle", "sanitize: colon becomes ' -'")
eq(Naming.sanitize("What? Why* \"Quote\" <b> |pipe|"), "What Why Quote b pipe", "sanitize: illegal characters dropped")
eq(Naming.sanitize("  spaced   out \n title\t "), "spaced out title", "sanitize: whitespace tidied")
eq(Naming.sanitize("...hidden"), "hidden", "sanitize: leading dots removed")
eq(Naming.sanitize("ends with dots..."), "ends with dots", "sanitize: trailing dots removed")
eq(Naming.sanitize(""), "Download", "sanitize: empty -> fallback")
eq(Naming.sanitize("???"), "Download", "sanitize: only illegal chars -> fallback")
eq(Naming.sanitize(".."), "Download", "sanitize: '..' -> fallback")
eq(Naming.sanitize("bell\u{07}char"), "bellchar", "sanitize: control characters dropped")
eq(Naming.sanitize("Café – Ünïcode 🎵 song"), "Café – Ünïcode 🎵 song", "sanitize: unicode and emoji preserved")
let long = String(repeating: "あ", count: 200)
let sl = Naming.sanitize(long)
check(sl.utf8.count <= 180 && !sl.isEmpty, "sanitize: long CJK title capped at 180 bytes", "bytes=\(sl.utf8.count)")
check(Naming.sanitize(String(repeating: "a", count: 300)).count <= 120, "sanitize: long title capped at 120 chars")

// MARK: No-overwrite naming
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mh-test-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    eq(Naming.uniqueURL(in: dir, baseName: "Song", ext: "mp3").lastPathComponent, "Song.mp3", "unique: free name used as is")
    FileManager.default.createFile(atPath: dir.appendingPathComponent("Song.mp3").path, contents: Data())
    eq(Naming.uniqueURL(in: dir, baseName: "Song", ext: "mp3").lastPathComponent, "Song 2.mp3", "unique: existing -> ' 2'")
    FileManager.default.createFile(atPath: dir.appendingPathComponent("Song 2.mp3").path, contents: Data())
    eq(Naming.uniqueURL(in: dir, baseName: "Song", ext: "mp3").lastPathComponent, "Song 3.mp3", "unique: ' 2' taken -> ' 3'")
    eq(Naming.uniqueURL(in: dir, baseName: "Song", ext: "mp4").lastPathComponent, "Song.mp4", "unique: other extension unaffected")
} catch { check(false, "unique: setup", "\(error)") }

// MARK: Slides -> images: file names
eq(SlideNaming.fileName(prefix: "", name: "Sunday_Slides", number: 1, total: 12, ext: "png"), "Sunday_Slides_01.png", "slides: example name from the screen")
eq(SlideNaming.fileName(prefix: "Easter_", name: "Talk", number: 3, total: 5, ext: "jpg"), "Easter_Talk_03.jpg", "slides: prefix goes in front")
eq(SlideNaming.fileName(prefix: "", name: "Talk", number: 7, total: 99, ext: "png"), "Talk_07.png", "slides: 99 slides still two digits")
eq(SlideNaming.fileName(prefix: "", name: "Talk", number: 7, total: 100, ext: "png"), "Talk_007.png", "slides: 100 slides -> three digits so they sort")
eq(SlideNaming.fileName(prefix: "", name: "Talk", number: 1, total: 1, ext: "png"), "Talk_01.png", "slides: a single slide is still _01")
eq(SlideNaming.fileName(prefix: "", name: "Talk", number: 1234, total: 1234, ext: "png"), "Talk_1234.png", "slides: four digits when needed")
eq(SlideNaming.fileName(prefix: "A/B: ", name: "x*y?", number: 2, total: 3, ext: "png"), "A-B - xy_02.png", "slides: unsafe characters cleaned in prefix and name")
eq(SlideNaming.fileName(prefix: "", name: "", number: 2, total: 3, ext: "png"), "Slides_02.png", "slides: empty name falls back")
let sortedNames = (1...120).map { SlideNaming.fileName(prefix: "", name: "T", number: $0, total: 120, ext: "png") }
check(sortedNames == sortedNames.sorted(), "slides: 120 names sort in slide order as plain text")
eq(SlideImageFormat.png.ext, "png", "slides: PNG extension"); eq(SlideImageFormat.jpeg.ext, "jpg", "slides: JPEG extension is .jpg")

// MARK: Slides -> images: sizes
func px(_ z: SlideSize, _ w: Double, _ h: Double) -> String { let r = z.pixelSize(forPage: CGSize(width: w, height: h)); return "\(r.width)x\(r.height)" }
eq(px(.fullHD, 960, 540), "1920x1080", "size: Full HD, 16:9 page")
eq(px(.fourK, 960, 540), "3840x2160", "size: 4K, 16:9 page")
eq(px(.original, 960, 540), "960x540", "size: original keeps the page's own size")
eq(px(.fullHD, 720, 540), "1920x1440", "size: Full HD keeps a 4:3 shape")
eq(px(.fourK, 540, 960), "3840x6827", "size: 4K portrait page is 3840 wide, shape kept")
eq(px(.original, 612, 792), "612x792", "size: US Letter original")
eq(px(.fullHD, 841.89, 595.28), "1920x1358", "size: A4 landscape at Full HD")
eq(px(.original, 20000, 10000), "16000x8000", "size: huge pages are capped at 16000 px")
eq(px(.fullHD, 0, 0), "1920x1920", "size: broken zero-size page can't crash")
check((1...50).allSatisfy { i in let r = SlideSize.fullHD.pixelSize(forPage: CGSize(width: 960, height: 400 + Double(i) * 7)); return abs(Double(r.width) / Double(r.height) - 960 / (400 + Double(i) * 7)) < 0.002 }, "size: shape is preserved for many page shapes")
eq(SlideSize.allCases.map(\.title), ["Full HD (1920 wide)", "4K (3840 wide)", "Original size"], "size: menu wording")

// MARK: Slides -> images: which program makes the PDF
let all = SlideRenderer.Installed(libreOffice: URL(fileURLWithPath: "/x/soffice"), powerPoint: URL(fileURLWithPath: "/x/PP.app"), keynote: URL(fileURLWithPath: "/x/KN.app"))
let noLO = SlideRenderer.Installed(libreOffice: nil, powerPoint: all.powerPoint, keynote: all.keynote)
let onlyKN = SlideRenderer.Installed(libreOffice: nil, powerPoint: nil, keynote: all.keynote)
let onlyLO = SlideRenderer.Installed(libreOffice: all.libreOffice, powerPoint: nil, keynote: nil)
let none = SlideRenderer.Installed(libreOffice: nil, powerPoint: nil, keynote: nil)
check(SlideRenderer.choose(forExtension: "pptx", installed: all) == .libreOffice, "renderer: pptx prefers LibreOffice")
check(SlideRenderer.choose(forExtension: "ppt", installed: all) == .libreOffice, "renderer: ppt prefers LibreOffice")
check(SlideRenderer.choose(forExtension: "pptx", installed: noLO) == .powerPoint, "renderer: no LibreOffice -> PowerPoint")
check(SlideRenderer.choose(forExtension: "PPTX", installed: noLO) == .powerPoint, "renderer: extension is case-insensitive")
check(SlideRenderer.choose(forExtension: "pptx", installed: onlyKN) == .keynote, "renderer: only Keynote -> Keynote")
check(SlideRenderer.choose(forExtension: "pptx", installed: onlyLO) == .libreOffice, "renderer: only LibreOffice -> LibreOffice")
check(SlideRenderer.choose(forExtension: "pptx", installed: none) == nil, "renderer: nothing installed -> none")
check(SlideRenderer.choose(forExtension: "key", installed: all) == .keynote, "renderer: .key always Keynote")
check(SlideRenderer.choose(forExtension: "key", installed: onlyLO) == nil, "renderer: .key without Keynote -> none")
check(SlideRenderer.choose(forExtension: "pptx", installed: all, forced: .keynote) == .keynote, "renderer: forced Keynote honoured")
check(SlideRenderer.choose(forExtension: "pptx", installed: onlyKN, forced: .powerPoint) == nil, "renderer: forced but missing -> none")
check(SlideRenderer.choose(forExtension: "key", installed: all, forced: .powerPoint) == nil, "renderer: .key can't be forced onto PowerPoint")
check(SlideRenderer.missingMessage(forExtension: "pptx").contains("Keynote") && SlideRenderer.missingMessage(forExtension: "pptx").contains("LibreOffice"), "renderer: missing-program message names the free options")
check(SlideConverter.isSupported(URL(fileURLWithPath: "/a/b.PPTX")) && SlideConverter.isSupported(URL(fileURLWithPath: "/a/b.key")) && SlideConverter.isSupported(URL(fileURLWithPath: "/a/b.pdf")) && SlideConverter.isSupported(URL(fileURLWithPath: "/a/b.ppt")), "slides: accepted file types")
check(!SlideConverter.isSupported(URL(fileURLWithPath: "/a/b.mp4")) && !SlideConverter.isSupported(URL(fileURLWithPath: "/a/b.docx")), "slides: other file types refused")
check(OfficeExporter.explain(stderr: "x (-1743)", appTitle: "Keynote").contains("Automation"), "office: 'not allowed' error explained")
check(!OfficeExporter.explain(stderr: "x (-1743)", appTitle: "Keynote").contains("-1743"), "office: no error codes shown to people")
check(OfficeExporter.libreOfficeArguments(input: URL(fileURLWithPath: "/in/a b.pptx"), outDir: URL(fileURLWithPath: "/out"), profileDir: URL(fileURLWithPath: "/p")).contains("--headless"), "office: LibreOffice runs headless")
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mh-test-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    eq(Naming.uniqueFolderURL(in: dir, baseName: "Deck").lastPathComponent, "Deck", "unique folder: free name used as is")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Deck"), withIntermediateDirectories: true)
    eq(Naming.uniqueFolderURL(in: dir, baseName: "Deck").lastPathComponent, "Deck 2", "unique folder: existing -> ' 2'")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Deck 2"), withIntermediateDirectories: true)
    eq(Naming.uniqueFolderURL(in: dir, baseName: "Deck").lastPathComponent, "Deck 3", "unique folder: ' 2' taken -> ' 3'")
    // A small real PDF: one landscape page and one portrait page, rendered at every size.
    let pdf = dir.appendingPathComponent("t.pdf")
    var box = CGRect(x: 0, y: 0, width: 400, height: 300)
    let c = CGContext(pdf as CFURL, mediaBox: &box, nil)!
    c.beginPDFPage(nil); c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 50, height: 50)); c.endPDFPage()
    var portrait = CGRect(x: 0, y: 0, width: 300, height: 400)
    c.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &portrait, count: MemoryLayout<CGRect>.size)] as CFDictionary); c.endPDFPage()
    c.closePDF()
    let out = dir.appendingPathComponent("o"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let n = try SlideConverter.renderPages(pdf: pdf, into: out, name: "T", options: .init(format: .jpeg, size: .original, prefix: "P_"), token: nil)
    eq(n, 2, "render: two pages -> two pictures")
    eq(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), ["P_T_01.jpg", "P_T_02.jpg"], "render: file names")
    let src = CGImageSourceCreateWithURL(out.appendingPathComponent("P_T_02.jpg") as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    eq("\(img.width)x\(img.height)", "300x400", "render: portrait page keeps its shape")
    let tok = CancelToken(); tok.cancel()
    do { _ = try SlideConverter.renderPages(pdf: pdf, into: out, name: "T", options: .init(), token: tok); check(false, "render: cancel") }
    catch { check((error as? HelperError) == .cancelled, "render: a cancelled job stops before drawing") }
    do { _ = try SlideConverter.renderPages(pdf: dir.appendingPathComponent("o"), into: out, name: "T", options: .init(), token: nil); check(false, "render: not a pdf") }
    catch { check((error as? HelperError)?.errorDescription?.contains("PDF") == true, "render: a file that isn't a PDF gives a plain message") }
} catch { check(false, "slides: setup", "\(error)") }

// MARK: Links
eq(YouTubeDownloader.normalizedLink("https://www.youtube.com/watch?v=jNQXAC9IVRw"), "https://www.youtube.com/watch?v=jNQXAC9IVRw", "link: full URL accepted")
eq(YouTubeDownloader.normalizedLink("youtu.be/jNQXAC9IVRw"), "https://youtu.be/jNQXAC9IVRw", "link: scheme added to youtu.be")
check(YouTubeDownloader.normalizedLink("hello world") == nil, "link: plain words rejected")
check(YouTubeDownloader.normalizedLink("") == nil, "link: empty rejected")
let parsed = YouTubeDownloader.parseLinks("https://youtu.be/a\n\n  https://youtu.be/b  \nnot a link\r\nyoutube.com/watch?v=c")
eq(parsed.links.count, 3, "links: three valid lines found"); eq(parsed.skipped, 1, "links: one skipped line counted")

// MARK: yt-dlp command line
let argsAudio = YouTubeDownloader.arguments(mode: .audio(.mp3), outputTemplate: "/t/media.%(ext)s", ffmpegLocation: "/tools", link: "https://x.test/v")
check(argsAudio.contains("--no-playlist"), "args: audio has --no-playlist")
check(argsAudio.joined(separator: " ").contains("-x --audio-format mp3 --audio-quality 0"), "args: audio is -x --audio-format mp3 --audio-quality 0")
check(argsAudio.joined(separator: " ").contains("--ffmpeg-location /tools"), "args: ffmpeg location passed")
eq(argsAudio.last!, "https://x.test/v", "args: link is last"); check(argsAudio[argsAudio.count - 2] == "--", "args: -- guards the link")
check(YouTubeDownloader.arguments(mode: .audio(.m4a), outputTemplate: "o", ffmpegLocation: nil, link: "l").joined(separator: " ").contains("--audio-format m4a"), "args: m4a option")
let argsVideo = YouTubeDownloader.arguments(mode: .video(.best), outputTemplate: "o", ffmpegLocation: nil, link: "l")
check(argsVideo.contains("--no-playlist"), "args: video has --no-playlist")
check(argsVideo.joined(separator: " ").contains("--merge-output-format mp4"), "args: video merges to mp4")
eq(YouTubeDownloader.VideoQuality.best.formatSelector, "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]/b", "format: best selector exact")
check(YouTubeDownloader.VideoQuality.p720.formatSelector.contains("height<=720"), "format: 720p selector")
check(YouTubeDownloader.VideoQuality.p480.formatSelector.contains("height<=480"), "format: 480p selector")
check(argsVideo.contains(YouTubeDownloader.VideoQuality.best.formatSelector), "args: video uses the selector")

// MARK: yt-dlp progress parsing
eq(YouTubeDownloader.lastPercent(in: "[download]  45.3% of 3.2MiB at 1MiB/s ETA 00:02"), 45.3, "ytdlp: percent with decimals")
eq(YouTubeDownloader.lastPercent(in: "[download] 100% of 3.2MiB in 00:03"), 100, "ytdlp: 100%")
check(YouTubeDownloader.lastPercent(in: "[youtube] abc: Downloading webpage") == nil, "ytdlp: no percent -> nil")
eq(YouTubeDownloader.lastPercent(in: "[download]  10.0% x\n[download]  20.5% x"), 20.5, "ytdlp: last of several")
eq(DownloadProgressTracker.streamCount(in: "[info] abc: Downloading 1 format(s): 137+140"), 2, "tracker: video+audio = 2 streams")
eq(DownloadProgressTracker.streamCount(in: "[info] abc: Downloading 1 format(s): 18"), 1, "tracker: single format = 1 stream")
var tr = DownloadProgressTracker()
tr.handle(line: "[info] abc: Downloading 1 format(s): 137+140")
tr.handle(line: "[download] Destination: /t/media.f137.mp4")
tr.handle(line: "[download]  50.0% of 10MiB at 1MiB/s")
eq(tr.fraction, 0.25, "tracker: 50% of first of two streams = 25%")
tr.handle(line: "[download] 100% of 10MiB in 00:10")
eq(tr.fraction, 0.5, "tracker: first stream done = 50%")
tr.handle(line: "[download] Destination: /t/media.f140.m4a")
tr.handle(line: "[download]  50.0% of 1MiB at 1MiB/s")
eq(tr.fraction, 0.75, "tracker: half of second stream = 75%")
tr.handle(line: "[download]  10.0% of 1MiB at 1MiB/s")
eq(tr.fraction, 0.75, "tracker: never goes backwards")
tr.handle(line: "[Merger] Merging formats into \"/t/media.mp4\"")
eq(tr.stage, .merging, "tracker: merger line -> merging stage")
var tr2 = DownloadProgressTracker()
tr2.handle(line: "[ExtractAudio] Destination: /t/media.mp3")
eq(tr2.stage, .converting, "tracker: ExtractAudio -> converting stage")

// MARK: ffmpeg progress parsing
eq(FFmpegProgress.seconds(inLine: "out_time_us=2500000"), 2.5, "ffmpeg: out_time_us -> seconds")
eq(FFmpegProgress.seconds(inLine: "out_time_ms=1500000"), 1.5, "ffmpeg: out_time_ms -> seconds")
eq(FFmpegProgress.seconds(inLine: "out_time=00:01:02.500000"), 62.5, "ffmpeg: out_time clock")
check(FFmpegProgress.seconds(inLine: "out_time_us=N/A") == nil, "ffmpeg: N/A ignored")
check(FFmpegProgress.seconds(inLine: "bitrate=128.0kbits/s") == nil, "ffmpeg: unrelated line ignored")
check(FFmpegProgress.seconds(inLine: "out_time_us=-9223372036854775807") == nil, "ffmpeg: negative ignored")
check(FFmpegProgress.isEnd("progress=end") && !FFmpegProgress.isEnd("progress=continue"), "ffmpeg: progress=end detected")
eq(FFmpegProgress.fraction(seconds: 2.5, duration: 5), 0.5, "ffmpeg: fraction 2.5/5")
eq(FFmpegProgress.fraction(seconds: 9, duration: 5), 1.0, "ffmpeg: fraction clamped to 1")
check(FFmpegProgress.fraction(seconds: 1, duration: nil) == nil && FFmpegProgress.fraction(seconds: 1, duration: 0) == nil, "ffmpeg: unknown duration -> nil")
let collected = LineCollector(onLine: nil); var lines: [String] = []
let lc = LineCollector(onLine: { lines.append($0) })
lc.feed(Data("out_time_us=1".utf8)); lc.feed(Data("000000\nprogress=con".utf8)); lc.feed(Data("tinue\n".utf8))
eq(lines, ["out_time_us=1000000", "progress=continue"], "lines: chunked output re-assembled into lines"); _ = collected

// MARK: ffprobe parsing / tool versions
let json = #"{"streams":[{"codec_type":"video","codec_name":"h264"},{"codec_type":"audio","codec_name":"aac"}],"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"19.058000"}}"#
let mi = MediaProbe.parse(json: Data(json.utf8))
eq(mi?.videoCodec, "h264", "probe: video codec"); eq(mi?.audioCodec, "aac", "probe: audio codec"); eq(mi?.duration, 19.058, "probe: duration")
check(MediaProbe.parse(json: Data("garbage".utf8)) == nil, "probe: garbage -> nil")
check(MediaProbe.parse(json: Data(#"{"streams":[{"codec_type":"video","codec_name":"h264"}],"format":{"duration":"5"}}"#.utf8))?.hasAudio == false, "probe: no audio stream detected")
eq(Tools.ffmpegVersion(fromBanner: "ffmpeg version 9.0.2-https://www.martin-riedl.de Copyright (c) 2000-2026\n"), "9.0.2", "version: ffmpeg banner parsed")
eq(MediaConverter.arguments(input: URL(fileURLWithPath: "/a.mp4"), output: URL(fileURLWithPath: "/b.mp3"), format: .mp3).joined(separator: " "),
   "-y -i /a.mp4 -vn -sn -dn -map 0:a:0 -map_metadata 0 -c:a libmp3lame -q:a 0 -id3v2_version 3 /b.mp3", "convert: mp3 arguments")
check(MediaConverter.arguments(input: URL(fileURLWithPath: "/a.mp4"), output: URL(fileURLWithPath: "/b.m4a"), format: .m4a).contains("aac"), "convert: m4a uses aac")
for e in ["mp4", "mov", "m4v", "mkv", "webm", "avi", "MP4", "MKV"] { check(MediaConverter.isSupportedVideo(URL(fileURLWithPath: "/x/clip.\(e)")), "convert: .\(e) accepted") }
check(!MediaConverter.isSupportedVideo(URL(fileURLWithPath: "/x/notes.pdf")), "convert: .pdf rejected")

// MARK: Error explanations
let bannerNoise = """
WARNING: [youtube] Falling back to generic n function search
 
Current version: 2025.01.01
ERROR: [youtube] abc: Video unavailable. This video is private
"""
eq(YouTubeDownloader.explain(bannerNoise), "That video is unavailable or private.", "explain: private video, banner noise ignored")
let e403 = YouTubeDownloader.explain("ERROR: unable to download video data: HTTP Error 403: Forbidden")
check(e403.contains(YouTubeDownloader.outdatedToolHint), "explain: 403 -> out-of-date hint", e403)
check(YouTubeDownloader.isOutdatedToolFailure(e403), "outdated: detected from explained message")
check(YouTubeDownloader.isOutdatedToolFailure("HTTP Error 403: Forbidden"), "outdated: detected from raw 403")
check(YouTubeDownloader.isOutdatedToolFailure("nsig extraction failed: Some formats may be missing"), "outdated: nsig")
check(YouTubeDownloader.isOutdatedToolFailure("[youtube] jNQXAC9IVRw: The page needs to be reloaded."), "outdated: 'page needs to be reloaded' (seen from a real old copy)")
check(YouTubeDownloader.explain("ERROR: [youtube] jNQXAC9IVRw: The page needs to be reloaded.").contains(YouTubeDownloader.outdatedToolHint), "explain: reload error -> out-of-date hint")
check(!YouTubeDownloader.isOutdatedToolFailure("That video is unavailable or private."), "outdated: private video is not stale-tool")
check(!YouTubeDownloader.isOutdatedToolFailure(nil), "outdated: nil")
let e429 = YouTubeDownloader.explain("ERROR: HTTP Error 429: Too Many Requests")
check(e429.contains(YouTubeDownloader.rateLimitHint) && YouTubeDownloader.isPushbackFailure(e429), "explain: 429 -> rate-limit message", e429)
check(YouTubeDownloader.isPushbackFailure("Sign in to confirm you're not a bot"), "pushback: not-a-bot detected")
check(YouTubeDownloader.explain("ERROR: Sign in to confirm you’re not a bot").contains(YouTubeDownloader.rateLimitHint), "explain: bot check -> rate-limit")
check(YouTubeDownloader.explain("ERROR: Sign in to confirm your age").contains("age-restricted"), "explain: age restriction")
check(YouTubeDownloader.explain("ERROR: [generic] 'x' is not a valid URL").contains("link"), "explain: invalid URL")
check(YouTubeDownloader.explain("ERROR: Unsupported URL: https://x.test").contains("link"), "explain: unsupported URL")
check(YouTubeDownloader.explain("ERROR: unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>").contains("internet"), "explain: no internet")
eq(YouTubeDownloader.explain(""), "The download failed.", "explain: empty output")
check(!e403.lowercased().contains("yt-dlp") && !e429.lowercased().contains("yt-dlp"), "explain: user-facing text never says yt-dlp")
check(FFmpegRunner.explain("x.mp4: Invalid data found when processing input").contains("couldn't be read"), "explain: ffmpeg invalid data")
check(FFmpegRunner.explain("Permission denied").contains("allowed"), "explain: ffmpeg permission")

// MARK: Stale-tool retry (async)
func runAsync(_ body: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await body(); sem.signal() }
    sem.wait()
}
final class Counter { var attempts = 0; var updates = 0; var announced = 0 }
runAsync {
    let c = Counter()
    let r: String? = try? await YouTubeDownloader.retryingAfterUpdate(
        attempt: { c.attempts += 1; if c.attempts == 1 { throw HelperError.message(YouTubeDownloader.outdatedToolHint) }; return "ok" },
        update: { c.updates += 1 }, onUpdating: { c.announced += 1 })
    check(r == "ok" && c.attempts == 2 && c.updates == 1 && c.announced == 1, "retry: stale failure -> update once -> retry succeeds", "\(String(describing: r)) \(c.attempts) \(c.updates)")
}
runAsync {
    let c = Counter()
    do { _ = try await YouTubeDownloader.retryingAfterUpdate(attempt: { c.attempts += 1; throw HelperError.message("HTTP Error 403: Forbidden") as Error }, update: { c.updates += 1 }) as String
        check(false, "retry: still failing -> error") }
    catch { check(c.attempts == 2 && c.updates == 1 && (error as? HelperError) == .message(YouTubeDownloader.stillRefusedMessage), "retry: retries only once, then explains", "\(error) \(c.attempts)") }
}
runAsync {
    let c = Counter()
    do { _ = try await YouTubeDownloader.retryingAfterUpdate(attempt: { c.attempts += 1; throw HelperError.message("That video is unavailable or private.") as Error }, update: { c.updates += 1 }) as String
        check(false, "retry: other error") }
    catch { check(c.attempts == 1 && c.updates == 0, "retry: unrelated failure is NOT retried or updated", "\(c.attempts) \(c.updates)") }
}
runAsync {
    do { _ = try await YouTubeDownloader.retryingAfterUpdate(attempt: { throw HelperError.message("403 Forbidden") as Error }, update: { throw HelperError.message("offline") }) as String
        check(false, "retry: update failure") }
    catch { check((error as? HelperError)?.errorDescription?.contains("couldn't update itself") == true, "retry: if the update itself fails, say so", "\(error)") }
}
runAsync {
    do { _ = try await YouTubeDownloader.retryingAfterUpdate(attempt: { throw HelperError.cancelled as Error }, update: { check(false, "retry: cancel must not update") }) as String }
    catch { check((error as? HelperError) == .cancelled, "retry: cancellation passes straight through") }
}

// MARK: Checksums
eq(Checksum.expectedHash(in: "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202  yt-dlp_macos\nffff  other\n", forFile: "yt-dlp_macos"), "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202", "checksum: list lookup by file name")
eq(Checksum.expectedHash(in: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924  ffmpeg.zip\n"), "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924", "checksum: single-line file")
check(Checksum.expectedHash(in: "<html>404</html>") == nil, "checksum: junk rejected")
check(Checksum.expectedHash(in: "abc  yt-dlp_macos", forFile: "yt-dlp_macos") == nil, "checksum: short hash rejected")

// MARK: Version comparison, update feed and signatures
check(AppVersion("1.10")! > AppVersion("1.9")!, "version: 1.10 > 1.9 (numeric, not alphabetical)")
check(AppVersion("2.0")! > AppVersion("1.99.99")!, "version: 2.0 > 1.99.99")
check(AppVersion("1.0")! == AppVersion("1.0.0")!, "version: 1.0 == 1.0.0")
check(AppVersion("1.0")! < AppVersion("1.0.1")!, "version: 1.0 < 1.0.1")
eq(AppVersion("v1.2", prefix: "v")?.description, "1.2", "version: tag v1.2 parsed with prefix v")
check(AppVersion("lite-v1.2", prefix: "v") == nil, "version: another app's tag rejected")
check(AppVersion("1.x") == nil && AppVersion("") == nil && AppVersion("1..2") == nil && AppVersion("1.2-beta") == nil, "version: junk rejected")

func release(_ tag: String, draft: Bool = false, pre: Bool = false, assets: [String]? = nil) -> GitHubRelease {
    let v = AppVersion(tag, prefix: "v")
    let names = assets ?? (v.map { [UpdateFeed.zipName($0), UpdateFeed.zipName($0) + ".sig"] } ?? [])
    let list = names.map { #"{"name":"\#($0)","size":1,"browser_download_url":"https://example.test/dl/\#($0)"}"# }.joined(separator: ",")
    let j = #"{"tag_name":"\#(tag)","name":"\#(tag)","body":"Notes for \#(tag)","draft":\#(draft),"prerelease":\#(pre),"assets":[\#(list)]}"#
    return try! JSONDecoder().decode(GitHubRelease.self, from: Data(j.utf8))
}
let cur = AppVersion("1.0")!
let offer = UpdateFeed.bestOffer(in: [release("v1.1"), release("v1.3"), release("v1.2")], current: cur)
eq(offer?.version.description, "1.3", "feed: newest complete release offered"); eq(offer?.zip.name, "MediaHelper-1.3.zip", "feed: zip asset name"); eq(offer?.signature.name, "MediaHelper-1.3.zip.sig", "feed: signature asset name")
check(UpdateFeed.bestOffer(in: [release("v1.0")], current: cur) == nil, "feed: same version not offered")
check(UpdateFeed.bestOffer(in: [release("v0.9")], current: cur) == nil, "feed: older not offered")
check(UpdateFeed.bestOffer(in: [release("v1.5", draft: true)], current: cur) == nil, "feed: draft ignored")
check(UpdateFeed.bestOffer(in: [release("v1.5", pre: true)], current: cur) == nil, "feed: pre-release ignored")
check(UpdateFeed.bestOffer(in: [release("v1.5", assets: ["MediaHelper-1.5.zip"])], current: cur) == nil, "feed: no signature = never offered")
check(UpdateFeed.bestOffer(in: [release("lite-v9.0", assets: ["x.zip"])], current: cur) == nil, "feed: other tag ignored")
eq(UpdateFeed.bestOffer(in: [release("v1.2", assets: ["MediaHelper-1.2.zip"]), release("v1.1")], current: cur)?.version.description, "1.1", "feed: falls back to older complete release")

let priv = Curve25519.Signing.PrivateKey(); let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
let tmpZip = FileManager.default.temporaryDirectory.appendingPathComponent("mh-\(UUID()).zip")
try! Data("pretend zip contents".utf8).write(to: tmpZip); defer { try? FileManager.default.removeItem(at: tmpZip) }
let dig = try! UpdateVerifier.digest(of: tmpZip); let sig = try! UpdateVerifier.sign(digest: dig, privateKey: priv)
check(UpdateVerifier.isValid(signatureBase64: sig, digest: dig, publicKeyBase64: pubB64), "signature: genuine signature accepted")
check(!UpdateVerifier.isValid(signatureBase64: sig, digest: Data(SHA256.hash(data: Data("other".utf8))), publicKeyBase64: pubB64), "signature: signature of another file refused")
check(!UpdateVerifier.isValid(signatureBase64: sig, digest: dig, publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()), "signature: wrong key refused")
check(!UpdateVerifier.isValid(signatureBase64: "not base64!!", digest: dig, publicKeyBase64: pubB64), "signature: junk refused")
check(!UpdateVerifier.isValid(signatureBase64: sig, digest: dig, publicKeyBase64: ""), "signature: empty key refused")

// MARK: Process runner (drains both pipes, handles big output, cancel)
runAsync {
    // 3 MB on stderr AND stdout at once would stall a naive reader.
    let r = try? await ProcessRunner.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero | tr '\\0' 'x' >&2 & head -c 3000000 /dev/zero | tr '\\0' 'y'; wait"])
    check(r?.succeeded == true && (r?.stdout.count ?? 0) >= 2_900_000 && (r?.stderr.count ?? 0) >= 2_900_000, "process: large stdout+stderr drained without stalling", "\(r?.stdout.count ?? -1) \(r?.stderr.count ?? -1)")
}
runAsync {
    let token = CancelToken()
    let started = Date()
    Task { try? await Task.sleep(nanoseconds: 500_000_000); token.cancel() }
    do { _ = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30"], token: token); check(false, "process: cancel") }
    catch { check((error as? HelperError) == .cancelled && Date().timeIntervalSince(started) < 5, "process: cancel stops a running program promptly (incl. children)", "\(error) \(Date().timeIntervalSince(started))") }
}
runAsync {
    let seen = LockedLines()
    let r = try? await ProcessRunner.run("/bin/sh", ["-c", "echo one; echo two >&2; echo three"], onStdoutLine: { seen.add($0) })
    check(r?.stdout == "one\nthree\n" && r?.stderr == "two\n" && seen.lines == ["one", "three"], "process: lines delivered live, streams kept separate", "\(String(describing: r))")
}
final class LockedLines { private let l = NSLock(); private var a: [String] = []; func add(_ s: String) { l.lock(); a.append(s); l.unlock() }; var lines: [String] { l.lock(); defer { l.unlock() }; return a } }

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

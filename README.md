# Media Helper

A small, friendly Mac app for church media volunteers (school assemblies, hire events). It does three things:

1. **Download from YouTube.** Paste one or more YouTube links (one per line), choose **Audio** (MP3, or M4A) or **Video** (MP4 that plays in PowerPoint, ProPresenter and QuickTime), and click **Download**. Links are processed one at a time; each shows its title, a progress bar, a status, **Cancel**, and **Show in Finder** when done.
2. **Video → Audio.** Drag video files onto the window (or **Choose Files…**) and get MP3 or M4A audio files. Works with MP4, MOV, M4V, MKV, WEBM and AVI.
3. **Slides → Images.** Drag PowerPoint (`.pptx`, `.ppt`), Keynote (`.key`) or PDF files onto the window (or **Choose Files…**) and get one picture for every slide or page, saved in a new folder named after the file (inside the save folder; a second "Sunday Slides" becomes "Sunday Slides 2"). Choose **PNG** (sharpest) or **JPEG**, a size (**Full HD** 1920 wide, **4K** 3840 wide, or **Original size**), and optionally a few letters to start each name with. Pictures are named like `Sunday_Slides_01.png`, with zero-padded numbers so they sort correctly. Each file shows "Slide 3 of 12", **Cancel** and **Show in Finder**. PowerPoint files need **Keynote** (free from the App Store), **Microsoft PowerPoint** or **LibreOffice** (free) on that Mac; PDFs need nothing extra; `.key` files use Keynote, or LibreOffice when Keynote isn't there (fonts may differ a little). WebP isn't offered: this Mac's image framework can't write it.

Everything is saved to one **Save to:** folder (default Downloads) that you can change; Video → Audio can also save next to the original video. Files are never overwritten: a second "Song" becomes "Song 2".

Screenshots are in [`docs/screenshots/`](docs/screenshots/).

The helper programs it relies on (a YouTube downloader and an audio/video converter) are installed and kept up to date by the app itself, in `~/Library/Application Support/Media Helper/Tools/`. No Homebrew or Terminal needed. The first launch needs the internet once ("Getting ready…").

* Native macOS app, SwiftUI, macOS 14 or newer, universal (Apple Silicon + Intel).
* App Sandbox off (it starts helper programs), ad-hoc signed.
* Installing on a church Mac: see [SETUP.md](SETUP.md).
* Shipping updates: see [UPDATING.md](UPDATING.md).

## Build

You need full Xcode (not just the command line tools) and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # or whichever Xcode you use
./build.sh            # -> build/Media Helper.app  (Release, universal, ad-hoc signed)
./build.sh debug      # Debug build
```

`build.sh` runs xcodegen (`project.yml` is the source of truth; the `.xcodeproj` is generated and git-ignored), builds with a macOS 14.0 deployment target, signs ad hoc, and prints the architectures and `minos` it found.

The app icon is drawn by `scripts/make-icon.swift` (`swiftc -O -o /tmp/make-icon scripts/make-icon.swift && /tmp/make-icon`), which writes `MediaHelper/Resources/AppIcon.icns`.

## How it works

| Piece | Where |
| --- | --- |
| Link handling, yt-dlp command line, progress parsing, error explaining, stale-tool retry | `MediaHelper/Core/YouTubeDownloader.swift`, `ProgressParsers.swift` |
| Video → Audio (ffmpeg, progress from `-progress pipe:1`) | `MediaHelper/Core/MediaConverter.swift` |
| Safe file names, never-overwrite naming | `MediaHelper/Core/Naming.swift` |
| Running programs (PATH, both pipes drained, cancel kills the whole process tree) | `MediaHelper/Core/ProcessRunner.swift` |
| Installing/updating the helper programs | `MediaHelper/Core/ToolInstaller.swift`, `FileDownloader.swift` |
| App self-update (signed, GitHub releases) | `MediaHelper/Core/UpdateCore.swift`, `MediaHelper/App/UpdateManager.swift` |
| Slides → Images: naming, sizes, choosing the program, drawing PDF pages (crop box, rotation, white background) | `MediaHelper/Core/SlideConverter.swift` |
| Making a PDF out of a PowerPoint/Keynote file (LibreOffice, or PowerPoint/Keynote through AppleScript) | `MediaHelper/Core/OfficeExporter.swift` |
| UI | `MediaHelper/Views/` |

### How Slides → Images works

1. PDFs go straight to step 3. A PowerPoint file is turned into a PDF by the first of **LibreOffice** (runs invisibly), **Microsoft PowerPoint**, **Keynote** that is installed; `.key` files use Keynote first, then LibreOffice.
2. PowerPoint and Keynote are driven with AppleScript on a private copy of the file (the original is never opened or changed). The copy is closed without saving, an app that wasn't already running is quit again, and the scratch files are deleted. The first time, macOS asks "Media Helper wants to control PowerPoint/Keynote"; the answer is OK. Files are handled one at a time, because these apps can't be driven in parallel.
3. Each PDF page is drawn at the chosen size with the crop box and page rotation honoured, on a white background, and written as PNG or JPEG (quality 0.92).
4. The finished folder is moved into the save folder, so a cancelled or failed file leaves nothing behind.

Sandboxed PowerPoint refuses to write anywhere it hasn't been given (it stops with a "Grant File Access" box). The export therefore saves into a file whose name starts with `~$`, which is the one kind of file its sandbox always lets it write. If a future PowerPoint closes that gap, the box will appear on the first slide file and has to be answered by hand.

Downloads and conversions work in a scratch folder in the system temp directory and the finished file is moved into the save folder, so a cancelled or crashed job never leaves partial files in someone's Downloads.

### Where the helper programs come from

* **Downloader:** the official standalone `yt-dlp_macos` from `github.com/yt-dlp/yt-dlp/releases/latest`, verified against the `SHA2-256SUMS` published with the release. It updates itself with `yt-dlp -U` (silently at launch when the last check was more than 24 hours ago, and automatically, with one retry, when a download fails the way an out-of-date copy does).
* **Converter (ffmpeg + ffprobe):** static builds from `ffmpeg.martin-riedl.de` (`/redirect/latest/macos/<arm64|amd64>/release/<ffmpeg|ffprobe>.zip`), chosen by the Mac's real architecture and verified against the `.sha256` file published beside each download. After install the app runs `ffmpeg -version`; if macOS refuses to run it, it is ad-hoc signed and retried.
* Homebrew copies are used only if installing the managed copies fails.

## Testing

```bash
tests/run-tests.sh                                   # unit tests (no Xcode project needed): naming, progress parsing, errors, versions, signatures, process handling
tests/qa-convert.sh "build/Media Helper.app" <tools dir> <work dir>   # video -> audio for mp4/mov/m4v/mkv/webm/avi, checked with ffprobe
tests/qa-slides.sh "build/Media Helper.app" <work dir> [<a .pptx>]   # slides -> pictures: generated PDFs checked pixel by pixel; with a .pptx also the PowerPoint, Keynote and .key paths, cancelling, tidy-up
tests/qa-update.sh <tools dir> <work dir>            # whole update path with throwaway keys and a local feed
tests/screenshots.sh "build/Media Helper.app" <tools dir> <work dir> docs/screenshots [<a .pptx>]   # ONLY=slides takes just the slide shots
```

The app has headless QA flags that run its own code paths without a window:

```
-qaInstallTools                       install missing tools (honours -toolsDir)
-qaDownload <link> audio|video -saveTo <folder> [-qaFormat mp3|m4a] [-qaQuality best|720|480] [-qaCancelAfter <s>]
-qaConvert <file> mp3|m4a  (-saveTo <folder> | -nextToOriginal)
-qaSlides <file> png|jpeg [-qaSize fullhd|4k|original] [-qaPrefix <text>] [-qaRenderer libreoffice|powerpoint|keynote] [-qaCancelAfter <s>] -saveTo <folder>
-qaUpdateTool                         update the downloader like a stale-tool retry does
-qaUpdateCheck | -qaUpdateInstall     with -updateFeed <releases.json or folder> -updateKey <base64 public key> -currentVersion <v>
-supportDir <folder> -toolsDir <folder>   keep all of the app's files somewhere else (so tests never touch the real ones)
```

For screenshots there are launch hooks `-qaSection download|convert|slides`, `-qaAutoDownload <link> [-qaAutoKind audio|video]`, `-qaAutoConvert <file>` and `-qaAutoSlides <file>` (these also take `-qaSlideFormat`, `-qaSize`, `-qaPrefix`, `-qaRenderer`; note they are remembered like normal settings).

## Releasing

See [UPDATING.md](UPDATING.md). In short: `scripts/setup-updates.sh <owner/repo>` once, then `scripts/release.sh 1.1 "What changed"` for every release.

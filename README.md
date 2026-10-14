# Media Helper

A small, friendly Mac app for church media volunteers (school assemblies, hire events). It does two things:

1. **Download from YouTube.** Paste one or more YouTube links (one per line), choose **Audio** (MP3, or M4A) or **Video** (MP4 that plays in PowerPoint, ProPresenter and QuickTime), and click **Download**. Links are processed one at a time; each shows its title, a progress bar, a status, **Cancel**, and **Show in Finder** when done.
2. **Video → Audio.** Drag video files onto the window (or **Choose Files…**) and get MP3 or M4A audio files. Works with MP4, MOV, M4V, MKV, WEBM and AVI.

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
| UI | `MediaHelper/Views/` |

Downloads and conversions work in a scratch folder in the system temp directory and the finished file is moved into the save folder, so a cancelled or crashed job never leaves partial files in someone's Downloads.

### Where the helper programs come from

* **Downloader:** the official standalone `yt-dlp_macos` from `github.com/yt-dlp/yt-dlp/releases/latest`, verified against the `SHA2-256SUMS` published with the release. It updates itself with `yt-dlp -U` (silently at launch when the last check was more than 24 hours ago, and automatically, with one retry, when a download fails the way an out-of-date copy does).
* **Converter (ffmpeg + ffprobe):** static builds from `ffmpeg.martin-riedl.de` (`/redirect/latest/macos/<arm64|amd64>/release/<ffmpeg|ffprobe>.zip`), chosen by the Mac's real architecture and verified against the `.sha256` file published beside each download. After install the app runs `ffmpeg -version`; if macOS refuses to run it, it is ad-hoc signed and retried.
* Homebrew copies are used only if installing the managed copies fails.

## Testing

```bash
tests/run-tests.sh                                   # unit tests (no Xcode project needed): naming, progress parsing, errors, versions, signatures, process handling
tests/qa-convert.sh "build/Media Helper.app" <tools dir> <work dir>   # video -> audio for mp4/mov/m4v/mkv/webm/avi, checked with ffprobe
tests/qa-update.sh <tools dir> <work dir>            # whole update path with throwaway keys and a local feed
tests/screenshots.sh "build/Media Helper.app" <tools dir> <work dir> docs/screenshots
```

The app has headless QA flags that run its own code paths without a window:

```
-qaInstallTools                       install missing tools (honours -toolsDir)
-qaDownload <link> audio|video -saveTo <folder> [-qaFormat mp3|m4a] [-qaQuality best|720|480] [-qaCancelAfter <s>]
-qaConvert <file> mp3|m4a  (-saveTo <folder> | -nextToOriginal)
-qaUpdateTool                         update the downloader like a stale-tool retry does
-qaUpdateCheck | -qaUpdateInstall     with -updateFeed <releases.json or folder> -updateKey <base64 public key> -currentVersion <v>
-supportDir <folder> -toolsDir <folder>   keep all of the app's files somewhere else (so tests never touch the real ones)
```

For screenshots there are launch hooks `-qaSection download|convert`, `-qaAutoDownload <link> [-qaAutoKind audio|video]` and `-qaAutoConvert <file>`.

## Releasing

See [UPDATING.md](UPDATING.md). In short: `scripts/setup-updates.sh <owner/repo>` once, then `scripts/release.sh 1.1 "What changed"` for every release.

import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: Options

enum SlideImageFormat: String, CaseIterable, Identifiable, Equatable {
    case png, jpeg
    var id: String { rawValue }
    var ext: String { self == .png ? "png" : "jpg" }
    var title: String { self == .png ? "PNG (sharpest)" : "JPEG (smaller files)" }
    /// JPEG quality used for every slide.
    static let jpegQuality = 0.92
}

enum SlideSize: String, CaseIterable, Identifiable, Equatable {
    case fullHD, fourK, original
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullHD: return "Full HD (1920 wide)"
        case .fourK: return "4K (3840 wide)"
        case .original: return "Original size"
        }
    }
    /// Width in pixels, or nil to keep the page's own size.
    var targetWidth: Int? {
        switch self {
        case .fullHD: return 1920
        case .fourK: return 3840
        case .original: return nil
        }
    }

    /// The picture size for a page that is `page` points across/high. The shape of the page is
    /// kept exactly; "original" means one pixel per point (a 13.33 × 7.5 inch slide is 960 × 540).
    /// Nothing ever gets bigger than 16,000 pixels either way.
    func pixelSize(forPage page: CGSize) -> (width: Int, height: Int) {
        let pw = max(page.width, 1), ph = max(page.height, 1)
        var w = Double(targetWidth ?? Int(pw.rounded()))
        var h = w * Double(ph / pw)
        let limit = 16000.0
        if max(w, h) > limit { let f = limit / max(w, h); w *= f; h *= f }
        return (max(Int(w.rounded()), 1), max(Int(h.rounded()), 1))
    }
}

// MARK: Naming

enum SlideNaming {
    /// How many digits the slide number gets: at least two, more for very long decks so the files always sort right.
    static func padWidth(total: Int) -> Int { max(2, String(max(total, 1)).count) }

    /// `<prefix><name>_<NN>.<ext>`, e.g. "Sunday_Slides_01.png". The prefix and name are made safe for file names.
    static func fileName(prefix: String, name: String, number: Int, total: Int, ext: String) -> String {
        let base = Naming.sanitize(prefix + name, fallback: "Slides")
        let n = String(format: "%0\(padWidth(total: total))d", number)
        return "\(base)_\(n).\(ext)"
    }
}

// MARK: Which program makes the PDF

enum SlideRenderer: String, Equatable, CaseIterable {
    case libreOffice, powerPoint, keynote

    var title: String {
        switch self {
        case .libreOffice: return "LibreOffice"
        case .powerPoint: return "PowerPoint"
        case .keynote: return "Keynote"
        }
    }

    var bundleID: String? {
        switch self {
        case .libreOffice: return nil
        case .powerPoint: return SlideRenderer.powerPointID
        case .keynote: return SlideRenderer.keynoteID
        }
    }

    /// What is installed on this Mac.
    struct Installed: Equatable {
        var libreOffice: URL?
        var powerPoint: URL?
        var keynote: URL?
        func has(_ r: SlideRenderer) -> Bool {
            switch r {
            case .libreOffice: return libreOffice != nil
            case .powerPoint: return powerPoint != nil
            case .keynote: return keynote != nil
            }
        }
    }

    static let powerPointID = "com.microsoft.Powerpoint"
    static let keynoteID = "com.apple.iWork.Keynote"

    static func detectInstalled() -> Installed {
        let fm = FileManager.default
        var lo: URL?
        let home = fm.homeDirectoryForCurrentUser.path
        for p in ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "\(home)/Applications/LibreOffice.app/Contents/MacOS/soffice",
                  "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"] where fm.isExecutableFile(atPath: p) {
            lo = URL(fileURLWithPath: p); break
        }
        return Installed(libreOffice: lo,
                         powerPoint: appURL(bundleID: powerPointID),
                         keynote: appURL(bundleID: keynoteID))
    }

    private static func appURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// The program to use, in order of preference: LibreOffice, PowerPoint, Keynote. Keynote files only
    /// open in Keynote. PDFs need none. `forced` is for testing a particular path.
    static func choose(forExtension ext: String, installed: Installed, forced: SlideRenderer? = nil) -> SlideRenderer? {
        let e = ext.lowercased()
        let allowed: [SlideRenderer] = e == "key" ? [.keynote] : [.libreOffice, .powerPoint, .keynote]
        if let forced { return allowed.contains(forced) && installed.has(forced) ? forced : nil }
        return allowed.first { installed.has($0) }
    }

    /// Friendly words for when nothing suitable is installed.
    static func missingMessage(forExtension ext: String) -> String {
        if ext.lowercased() == "key" {
            return "Keynote files need Keynote, which is free from the App Store. Install it and try again."
        }
        return "To turn PowerPoint files into pictures, this Mac needs Keynote (free from the App Store), Microsoft PowerPoint, or LibreOffice (free from libreoffice.org). Install one of them and try again."
    }
}

// MARK: Slides → images

enum SlideConverter {
    static let slideExtensions: Set<String> = ["pptx", "ppt", "key", "pdf"]
    static func isSupported(_ url: URL) -> Bool { slideExtensions.contains(url.pathExtension.lowercased()) }

    struct Options: Equatable {
        var format: SlideImageFormat = .png
        var size: SlideSize = .fullHD
        var prefix = ""
    }

    /// Makes one picture per slide or page of `input` inside a new folder (named after the file) in `saveFolder`.
    /// Returns that folder. The pictures are made in a scratch folder first and the finished folder is moved
    /// into place, so a cancelled or failed job leaves nothing behind. Never overwrites: a second
    /// "Sunday Slides" folder becomes "Sunday Slides 2".
    static func convert(input: URL, options: Options, saveFolder: URL, token: CancelToken,
                        forcedRenderer: SlideRenderer? = nil,
                        onStatus: @escaping (String) -> Void = { _ in },
                        onProgress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: input.path) else {
            throw HelperError.message("That file could not be found or opened.")
        }
        let ext = input.pathExtension.lowercased()
        guard slideExtensions.contains(ext) else {
            throw HelperError.message("That isn't a PowerPoint, Keynote or PDF file.")
        }
        let work = try AppPaths.makeWorkDir()
        defer { try? fm.removeItem(at: work) }

        let pdf: URL
        let unit: String
        if ext == "pdf" {
            pdf = input; unit = "Page"
        } else {
            unit = "Slide"
            guard let renderer = SlideRenderer.choose(forExtension: ext, installed: SlideRenderer.detectInstalled(), forced: forcedRenderer) else {
                throw HelperError.message(forcedRenderer == nil ? SlideRenderer.missingMessage(forExtension: ext)
                                          : "\(forcedRenderer!.title) can't be used for that file on this Mac.")
            }
            onStatus("Opening the presentation in \(renderer.title)…")
            onProgress(0.05)
            pdf = try await OfficeExporter.exportPDF(input: input, renderer: renderer, workDir: work, token: token, onStatus: onStatus)
            onStatus("Making pictures…")
        }
        try token.throwIfCancelled()

        let images = work.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        let name = input.deletingPathExtension().lastPathComponent
        let startFraction = ext == "pdf" ? 0.0 : 0.3
        let count = try renderPages(pdf: pdf, into: images, name: name, options: options, token: token) { done, total in
            onStatus("\(unit) \(done) of \(total)")
            onProgress(startFraction + (1 - startFraction) * Double(done) / Double(total))
        }
        try token.throwIfCancelled()
        guard count > 0 else { throw HelperError.message("There were no slides to save.") }

        do {
            try fm.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            let dest = Naming.uniqueFolderURL(in: saveFolder, baseName: Naming.sanitize(name, fallback: "Slides"))
            try fm.moveItem(at: images, to: dest)
            onProgress(1)
            return dest
        } catch {
            throw HelperError.message("The pictures were made but couldn't be saved in that folder: \(error.localizedDescription)")
        }
    }

    /// Draws every page of a PDF to its own image file. Honours each page's crop box and rotation, on a white
    /// background (no see-through slides). Returns how many pictures were written.
    static func renderPages(pdf url: URL, into folder: URL, name: String, options: Options, token: CancelToken?,
                            progress: (Int, Int) -> Void = { _, _ in }) throws -> Int {
        guard let doc = CGPDFDocument(url as CFURL) else {
            throw HelperError.message("That file couldn't be read as a PDF. It may be damaged.")
        }
        if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") {
            throw HelperError.message("That PDF is locked with a password, so Media Helper can't open it.")
        }
        let total = doc.numberOfPages
        guard total > 0 else { throw HelperError.message("That PDF doesn't have any pages.") }
        for number in 1...total {
            try token?.throwIfCancelled()
            guard let page = doc.page(at: number) else { throw HelperError.message("Page \(number) couldn't be read.") }
            let size = pageSize(page)
            let px = options.size.pixelSize(forPage: size)
            guard let image = draw(page: page, width: px.width, height: px.height) else {
                throw HelperError.message("Page \(number) couldn't be turned into a picture.")
            }
            let file = folder.appendingPathComponent(
                SlideNaming.fileName(prefix: options.prefix, name: name, number: number, total: total, ext: options.format.ext))
            try write(image, to: file, format: options.format)
            progress(number, total)
        }
        return total
    }

    /// The page as people see it: crop box size, swapped when the page is turned sideways.
    static func pageSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let turn = ((Int(page.rotationAngle) % 360) + 360) % 360
        return (turn == 90 || turn == 270) ? CGSize(width: box.height, height: box.width) : box.size
    }

    static func draw(page: CGPDFPage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(target)
        ctx.interpolationQuality = .high
        ctx.saveGState()
        // getDrawingTransform never scales a page up, so lay the page out at its natural size
        // (this handles the crop box and the page's rotation) and scale that up to the picture ourselves.
        let natural = CGRect(origin: .zero, size: pageSize(page))
        ctx.scaleBy(x: CGFloat(width) / natural.width, y: CGFloat(height) / natural.height)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: natural, rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, to url: URL, format: SlideImageFormat) throws {
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw HelperError.message("A picture couldn't be created.")
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = SlideImageFormat.jpegQuality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw HelperError.message("A picture couldn't be saved. There may not be enough space on this Mac.")
        }
    }
}

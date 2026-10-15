// Helper for the slide tests (compiled by tests/qa-slides.sh).
//   slide-fixtures make <folder>            writes pages.pdf (4 pages) into the folder
//   slide-fixtures pixel <image> <x> <y>    prints "WxH r g b" (x, y measured from the top-left corner)
import Foundation
import CoreGraphics
import ImageIO
import PDFKit

func rectData(_ r: CGRect) -> Data { var r = r; return Data(bytes: &r, count: MemoryLayout<CGRect>.size) }
func fill(_ c: CGContext, _ r: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
    c.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1)); c.fill(r)
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "make" {
    let dir = URL(fileURLWithPath: args[2], isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var media = CGRect(x: 0, y: 0, width: 960, height: 540)
    let ctx = CGContext(dir.appendingPathComponent("pages.pdf") as CFURL, mediaBox: &media, nil)!

    // Page 1: landscape 960 x 540. Nothing painted behind the shapes (must come out on white).
    //         Red square top-left, blue square bottom-right.
    ctx.beginPDFPage([kCGPDFContextMediaBox as String: rectData(media)] as CFDictionary)
    fill(ctx, CGRect(x: 0, y: 420, width: 120, height: 120), 1, 0, 0)
    fill(ctx, CGRect(x: 840, y: 0, width: 120, height: 120), 0, 0, 1)
    ctx.endPDFPage()

    // Page 2: the same drawing on a page turned 90 degrees clockwise: shown 540 x 960,
    //         red square top-RIGHT, blue square bottom-LEFT.
    ctx.beginPDFPage([kCGPDFContextMediaBox as String: rectData(media)] as CFDictionary)
    fill(ctx, CGRect(x: 0, y: 420, width: 120, height: 120), 1, 0, 0)
    fill(ctx, CGRect(x: 840, y: 0, width: 120, height: 120), 0, 0, 1)
    ctx.endPDFPage()

    // Page 3: crop box (100,50)-(740,410), shown 640 x 360. Green everywhere, red square at the crop's
    //         top-left corner, blue square just outside the crop (must not show).
    ctx.beginPDFPage([kCGPDFContextMediaBox as String: rectData(media), kCGPDFContextCropBox as String: rectData(CGRect(x: 100, y: 50, width: 640, height: 360))] as CFDictionary)
    fill(ctx, media, 0, 0.6, 0)
    fill(ctx, CGRect(x: 100, y: 290, width: 120, height: 120), 1, 0, 0)
    fill(ctx, CGRect(x: 20, y: 20, width: 60, height: 60), 0, 0, 1)
    ctx.endPDFPage()

    // Page 4: US Letter portrait 612 x 792, green.
    let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    ctx.beginPDFPage([kCGPDFContextMediaBox as String: rectData(letter)] as CFDictionary)
    fill(ctx, letter, 0, 0.6, 0)
    ctx.endPDFPage()
    ctx.closePDF()
    // CoreGraphics has no switch for a turned page, so set /Rotate 90 on page 2 afterwards.
    let file = dir.appendingPathComponent("pages.pdf")
    let doc = PDFDocument(url: file)!
    doc.page(at: 1)!.rotation = 90
    doc.write(to: file)
    print("wrote \(dir.path)/pages.pdf")
} else if args.count >= 5, args[1] == "pixel" {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("unreadable"); exit(1) }
    let x = Int(args[3])!, y = Int(args[4])!
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    print("\(img.width)x\(img.height) \(px[0]) \(px[1]) \(px[2])")
} else { print("usage: make <folder> | pixel <image> <x> <y>"); exit(2) }

// Exercises every conversion and tool on generated sample files and checks the outputs decode.
// Run: swift run -c release dropwheel-selftest
import AppKit
import PDFKit
import DropWheelCore

let work = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-selftest-\(UUID().uuidString.prefix(6))")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let opts = OutputOptions(location: .sameFolder, jpegQuality: 0.85, pdfRenderDPI: 150)
var passed = 0, failed = 0

@MainActor func check(_ name: String, _ body: @MainActor () async throws -> String) async {
    do {
        let detail = try await body()
        passed += 1
        print("  ✓ \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    } catch {
        failed += 1
        print("  ✗ \(name)  — \(error.localizedDescription)")
    }
}

func expect(_ cond: Bool, _ msg: String) throws { if !cond { throw DropWheelError(msg) } }

// MARK: Sample files

let sampleText = """
Title: Nurses Turnover: Retention of the Staff
According to Alharbi (2022), the causes of nurse turnover were studied in this review.
Contact: jane.doe@example.com or +1 415 555 0134.

Recommendations are general and prescriptive.
"""

/// A test image with text on it, a gradient and a transparent corner.
func makeImage(width: Int, height: Int, alphaCorner: Bool) -> CGImage {
    let ctx = ImageKit.makeContext(width: width, height: height)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let grad = CGGradient(colorsSpace: ImageKit.sRGB, colors: [CGColor(srgbRed: 1, green: 0.4, blue: 0.2, alpha: 1),
                                                                CGColor(srgbRed: 0.3, green: 0.4, blue: 1, alpha: 1)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: width, y: 0), options: [])
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 40, y: height / 2 - 120, width: width - 80, height: 240))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ("INVOICE 2026\njane.doe@example.com" as NSString).draw(at: CGPoint(x: 70, y: height / 2 - 90), withAttributes: [
        .font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    if alphaCorner { ctx.clear(CGRect(x: 0, y: 0, width: 60, height: 60)) }
    return ctx.makeImage()!
}

let img = makeImage(width: 1200, height: 800, alphaCorner: true)
let pngURL = work.appendingPathComponent("Sample.png")
try ImageKit.write(img, to: pngURL, as: .png)

// JPEG with EXIF + GPS for the metadata tests.
let jpgURL = work.appendingPathComponent("Photo.jpg")
do {
    let dest = CGImageDestinationCreateWithURL(jpgURL as CFURL, "public.jpeg" as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens", kCGImagePropertyExifDateTimeOriginal: "2026:11:18 10:00:00"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam"],
    ]
    CGImageDestinationAddImage(dest, ImageKit.flattened(img), props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

let txtURL = work.appendingPathComponent("Notes.txt")
try sampleText.write(to: txtURL, atomically: true, encoding: .utf8)

// A 3-page PDF made from text.
let pdfURL = work.appendingPathComponent("Page 001.pdf")
let longText = Array(repeating: sampleText, count: 40).joined(separator: "\n\n")
try await MainActor.run { try DocumentKit.pdfData(from: DocumentKit.plainAttributed(longText)).write(to: pdfURL) }

// A scanned-style PDF (image only, no text layer) to exercise OCR.
let scanURL = work.appendingPathComponent("Scan.pdf")
try DocumentKit.pdfData(fromImages: [pngURL]).write(to: scanURL)

// A .docx produced by our own writer, and an RTF produced by AppKit.
let docxURL = work.appendingPathComponent("Report.docx")
var builder = DocxBuilder()
builder.add(.heading("Quarterly report"))
builder.add(.paragraph("First paragraph with <xml> & \"quotes\"."))
builder.add(.image(png: try ImageKit.encode(ImageKit.scaled(img, maxPixel: 400), as: .png), pixelWidth: 400, pixelHeight: 267))
builder.add(.pageBreak)
builder.add(.paragraph("Second page."))
try builder.data().write(to: docxURL)

let rtfURL = work.appendingPathComponent("Letter.rtf")
try await MainActor.run {
    let a = DocumentKit.plainAttributed(sampleText)
    try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtfURL)
}

// MARK: Validators

func validateImage(_ url: URL, format: OutputFormat) throws -> String {
    let decoded = try ImageKit.load(url)
    try expect(decoded.width > 0 && decoded.height > 0, "decoded image is empty")
    return "\(decoded.width)×\(decoded.height), \(formattedSize(fileSize(url)))"
}

@MainActor func validateDocx(_ url: URL, contains needle: String? = nil) throws -> String {
    let a = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
    try expect(a.length > 0, "docx is empty")
    if let needle { try expect(a.string.localizedCaseInsensitiveContains(needle), "docx missing '\(needle)'") }
    return "\(a.length) chars"
}

func validatePDF(_ url: URL, minPages: Int = 1) throws -> String {
    let d = PDFDocument(url: url)!
    try expect(d.pageCount >= minPages, "expected ≥\(minPages) pages, got \(d.pageCount)")
    return "\(d.pageCount) pages, \(formattedSize(fileSize(url)))"
}

// MARK: Tests

print("Work folder: \(work.path)")
print("\nWebP encoder")
await check("WebP round-trip is pixel-exact") {
    let small = makeImage(width: 333, height: 211, alphaCorner: true)
    let data = try WebPEncoder.encode(small)
    let decoded = try ImageKit.load(data: data)
    try expect(decoded.width == 333 && decoded.height == 211, "size mismatch")
    // Compare unpremultiplied opaque pixels.
    func px(_ i: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: i.width * i.height * 4)
        let c = CGContext(data: &buf, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4,
                          space: ImageKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height)); return buf
    }
    let a = px(small), b = px(decoded)
    var maxDiff = 0
    for k in 0..<a.count { maxDiff = max(maxDiff, abs(Int(a[k]) - Int(b[k]))) }
    try expect(maxDiff <= 1, "pixels differ by up to \(maxDiff)")
    return "\(data.count) bytes vs PNG \(try ImageKit.encode(small, as: .png).count) bytes"
}
await check("WebP of 1×1 and solid images") {
    let ctx = ImageKit.makeContext(width: 1, height: 1)!; ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    _ = try ImageKit.load(data: try WebPEncoder.encode(ctx.makeImage()!))
    let big = ImageKit.makeContext(width: 640, height: 480)!; big.setFillColor(CGColor(gray: 1, alpha: 1)); big.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
    let d = try WebPEncoder.encode(big.makeImage()!)
    _ = try ImageKit.load(data: d)
    return "solid 640×480 → \(d.count) bytes"
}

print("\nImage conversions (Sample.png, Photo.jpg)")
for source in [pngURL, jpgURL] {
    for format in OutputFormat.targets(for: source) {
        await check("\(source.pathExtension.uppercased()) → \(format.label)") {
            let out = try await Converter.convert(source, to: format, options: opts)
            let url = out[0]
            switch format {
            case .pdf: return try validatePDF(url)
            case .txt:
                let t = try String(contentsOf: url, encoding: .utf8)
                try expect(t.localizedCaseInsensitiveContains("invoice"), "OCR didn't find 'INVOICE' (got: \(t.prefix(60)))")
                return "OCR: \(t.replacingOccurrences(of: "\n", with: " | "))"
            case .docx: return try await validateDocx(url, contains: "invoice")
            default: return try validateImage(url, format: format)
            }
        }
    }
}

print("\nPDF conversions (3-page text PDF + scanned PDF)")
for format in OutputFormat.targets(for: pdfURL) {
    await check("PDF → \(format.label)") {
        let out = try await Converter.convert(pdfURL, to: format, options: opts)
        switch format {
        case .txt:
            let t = try String(contentsOf: out[0], encoding: .utf8)
            try expect(t.contains("Nurses Turnover"), "text missing"); return "\(t.count) chars"
        case .docx: return try await validateDocx(out[0], contains: "Nurses Turnover")
        default:
            let files = try FileManager.default.contentsOfDirectory(at: out[0], includingPropertiesForKeys: nil)
            try expect(files.count >= 3, "expected one image per page, got \(files.count)")
            return "\(files.count) pages → \(try validateImage(files.sorted { $0.path < $1.path }[0], format: format))"
        }
    }
}
await check("Scanned PDF → TXT uses OCR") {
    let out = try await Converter.convert(scanURL, to: .txt, options: opts)
    let t = try String(contentsOf: out[0], encoding: .utf8)
    try expect(t.localizedCaseInsensitiveContains("invoice"), "OCR failed: \(t)"); return t.replacingOccurrences(of: "\n", with: " | ")
}
await check("Single-page PDF → JPG is one file") {
    let out = try await Converter.convert(scanURL, to: .jpg, options: opts)
    try expect(out[0].pathExtension == "jpg", "expected a jpg file"); return try validateImage(out[0], format: .jpg)
}

print("\nDocuments and text")
for source in [docxURL, rtfURL, txtURL] {
    for format in OutputFormat.targets(for: source) {
        await check("\(source.pathExtension.uppercased()) → \(format.label)") {
            let out = try await Converter.convert(source, to: format, options: opts)
            switch format {
            case .pdf: return try validatePDF(out[0], minPages: source == docxURL ? 2 : 1)
            case .docx: return try await validateDocx(out[0])
            case .txt:
                let t = try String(contentsOf: out[0], encoding: .utf8); try expect(!t.isEmpty, "empty"); return "\(t.count) chars"
            default:
                let a = try NSAttributedString(url: out[0], options: [:], documentAttributes: nil)
                try expect(a.length > 0, "empty"); return "\(a.length) chars"
            }
        }
    }
}

print("\nMulti-file")
await check("Combine images into PDF") { try validatePDF(try await Converter.combineImagesToPDF([pngURL, jpgURL], options: opts), minPages: 2) }
await check("Merge PDFs") { try validatePDF(try Converter.mergePDFs([pdfURL, scanURL], options: opts), minPages: 4) }

print("\nImage tools")
await check("Crop") {
    let c = try ImageTools.crop(img, to: CGRect(x: 100, y: 50, width: 640, height: 360))
    try expect(c.width == 640 && c.height == 360, "wrong size \(c.width)×\(c.height)"); return "640×360"
}
await check("Compress JPEG + resize") {
    let d = try ImageTools.compress(img, .init(quality: 0.5, maxPixel: 600, format: .jpg))
    let back = try ImageKit.load(data: d)
    try expect(back.width == 600, "expected width 600"); return "\(formattedSize(Int64(d.count))) vs PNG \(formattedSize(fileSize(pngURL)))"
}
await check("Edit: adjustments + rotate 90° clockwise") {
    var a = ImageTools.Adjustments(); a.exposure = 0.5; a.saturation = 1.4; a.warmth = 0.3; a.rotation = 1; a.look = .vivid
    let out = ImageTools.adjust(img, a)
    try expect(out.width == img.height && out.height == img.width, "rotation didn't swap dimensions")
    // The transparent corner was bottom-left in CG space (= top-left... visually bottom-left). After a clockwise turn it sits top-left.
    let ctx = ImageKit.makeContext(width: out.width, height: out.height)!
    ctx.draw(out, in: CGRect(x: 0, y: 0, width: out.width, height: out.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    // Top-left pixel in memory is row 0 (top of image).
    try expect(p[3] == 0, "expected transparent pixel at top-left after clockwise rotation, alpha=\(p[3])")
    return "\(out.width)×\(out.height)"
}
await check("Every look filter renders") {
    for look in ImageTools.Look.allCases { var a = ImageTools.Adjustments(); a.look = look; _ = ImageTools.adjust(ImageKit.scaled(img, maxPixel: 200), a) }
    return "\(ImageTools.Look.allCases.count) looks"
}
await check("Add background (gradients, solid, image, ratios)") {
    var s = ImageTools.BackgroundSettings()
    var sizes: [String] = []
    for g in ImageTools.gradients { s.background = .gradient(g); _ = ImageTools.addBackground(img, s, scale: 0.2) }
    s.background = .solid(ImageTools.solidColors[3]); s.ratio = .square
    let sq = ImageTools.addBackground(img, s)!
    try expect(sq.width == sq.height, "1:1 ratio not square"); sizes.append("1:1 \(sq.width)px")
    s.background = .image(SendableImage(img)); s.ratio = .wide
    let wide = ImageTools.addBackground(img, s)!
    try expect(abs(Double(wide.width) / Double(wide.height) - 16.0 / 9) < 0.01, "16:9 wrong"); sizes.append("16:9 \(wide.width)×\(wide.height)")
    return sizes.joined(separator: ", ")
}
await check("Annotate (all shapes)") {
    let red = ImageTools.RGBA(1, 0, 0)
    let items: [ImageTools.Annotation] = [
        .init(kind: .pen, points: [CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 120), CGPoint(x: 300, y: 50)], color: red, lineWidth: 6),
        .init(kind: .highlighter, points: [CGPoint(x: 50, y: 400), CGPoint(x: 600, y: 400)], color: .init(1, 1, 0), lineWidth: 8),
        .init(kind: .arrow, points: [CGPoint(x: 100, y: 700), CGPoint(x: 500, y: 500)], color: red, lineWidth: 6),
        .init(kind: .rectangle, points: [CGPoint(x: 700, y: 100), CGPoint(x: 1000, y: 300)], color: red, lineWidth: 6),
        .init(kind: .ellipse, points: [CGPoint(x: 700, y: 400), CGPoint(x: 1000, y: 700)], color: red, lineWidth: 6),
        .init(kind: .text, points: [CGPoint(x: 100, y: 100)], color: red, lineWidth: 6, text: "Hello"),
    ]
    let out = ImageTools.render(img, annotations: items)!
    // The rectangle's top edge at y=100 (top-left coords) must be red.
    let ctx = ImageKit.makeContext(width: out.width, height: out.height)!
    ctx.draw(out, in: CGRect(x: 0, y: 0, width: out.width, height: out.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let i = (100 * out.width + 850) * 4
    try expect(p[i] > 200 && p[i + 1] < 60, "rectangle edge not red at (850,100): \(p[i]),\(p[i+1]),\(p[i+2])")
    return "6 shapes"
}
await check("Redact: auto-detect sensitive text and faces, 3 styles") {
    let lines = try OCR.lines(in: img)
    let sensitive = lines.filter { OCR.isSensitive($0.text) }
    try expect(!sensitive.isEmpty, "didn't flag the email address (lines: \(lines.map(\.text)))")
    _ = try OCR.faces(in: img)
    for style in ImageTools.RedactStyle.allCases {
        guard ImageTools.redact(img, rects: sensitive.map(\.rect), style: style) != nil else { throw DropWheelError("\(style) failed") }
    }
    let boxed = ImageTools.redact(img, rects: sensitive.map(\.rect), style: .box)!
    let after = try OCR.lines(in: boxed).map(\.text).joined(separator: " ")
    try expect(!after.contains("@"), "email still readable after redaction: \(after)")
    return "flagged: \(sensitive.map(\.text))"
}
await check("Metadata: read, strip location, strip all") {
    let entries = ImageKit.metadata(jpgURL)
    try expect(entries.contains { $0.value.contains("Test Lens") }, "EXIF lens not read")
    try expect(ImageKit.hasLocation(jpgURL), "GPS not present in sample")
    let noGPS = work.appendingPathComponent("Photo NoGPS.jpg")
    try ImageKit.stripMetadata(jpgURL, to: noGPS, locationOnly: true)
    try expect(!ImageKit.hasLocation(noGPS), "GPS still present")
    try expect(ImageKit.metadata(noGPS).contains { $0.value.contains("Test Lens") }, "EXIF lost when only stripping GPS")
    let clean = work.appendingPathComponent("Photo Clean.jpg")
    try ImageKit.stripMetadata(jpgURL, to: clean, locationOnly: false)
    try expect(!ImageKit.hasLocation(clean), "GPS still present")
    try expect(!ImageKit.metadata(clean).contains { $0.value.contains("Test Lens") || $0.value.contains("TestCam") }, "EXIF/TIFF still present")
    return "\(entries.count) fields read"
}

print("\nPDF tools")
for level in PDFTools.CompressLevel.allCases {
    await check("Compress PDF (\(level.rawValue))") {
        let d = try PDFTools.compress(scanURL, level: level)
        try expect(PDFDocument(data: d)?.pageCount == 1, "invalid output")
        return "\(formattedSize(fileSize(scanURL))) → \(formattedSize(Int64(d.count)))"
    }
}
await check("Rotate PDF") {
    let out = work.appendingPathComponent("Rotated.pdf")
    try PDFTools.rotate(pdfURL, by: 90, to: out)
    try expect(PDFDocument(url: out)?.page(at: 0)?.rotation == 90, "not rotated"); return "90°"
}
await check("Rotated page renders landscape") {
    let page = PDFDocument(url: work.appendingPathComponent("Rotated.pdf"))!.page(at: 0)!
    let r = DocumentKit.render(page, dpi: 72)!
    try expect(r.width > r.height, "expected landscape, got \(r.width)×\(r.height)"); return "\(r.width)×\(r.height)"
}
await check("Split PDF") {
    let folder = try PDFTools.split(pdfURL, options: opts)
    let n = try FileManager.default.contentsOfDirectory(atPath: folder.path).count
    try expect(n == PDFDocument(url: pdfURL)!.pageCount, "wrong number of files"); return "\(n) files"
}
await check("Protect PDF with password") {
    let out = work.appendingPathComponent("Locked.pdf")
    try PDFTools.protect(pdfURL, password: "s3cret", to: out)
    let d = PDFDocument(url: out)!
    try expect(d.isEncrypted && d.isLocked, "not locked")
    try expect(d.unlock(withPassword: "s3cret"), "password doesn't unlock"); return "locked + unlocks"
}
await check("PDF metadata edit") {
    let out = work.appendingPathComponent("Meta.pdf")
    try PDFTools.writeMetadata(pdfURL, values: ["Title": "Retention", "Author": "Test Author", "Keywords": "a, b"], to: out)
    let m = try PDFTools.metadata(out)
    try expect(m["Title"] == "Retention" && m["Author"] == "Test Author", "metadata not saved: \(m)"); return "\(m["Title"]!), \(m["Author"]!)"
}

print("\nNaming")
await check("Outputs never overwrite") {
    let a = opts.outputURL(for: pngURL, suffix: "Cropped", ext: "png")
    try Data().write(to: a)
    let b = opts.outputURL(for: pngURL, suffix: "Cropped", ext: "png")
    try expect(a.lastPathComponent == "Sample Cropped.png" && b.lastPathComponent == "Sample Cropped 2.png", "\(a.lastPathComponent), \(b.lastPathComponent)")
    return b.lastPathComponent
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

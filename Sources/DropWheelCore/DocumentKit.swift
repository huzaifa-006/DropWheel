import AppKit
import PDFKit
import Vision

/// Text recognition (OCR) using Apple's on-device Vision framework.
public enum OCR {
    public struct Line: Sendable {
        public let text: String
        /// Bounding box in image pixels, origin at the top-left.
        public let rect: CGRect
    }

    public static func lines(in image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            let rect = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            return Line(text: candidate.string, rect: rect)
        }
    }

    public static func text(in image: CGImage) throws -> String {
        try lines(in: image).map(\.text).joined(separator: "\n")
    }

    /// Faces in image pixels (top-left origin), for the redact tool.
    public static func faces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).map { obs in
            let b = obs.boundingBox
            return CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        }
    }

    /// Lines that look sensitive: emails, phone numbers, long digit runs (cards, IBANs, IDs) and URLs.
    public static func isSensitive(_ text: String) -> Bool {
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"(\+?\d[\d\s().-]{7,}\d)"#,
            #"\b(?:\d[ -]?){9,}\b"#,
            #"https?://\S+"#,
            #"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

/// Rendering helpers for rich text and PDFs.
public enum DocumentKit {
    public static let pageSize = CGSize(width: 612, height: 792) // US Letter
    public static let margin: CGFloat = 54

    /// Opens .docx, .doc, .rtf, .odt, .html and plain text as an attributed string.
    @MainActor
    public static func attributedString(from url: URL) throws -> NSAttributedString {
        if FileKind.of(url) == .text {
            return plainAttributed(try readText(url))
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw DropWheelError("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public static func readText(_ url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var enc = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        throw DropWheelError("Couldn't read \(url.lastPathComponent) as text.")
    }

    public static func plainAttributed(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black,
            .paragraphStyle: para,
        ])
    }

    /// Lays out rich text over as many Letter pages as needed and returns PDF bytes.
    @MainActor
    public static func pdfData(from attributed: NSAttributedString) -> Data {
        let content = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        let storage = NSTextStorage(attributedString: attributed.length > 0 ? attributed : NSAttributedString(string: " "))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        while containers.count < 5000 {
            let tc = NSTextContainer(size: content)
            tc.lineFragmentPadding = 0
            layout.addTextContainer(tc)
            containers.append(tc)
            let range = layout.glyphRange(for: tc)
            if NSMaxRange(range) >= layout.numberOfGlyphs || range.length == 0 { break }
        }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for tc in containers {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let glyphs = layout.glyphRange(for: tc)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Renders one PDF page to a bitmap at the given DPI, on white.
    public static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let ptSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = dpi / 72
        let w = max(1, Int((ptSize.width * scale).rounded())), h = max(1, Int((ptSize.height * scale).rounded()))
        guard let ctx = ImageKit.makeContext(width: w, height: h, opaque: true) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        if let ref = page.pageRef {
            let t = ref.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: ptSize), rotate: 0, preserveAspectRatio: true)
            ctx.concatenate(t)
            ctx.drawPDFPage(ref)
        } else {
            page.draw(with: .mediaBox, to: ctx)
        }
        return ctx.makeImage()
    }

    public static func openPDF(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw DropWheelError("Couldn't open \(url.lastPathComponent) as a PDF.") }
        if doc.isLocked { throw DropWheelError("\(url.lastPathComponent) is password-protected.") }
        return doc
    }

    /// Builds a PDF where every image becomes one page sized to the image.
    public static func pdfData(fromImages urls: [URL]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw DropWheelError("Couldn't create the PDF.") }
        for url in urls {
            let img = try ImageKit.load(url)
            var dpi = 72.0
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let d = props[kCGImagePropertyDPIWidth] as? Double, d > 72 { dpi = d }
            var box = CGRect(x: 0, y: 0, width: Double(img.width) * 72 / dpi, height: Double(img.height) * 72 / dpi)
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
    }
}

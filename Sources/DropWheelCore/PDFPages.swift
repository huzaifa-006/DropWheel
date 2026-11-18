import Foundation
import PDFKit
import CoreText

public extension PDFTools {
    struct PageSpec: Sendable, Hashable, Identifiable {
        public let id = UUID()
        public let index: Int            // page index in the source PDF
        public var extraRotation: Int    // added to the page's rotation, multiples of 90
        public init(index: Int, extraRotation: Int = 0) { self.index = index; self.extraRotation = extraRotation }
    }

    /// Writes a new PDF with pages in the given order and rotations (pages not listed are dropped).
    static func rebuild(_ url: URL, pages: [PageSpec], to dest: URL) throws {
        guard !pages.isEmpty else { throw DropWheelError("Keep at least one page.") }
        let doc = try DocumentKit.openPDF(url)
        let out = PDFDocument()
        for spec in pages {
            guard let page = doc.page(at: spec.index)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + spec.extraRotation) % 360 + 360) % 360
            out.insert(page, at: out.pageCount)
        }
        if let attrs = doc.documentAttributes { out.documentAttributes = attrs }
        guard out.write(to: dest) else { throw DropWheelError("Couldn't write the PDF.") }
    }

    enum WatermarkPosition: String, CaseIterable, Sendable, Identifiable {
        case diagonal = "Diagonal", center = "Centre", footer = "Footer"
        public var id: String { rawValue }
    }

    struct WatermarkSettings: Sendable, Equatable {
        public var text = "CONFIDENTIAL"
        public var fontSize: Double = 64
        public var opacity: Double = 0.18
        public var color = ImageTools.RGBA(0.85, 0.1, 0.1)
        public var position: WatermarkPosition = .diagonal
        public init() {}
    }

    /// Stamps text on every page. Page content stays vector (text remains selectable).
    static func watermark(_ url: URL, _ s: WatermarkSettings, to dest: URL) throws {
        guard !s.text.trimmingCharacters(in: .whitespaces).isEmpty else { throw DropWheelError("Enter watermark text.") }
        let doc = try DocumentKit.openPDF(url)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw DropWheelError("Couldn't create the PDF.") }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let ref = page.pageRef else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            ctx.concatenate(ref.getDrawingTransform(.mediaBox, rect: box, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(ref)
            ctx.restoreGState()
            drawWatermark(s, in: ctx, size: size)
            ctx.endPage()
        }
        ctx.closePDF()
        try (data as Data).write(to: dest, options: .atomic)
    }

    static func drawWatermark(_ s: WatermarkSettings, in ctx: CGContext, size: CGSize) {
        var color = s.color; color.a = s.opacity
        let fontSize = s.position == .footer ? min(s.fontSize, 18) : s.fontSize
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attr = NSAttributedString(string: s.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        switch s.position {
        case .diagonal:
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: atan2(size.height, size.width))
            ctx.textPosition = CGPoint(x: -w / 2, y: -fontSize / 3)
        case .center:
            ctx.textPosition = CGPoint(x: (size.width - w) / 2, y: size.height / 2 - fontSize / 3)
        case .footer:
            ctx.textPosition = CGPoint(x: (size.width - w) / 2, y: 24)
        }
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// A small thumbnail of every page, for the page organizer.
    static func thumbnails(_ url: URL, maxPixel: Int = 220) throws -> [SendableImage] {
        let doc = try DocumentKit.openPDF(url)
        return (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let longest = max(page.bounds(for: .mediaBox).width, page.bounds(for: .mediaBox).height)
            return DocumentKit.render(page, dpi: 72 * Double(maxPixel) / max(1, longest)).map(SendableImage.init)
        }
    }
}

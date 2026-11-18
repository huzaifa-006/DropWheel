import AppKit
import PDFKit

/// Format conversion for every file family the wheel supports. Returns the files it wrote.
public enum Converter {
    public static func convert(_ urls: [URL], to format: OutputFormat, options: OutputOptions) async throws -> [URL] {
        var out: [URL] = []
        for url in urls where OutputFormat.targets(for: url).contains(format) {
            out += try await convert(url, to: format, options: options)
        }
        if out.isEmpty { throw DropWheelError("None of these files can become \(format.label).") }
        return out
    }

    public static func convert(_ url: URL, to format: OutputFormat, options: OutputOptions) async throws -> [URL] {
        switch FileKind.of(url) {
        case .image: return [try await imageTask { try convertImage(url, to: format, options: options) }]
        case .pdf: return try await imageTask { try convertPDF(url, to: format, options: options) }
        case .document, .text: return [try await convertDocument(url, to: format, options: options)]
        case .unsupported: throw DropWheelError("\(url.lastPathComponent) isn't a supported file type.")
        }
    }

    /// Runs CPU-heavy work off the main thread.
    static func imageTask<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    // MARK: Images

    static func convertImage(_ url: URL, to format: OutputFormat, options: OutputOptions) throws -> URL {
        let dest = options.outputURL(for: url, ext: format.fileExtension)
        switch format {
        case _ where format.isImage:
            let img = try ImageKit.load(url)
            try ImageKit.write(img, to: dest, as: format, quality: options.jpegQuality)
        case .pdf:
            try DocumentKit.pdfData(fromImages: [url]).write(to: dest, options: .atomic)
        case .txt:
            let text = try OCR.text(in: try ImageKit.load(url))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DropWheelError("No text was found in this image.")
            }
            try text.write(to: dest, atomically: true, encoding: .utf8)
        case .docx:
            let img = try ImageKit.load(url)
            var doc = DocxBuilder()
            let lines = try OCR.lines(in: img)
            if lines.isEmpty {
                let png = try ImageKit.encode(ImageKit.scaled(img, maxPixel: 3000), as: .png)
                doc.add(.image(png: png, pixelWidth: img.width, pixelHeight: img.height))
            } else {
                for p in paragraphs(from: lines.map(\.text).joined(separator: "\n")) { doc.add(.paragraph(p)) }
            }
            try doc.data().write(to: dest, options: .atomic)
        default:
            throw DropWheelError("Images can't be converted to \(format.label).")
        }
        return dest
    }

    // MARK: PDFs

    static func convertPDF(_ url: URL, to format: OutputFormat, options: OutputOptions) throws -> [URL] {
        let doc = try DocumentKit.openPDF(url)
        guard doc.pageCount > 0 else { throw DropWheelError("This PDF has no pages.") }
        switch format {
        case .jpg, .png, .webp, .heic, .tiff:
            if doc.pageCount == 1 {
                let dest = options.outputURL(for: url, ext: format.fileExtension)
                guard let page = doc.page(at: 0), let img = DocumentKit.render(page, dpi: options.pdfRenderDPI) else {
                    throw DropWheelError("Couldn't render the page.")
                }
                try ImageKit.write(img, to: dest, as: format, quality: options.jpegQuality)
                return [dest]
            }
            let base = url.deletingPathExtension().lastPathComponent
            let folder = OutputOptions.uniqueFolder(options.folder(for: url), base: "\(base) \(format.label)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var outs: [URL] = []
            let digits = String(doc.pageCount).count
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let img = DocumentKit.render(page, dpi: options.pdfRenderDPI) else { continue }
                let num = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
                let dest = folder.appendingPathComponent("\(base) \(num)").appendingPathExtension(format.fileExtension)
                try ImageKit.write(img, to: dest, as: format, quality: options.jpegQuality)
                outs.append(dest)
            }
            return [folder]
        case .txt:
            let dest = options.outputURL(for: url, ext: "txt")
            var pages: [String] = []
            for i in 0..<doc.pageCount { pages.append(try pageText(doc.page(at: i)!)) }
            let text = pages.joined(separator: "\n\n\u{0C}\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw DropWheelError("No text was found in this PDF.") }
            try text.write(to: dest, atomically: true, encoding: .utf8)
            return [dest]
        case .docx:
            let dest = options.outputURL(for: url, ext: "docx")
            var builder = DocxBuilder()
            for i in 0..<doc.pageCount {
                let page = doc.page(at: i)!
                if i > 0 { builder.add(.pageBreak) }
                let text = try pageText(page)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let img = DocumentKit.render(page, dpi: 150) {
                        builder.add(.image(png: try ImageKit.encode(img, as: .png), pixelWidth: img.width, pixelHeight: img.height))
                    }
                } else {
                    for p in paragraphs(from: text) { builder.add(.paragraph(p)) }
                }
            }
            try builder.data().write(to: dest, options: .atomic)
            return [dest]
        default:
            throw DropWheelError("PDFs can't be converted to \(format.label).")
        }
    }

    /// Text of a page; scanned pages (no text layer) are read with OCR.
    static func pageText(_ page: PDFPage) throws -> String {
        let text = page.string ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        guard let img = DocumentKit.render(page, dpi: 200) else { return "" }
        return try OCR.text(in: img)
    }

    /// Splits text into paragraphs on blank lines; single line breaks are kept inside a paragraph.
    static func paragraphs(from text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Documents and text

    @MainActor
    static func convertDocument(_ url: URL, to format: OutputFormat, options: OutputOptions) throws -> URL {
        let attr = try DocumentKit.attributedString(from: url)
        let dest = options.outputURL(for: url, ext: format.fileExtension)
        let range = NSRange(location: 0, length: attr.length)
        switch format {
        case .pdf:
            try DocumentKit.pdfData(from: attr).write(to: dest, options: .atomic)
        case .txt:
            try attr.string.write(to: dest, atomically: true, encoding: .utf8)
        case .rtf:
            let data = try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: dest, options: .atomic)
        case .docx:
            let data = try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: dest, options: .atomic)
        default:
            throw DropWheelError("Documents can't be converted to \(format.label).")
        }
        return dest
    }

    // MARK: Multi-file

    public static func combineImagesToPDF(_ urls: [URL], options: OutputOptions) async throws -> URL {
        let images = urls.filter { FileKind.of($0) == .image }
        guard let first = images.first else { throw DropWheelError("Drop some images to combine.") }
        let dest = OutputOptions.unique(options.folder(for: first), base: "Combined Images", ext: "pdf")
        let data = try await imageTask { try DocumentKit.pdfData(fromImages: images) }
        try data.write(to: dest, options: .atomic)
        return dest
    }

    public static func mergePDFs(_ urls: [URL], options: OutputOptions) throws -> URL {
        let pdfs = urls.filter { FileKind.of($0) == .pdf }
        guard let first = pdfs.first else { throw DropWheelError("Drop some PDFs to merge.") }
        let merged = PDFDocument()
        for url in pdfs {
            let doc = try DocumentKit.openPDF(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let dest = OutputOptions.unique(options.folder(for: first), base: "Merged", ext: "pdf")
        guard merged.write(to: dest) else { throw DropWheelError("Couldn't write the merged PDF.") }
        return dest
    }
}

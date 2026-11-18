import Foundation
import PDFKit

/// The Tools ring for PDFs.
public enum PDFTools {
    public enum CompressLevel: String, CaseIterable, Sendable, Identifiable {
        case balanced = "Balanced", strong = "Strong", extreme = "Smallest"
        public var id: String { rawValue }
        public var detail: String {
            switch self {
            case .balanced: "Re-encodes images. Text stays selectable."
            case .strong: "Pages become 150 dpi images. Text not selectable."
            case .extreme: "Pages become 96 dpi images. Smallest file."
            }
        }
    }

    public static func compress(_ url: URL, level: CompressLevel) throws -> Data {
        let doc = try DocumentKit.openPDF(url)
        switch level {
        case .balanced:
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let ok = doc.write(to: tmp, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            guard ok, let data = try? Data(contentsOf: tmp) else { throw DropWheelError("Couldn't compress this PDF.") }
            return data
        case .strong, .extreme:
            let dpi = level == .strong ? 150.0 : 96.0
            let quality = level == .strong ? 0.6 : 0.45
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw DropWheelError("Couldn't create the PDF.") }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let img = DocumentKit.render(page, dpi: dpi) else { continue }
                let jpeg = try ImageKit.encode(img, as: .jpg, quality: quality)
                guard let provider = CGDataProvider(data: jpeg as CFData),
                      let jimg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { continue }
                var box = CGRect(x: 0, y: 0, width: Double(img.width) * 72 / dpi, height: Double(img.height) * 72 / dpi)
                ctx.beginPage(mediaBox: &box)
                ctx.draw(jimg, in: box)
                ctx.endPage()
            }
            ctx.closePDF()
            return data as Data
        }
    }

    public static func rotate(_ url: URL, by degrees: Int, to dest: URL) throws {
        let doc = try DocumentKit.openPDF(url)
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { page.rotation = ((page.rotation + degrees) % 360 + 360) % 360 }
        }
        guard doc.write(to: dest) else { throw DropWheelError("Couldn't write the rotated PDF.") }
    }

    /// Writes every page as its own PDF into a new folder and returns the folder.
    public static func split(_ url: URL, options: OutputOptions) throws -> URL {
        let doc = try DocumentKit.openPDF(url)
        guard doc.pageCount > 1 else { throw DropWheelError("This PDF only has one page.") }
        let base = url.deletingPathExtension().lastPathComponent
        let folder = OutputOptions.uniqueFolder(options.folder(for: url), base: "\(base) Pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            let num = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            _ = single.write(to: folder.appendingPathComponent("\(base) \(num).pdf"))
        }
        return folder
    }

    public static func protect(_ url: URL, password: String, to dest: URL) throws {
        guard !password.isEmpty else { throw DropWheelError("Enter a password.") }
        let doc = try DocumentKit.openPDF(url)
        let ok = doc.write(to: dest, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password])
        guard ok else { throw DropWheelError("Couldn't write the protected PDF.") }
    }

    // MARK: Metadata

    public static let editableKeys: [(PDFDocumentAttribute, String)] = [
        (.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"),
        (.keywordsAttribute, "Keywords"), (.creatorAttribute, "Creator"), (.producerAttribute, "Producer"),
    ]

    public static func metadata(_ url: URL) throws -> [String: String] {
        let doc = try DocumentKit.openPDF(url)
        let attrs = doc.documentAttributes ?? [:]
        var out: [String: String] = [:]
        for (key, label) in editableKeys {
            if let v = attrs[key] {
                out[label] = (v as? [String])?.joined(separator: ", ") ?? "\(v)"
            }
        }
        let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
        if let d = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date { out["Created"] = fmt.string(from: d) }
        if let d = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date { out["Modified"] = fmt.string(from: d) }
        out["Pages"] = "\(doc.pageCount)"
        out["Size"] = formattedSize(fileSize(url))
        return out
    }

    /// Saves a copy with new metadata. Pass empty strings to clear fields.
    public static func writeMetadata(_ url: URL, values: [String: String], to dest: URL) throws {
        let doc = try DocumentKit.openPDF(url)
        var attrs: [AnyHashable: Any] = [:]
        for (key, label) in editableKeys {
            let v = values[label]?.trimmingCharacters(in: .whitespaces) ?? ""
            if v.isEmpty { continue }
            attrs[key] = key == .keywordsAttribute ? v.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } : v
        }
        doc.documentAttributes = attrs
        guard doc.write(to: dest) else { throw DropWheelError("Couldn't save the PDF.") }
    }
}

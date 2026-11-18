import Foundation
import UniformTypeIdentifiers

/// The broad family a dropped file belongs to. Decides which wheel segments appear.
public enum FileKind: String, Sendable {
    case image, pdf, document, text, video, audio, unsupported

    public static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) else { return .unsupported }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"].contains(ext) { return .document }
        if type.conforms(to: .rtf) || type.conforms(to: .html) { return .document }
        if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || ["md", "markdown", "csv", "json", "log"].contains(ext) {
            return .text
        }
        return .unsupported
    }
}

/// Every format the wheel can convert to.
public enum OutputFormat: String, CaseIterable, Sendable, Identifiable {
    case jpg, png, webp, heic, tiff, gif, bmp, pdf, docx, txt, rtf, mp4, mov, m4a, wav

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }

    public var isMedia: Bool { [.mp4, .mov, .m4a, .wav].contains(self) }

    public var isImage: Bool {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .gif, .bmp: true
        default: false
        }
    }

    /// The UTType identifier ImageIO uses to write this format (nil for formats we encode ourselves).
    var imageIOType: CFString? {
        switch self {
        case .jpg: UTType.jpeg.identifier as CFString
        case .png: UTType.png.identifier as CFString
        case .heic: UTType.heic.identifier as CFString
        case .tiff: UTType.tiff.identifier as CFString
        case .gif: UTType.gif.identifier as CFString
        case .bmp: UTType.bmp.identifier as CFString
        default: nil
        }
    }

    var supportsAlpha: Bool { ![.jpg, .bmp].contains(self) }

    /// Which output format a file "is", so the wheel can hide converting a file to itself.
    public static func matching(_ url: URL) -> OutputFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe": .jpg
        case "png": .png
        case "webp": .webp
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        case "gif": .gif
        case "bmp": .bmp
        case "pdf": .pdf
        case "docx": .docx
        case "txt": .txt
        case "rtf": .rtf
        case "mp4", "m4v": .mp4
        case "mov", "qt": .mov
        case "m4a": .m4a
        case "wav", "wave": .wav
        default: nil
        }
    }

    /// Conversion targets offered for a file, in the clockwise order the wheel draws them (first = top).
    public static func targets(for url: URL) -> [OutputFormat] {
        let own = matching(url)
        let list: [OutputFormat]
        switch FileKind.of(url) {
        case .image: list = [.png, .jpg, .webp, .heic, .tiff, .gif, .bmp, .pdf, .docx, .txt]
        case .pdf: list = [.docx, .jpg, .png, .txt]
        case .document: list = [.pdf, .docx, .txt, .rtf]
        case .text: list = [.pdf, .docx, .rtf]
        case .video: list = [.mp4, .mov, .gif, .m4a, .wav]
        case .audio: list = [.m4a, .wav]
        case .unsupported: list = []
        }
        // An image never needs to become itself, but a JPG wheel should still show 9 useful targets.
        return list.filter { $0 != own }
    }
}

/// Errors surfaced to the user in the centre of the wheel or in an editor.
public struct DropWheelError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Where results get written.
public struct OutputOptions: Sendable {
    public enum Location: String, Sendable, CaseIterable { case sameFolder, desktop, downloads }
    public var location: Location = .sameFolder
    public var jpegQuality: Double = 0.9
    public var pdfRenderDPI: Double = 300
    public init(location: Location = .sameFolder, jpegQuality: Double = 0.9, pdfRenderDPI: Double = 300) {
        self.location = location
        self.jpegQuality = jpegQuality
        self.pdfRenderDPI = pdfRenderDPI
    }

    public func folder(for source: URL) -> URL {
        let fm = FileManager.default
        switch location {
        case .sameFolder:
            let dir = source.deletingLastPathComponent()
            return fm.isWritableFile(atPath: dir.path) ? dir : fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
    }

    /// "Page 001.pdf" + suffix "Cropped" + ext "jpg" -> "Page 001 Cropped.jpg", never overwriting.
    public func outputURL(for source: URL, suffix: String? = nil, ext: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent + (suffix.map { " \($0)" } ?? "")
        return Self.unique(folder(for: source), base: base, ext: ext)
    }

    public static func unique(_ folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    public static func uniqueFolder(_ folder: URL, base: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}

public func formattedSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

public func fileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
}

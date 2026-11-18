import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Small wrapper so CGImages can cross actor boundaries explicitly. CGImage is immutable.
public struct SendableImage: @unchecked Sendable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }
}

public enum ImageKit {
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Loads the first frame of an image with its EXIF orientation applied.
    public static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw DropWheelError("Couldn't read \(url.lastPathComponent) as an image.")
        }
        return try load(src)
    }

    public static func load(data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            throw DropWheelError("Couldn't decode image data.")
        }
        return try load(src)
    }

    static func load(_ src: CGImageSource) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        if orientation != 1, max(w, h) > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
        }
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw DropWheelError("Couldn't decode the image.")
        }
        return img
    }

    /// A downscaled copy for fast on-screen previews.
    public static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let s = Double(maxPixel) / Double(longest)
        let w = max(1, Int((Double(image.width) * s).rounded())), h = max(1, Int((Double(image.height) * s).rounded()))
        guard let ctx = makeContext(width: w, height: h) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    public static func makeContext(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)
    }

    /// Composites onto white for formats with no alpha channel (otherwise transparent areas turn black).
    public static func flattened(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        guard let ctx = makeContext(width: image.width, height: image.height, opaque: true) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(background)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Encodes an image to bytes in any supported output format.
    public static func encode(_ image: CGImage, as format: OutputFormat, quality: Double = 0.9,
                              properties: [CFString: Any]? = nil) throws -> Data {
        if format == .webp { return try WebPEncoder.encode(image) }
        guard let type = format.imageIOType else { throw DropWheelError("\(format.label) is not an image format.") }
        let img = format.supportsAlpha ? image : flattened(image)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw DropWheelError("This Mac can't write \(format.label) files.")
        }
        var props = properties ?? [:]
        if [.jpg, .heic].contains(format) { props[kCGImageDestinationLossyCompressionQuality] = quality }
        props[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DropWheelError("Failed to encode \(format.label).") }
        return data as Data
    }

    public static func write(_ image: CGImage, to url: URL, as format: OutputFormat, quality: Double = 0.9) throws {
        try encode(image, as: format, quality: quality).write(to: url, options: .atomic)
    }

    /// The format to save an edited image in: keep the original format when we can write it.
    public static func saveFormat(for source: URL, needsAlpha: Bool = false) -> OutputFormat {
        if let f = OutputFormat.matching(source), f.isImage {
            if needsAlpha && !f.supportsAlpha { return .png }
            return f
        }
        return .png
    }

    // MARK: Metadata

    public struct MetadataEntry: Identifiable, Sendable, Hashable {
        public let id = UUID()
        public let group: String
        public let key: String
        public let value: String
    }

    public static func metadata(_ url: URL) -> [MetadataEntry] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [] }
        var out: [MetadataEntry] = []
        out.append(.init(group: "File", key: "Name", value: url.lastPathComponent))
        out.append(.init(group: "File", key: "Size", value: formattedSize(fileSize(url))))
        if let type = CGImageSourceGetType(src) as String?, let ut = UTType(type) {
            out.append(.init(group: "File", key: "Type", value: ut.localizedDescription ?? type))
        }
        func flat(_ dict: [String: Any], group: String) {
            for key in dict.keys.sorted() {
                let v = dict[key]!
                if let sub = v as? [String: Any] {
                    flat(sub, group: prettyGroup(key))
                } else {
                    out.append(.init(group: group, key: prettyKey(key), value: describe(v)))
                }
            }
        }
        flat(props, group: "Image")
        return out
    }

    public static func hasLocation(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return props[kCGImagePropertyGPSDictionary] != nil
    }

    /// Copies the image without re-encoding pixels, dropping location only or every metadata field.
    public static func stripMetadata(_ url: URL, to out: URL, locationOnly: Bool) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw DropWheelError("Couldn't read the image.")
        }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
            throw DropWheelError("Couldn't create the output file.")
        }
        var opts: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if locationOnly, let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
           let mutable = CGImageMetadataCreateMutableCopy(meta) {
            // Keep everything except GPS tags (they live in the exif namespace as GPS*).
            var gpsPaths: [String] = []
            CGImageMetadataEnumerateTagsUsingBlock(meta, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
                let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
                if name.hasPrefix("GPS") || prefix == "GPS" { gpsPaths.append(path as String) }
                return true
            }
            for path in gpsPaths { CGImageMetadataRemoveTagWithPath(mutable, nil, path as CFString) }
            opts[kCGImageDestinationMetadata] = mutable
            opts[kCGImageDestinationMergeMetadata] = false
        }
        if !locationOnly {
            opts[kCGImageDestinationMetadata] = CGImageMetadataCreateMutable()
            opts[kCGImageDestinationMergeMetadata] = false
            opts[kCGImageMetadataShouldExcludeXMP] = true
        }
        var err: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) {
            // Some formats can't be copied losslessly; fall back to a re-encode without properties.
            let img = try load(url)
            let format = saveFormat(for: url)
            var keep: [CFString: Any] = [:]
            if locationOnly, let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                keep = props
                keep[kCGImagePropertyGPSDictionary] = nil
            }
            try encode(img, as: format, quality: 0.95, properties: keep).write(to: out, options: .atomic)
        }
        // CGImageDestinationCopyImageSource finalizes the destination itself.
    }

    private static func prettyGroup(_ key: String) -> String {
        key.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }

    private static func prettyKey(_ key: String) -> String {
        var out = ""
        for (i, ch) in key.enumerated() {
            if i > 0, ch.isUppercase, let prev = out.last, prev.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    private static func describe(_ v: Any) -> String {
        if let a = v as? [Any] { return a.map { describe($0) }.joined(separator: ", ") }
        if let n = v as? NSNumber { return n.stringValue }
        return "\(v)"
    }
}

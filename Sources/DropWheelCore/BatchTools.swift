import Foundation
import CoreGraphics
import CoreImage
import Vision

// MARK: - Background removal

public extension ImageTools {
    /// Cuts the subject(s) out of a photo using on-device Vision. Returns an image with a transparent background.
    static func removeBackground(_ image: CGImage, cropToSubject: Bool = false) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch {
            throw DropWheelError("Background removal isn't available: \(error.localizedDescription)")
        }
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw DropWheelError("No subject was found in this image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: cropToSubject)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImageKit.sRGB) else {
            throw DropWheelError("Couldn't build the cut-out image.")
        }
        return out
    }
}

// MARK: - Resize

public enum ResizeMode: String, CaseIterable, Sendable, Identifiable {
    case longest = "Longest side", width = "Width", height = "Height", percent = "Percent"
    public var id: String { rawValue }
}

public extension ImageTools {
    /// Target pixel size for a resize. Never upscales beyond 4× and never below 1px.
    static func resizedSize(_ size: CGSize, mode: ResizeMode, value: Double) -> CGSize {
        let w = size.width, h = size.height
        let s: Double
        switch mode {
        case .longest: s = value / max(w, h)
        case .width: s = value / w
        case .height: s = value / h
        case .percent: s = value / 100
        }
        let k = min(max(s, 0.0001), 4)
        return CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
    }

    static func resize(_ image: CGImage, mode: ResizeMode, value: Double) -> CGImage {
        let target = resizedSize(image.size, mode: mode, value: value)
        guard let ctx = ImageKit.makeContext(width: Int(target.width), height: Int(target.height)) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: target))
        return ctx.makeImage() ?? image
    }
}

public extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }
}

// MARK: - Rename

public enum Renamer {
    public struct Item: Sendable, Identifiable, Hashable {
        public var id: URL { from }
        public let from: URL
        public let to: URL
        public init(from: URL, to: URL) { self.from = from; self.to = to }
    }

    /// Tokens: {name} original name, {n} counter, {date} file date (yyyy-MM-dd), {ext} extension.
    /// The original extension is always kept.
    public static func plan(_ urls: [URL], pattern: String, start: Int = 1, padding: Int = 3) -> [Item] {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return urls.enumerated().map { i, url in
            let ext = url.pathExtension
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let num = String(start + i)
            let padded = String(repeating: "0", count: max(0, padding - num.count)) + num
            var name = pattern
                .replacingOccurrences(of: "{name}", with: url.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "{n}", with: padded)
                .replacingOccurrences(of: "{date}", with: fmt.string(from: date))
                .replacingOccurrences(of: "{ext}", with: ext)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Untitled \(padded)" }
            let to = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(ext)
            return Item(from: url, to: to)
        }
    }

    /// Problems that would make the rename unsafe; empty means it can run.
    public static func problems(_ plan: [Item]) -> [String] {
        var out: [String] = []
        let targets = plan.map { $0.to.path.lowercased() }
        if Set(targets).count != targets.count { out.append("Two files would get the same name. Add {n} to the pattern.") }
        let sources = Set(plan.map { $0.from.path.lowercased() })
        for item in plan where item.from != item.to {
            if FileManager.default.fileExists(atPath: item.to.path) && !sources.contains(item.to.path.lowercased()) {
                out.append("\(item.to.lastPathComponent) already exists.")
            }
        }
        return out
    }

    /// Renames in two passes (via temporary names) so swaps like a→b, b→a work. Returns the undo plan.
    @discardableResult
    public static func apply(_ plan: [Item]) throws -> [Item] {
        let issues = problems(plan)
        guard issues.isEmpty else { throw DropWheelError(issues[0]) }
        let fm = FileManager.default
        let moving = plan.filter { $0.from != $0.to }
        var temps: [(URL, URL)] = []
        for item in moving {
            let tmp = item.from.deletingLastPathComponent().appendingPathComponent(".dropwheel-\(UUID().uuidString)")
            try fm.moveItem(at: item.from, to: tmp)
            temps.append((tmp, item.to))
        }
        for (tmp, to) in temps { try fm.moveItem(at: tmp, to: to) }
        return moving.map { Item(from: $0.to, to: $0.from) }
    }
}

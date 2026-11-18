import Foundation
import CoreGraphics
import CoreImage
import CoreText

/// Pure image operations behind the Tools ring. All rects are in image pixels with a top-left origin.
public enum ImageTools {
    // MARK: Crop

    public static func crop(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 1, r.height >= 1, let out = image.cropping(to: r) else {
            throw DropWheelError("The crop area is empty.")
        }
        return out
    }

    // MARK: Compress

    public struct CompressSettings: Sendable, Equatable {
        public var quality: Double = 0.7
        public var maxPixel: Int? = nil
        public var format: OutputFormat = .jpg
        public init(quality: Double = 0.7, maxPixel: Int? = nil, format: OutputFormat = .jpg) {
            self.quality = quality; self.maxPixel = maxPixel; self.format = format
        }
    }

    public static func compress(_ image: CGImage, _ s: CompressSettings) throws -> Data {
        let img = s.maxPixel.map { ImageKit.scaled(image, maxPixel: $0) } ?? image
        return try ImageKit.encode(img, as: s.format, quality: s.quality)
    }

    // MARK: Adjustments

    public enum Look: String, CaseIterable, Sendable, Identifiable {
        case none = "Original", vivid = "Vivid", mono = "Mono", noir = "Noir", chrome = "Chrome",
             fade = "Fade", instant = "Instant", process = "Process", transfer = "Transfer"
        public var id: String { rawValue }
        var filterName: String? {
            switch self {
            case .none, .vivid: nil
            case .mono: "CIPhotoEffectMono"
            case .noir: "CIPhotoEffectNoir"
            case .chrome: "CIPhotoEffectChrome"
            case .fade: "CIPhotoEffectFade"
            case .instant: "CIPhotoEffectInstant"
            case .process: "CIPhotoEffectProcess"
            case .transfer: "CIPhotoEffectTransfer"
            }
        }
    }

    public struct Adjustments: Sendable, Equatable {
        public var exposure: Double = 0      // EV, -2...2
        public var brightness: Double = 0    // -0.5...0.5
        public var contrast: Double = 1      // 0.5...1.5
        public var saturation: Double = 1    // 0...2
        public var warmth: Double = 0        // -1...1
        public var highlights: Double = 1    // 0...1
        public var shadows: Double = 0       // -1...1
        public var sharpness: Double = 0     // 0...2
        public var vignette: Double = 0      // 0...2
        public var rotation: Int = 0         // quarter turns clockwise
        public var flipH = false
        public var flipV = false
        public var look: Look = .none
        public init() {}
        public var isIdentity: Bool { self == Adjustments() }
    }

    nonisolated(unsafe) static let ciContext = CIContext(options: [.workingColorSpace: ImageKit.sRGB, .cacheIntermediates: false])

    public static func adjust(_ image: CGImage, _ a: Adjustments) -> CGImage {
        var ci = CIImage(cgImage: image)
        let extent = ci.extent
        if let name = a.look.filterName, let f = CIFilter(name: name) {
            f.setValue(ci, forKey: kCIInputImageKey); ci = f.outputImage ?? ci
        }
        if a.look == .vivid, let f = CIFilter(name: "CIVibrance") {
            f.setValue(ci, forKey: kCIInputImageKey); f.setValue(0.8, forKey: "inputAmount"); ci = f.outputImage ?? ci
        }
        if a.exposure != 0, let f = CIFilter(name: "CIExposureAdjust") {
            f.setValue(ci, forKey: kCIInputImageKey); f.setValue(a.exposure, forKey: kCIInputEVKey); ci = f.outputImage ?? ci
        }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1, let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(a.brightness, forKey: kCIInputBrightnessKey)
            f.setValue(a.contrast, forKey: kCIInputContrastKey)
            f.setValue(a.saturation, forKey: kCIInputSaturationKey)
            ci = f.outputImage ?? ci
        }
        if a.warmth != 0, let f = CIFilter(name: "CITemperatureAndTint") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500 - a.warmth * 2500, y: 0), forKey: "inputTargetNeutral")
            ci = f.outputImage ?? ci
        }
        if a.highlights != 1 || a.shadows != 0, let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(a.highlights, forKey: "inputHighlightAmount")
            f.setValue(a.shadows, forKey: "inputShadowAmount")
            ci = f.outputImage ?? ci
        }
        if a.sharpness > 0, let f = CIFilter(name: "CISharpenLuminance") {
            f.setValue(ci, forKey: kCIInputImageKey); f.setValue(a.sharpness, forKey: kCIInputSharpnessKey); ci = f.outputImage ?? ci
        }
        if a.vignette > 0, let f = CIFilter(name: "CIVignette") {
            f.setValue(ci, forKey: kCIInputImageKey); f.setValue(a.vignette, forKey: kCIInputIntensityKey)
            f.setValue(1.5, forKey: kCIInputRadiusKey); ci = f.outputImage ?? ci
        }
        ci = ci.cropped(to: extent)
        guard var out = ciContext.createCGImage(ci, from: extent, format: .RGBA8, colorSpace: ImageKit.sRGB) else { return image }
        out = transform(out, rotation: a.rotation, flipH: a.flipH, flipV: a.flipV)
        return out
    }

    public static func transform(_ image: CGImage, rotation: Int, flipH: Bool, flipV: Bool) -> CGImage {
        let turns = ((rotation % 4) + 4) % 4
        guard turns != 0 || flipH || flipV else { return image }
        let w = image.width, h = image.height
        let (ow, oh) = turns % 2 == 0 ? (w, h) : (h, w)
        guard let ctx = ImageKit.makeContext(width: ow, height: oh) else { return image }
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        if flipH { ctx.scaleBy(x: -1, y: 1) }
        if flipV { ctx.scaleBy(x: 1, y: -1) }
        ctx.rotate(by: -CGFloat(turns) * .pi / 2) // CG is y-up, so negative = clockwise on screen
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? image
    }

    // MARK: Background

    public struct RGBA: Sendable, Equatable, Hashable {
        public var r, g, b, a: Double
        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
        public init(hex: UInt32) {
            self.init(Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255)
        }
        public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    }

    /// A soft "mesh-like" gradient: a base linear gradient with coloured glows on top.
    public struct GradientPreset: Sendable, Equatable, Hashable, Identifiable {
        public let id: String
        public let base: [RGBA]
        public let glows: [Glow]
        public struct Glow: Sendable, Equatable, Hashable {
            public let color: RGBA; public let x: Double; public let y: Double; public let radius: Double
        }
    }

    public static let gradients: [GradientPreset] = [
        .init(id: "Sunset", base: [.init(hex: 0xFF4E50), .init(hex: 0xF9A03F)], glows: [
            .init(color: .init(hex: 0xFFD23F), x: 0.85, y: 0.1, radius: 0.6),
            .init(color: .init(hex: 0x8E6CF0), x: 0.9, y: 0.95, radius: 0.55),
            .init(color: .init(hex: 0xFF2E7E), x: 0.05, y: 0.55, radius: 0.5)]),
        .init(id: "Frost", base: [.init(hex: 0xFFFFFF), .init(hex: 0xE3ECF7)], glows: [
            .init(color: .init(hex: 0xB9D3F5), x: 0.2, y: 0.2, radius: 0.6),
            .init(color: .init(hex: 0xF5D0E6), x: 0.9, y: 0.8, radius: 0.5)]),
        .init(id: "Prism", base: [.init(hex: 0xF7D06B), .init(hex: 0x6BD6C9)], glows: [
            .init(color: .init(hex: 0xF27BBD), x: 0.15, y: 0.85, radius: 0.55),
            .init(color: .init(hex: 0x7B8CF2), x: 0.85, y: 0.15, radius: 0.55)]),
        .init(id: "Pearl", base: [.init(hex: 0xFBF7F4), .init(hex: 0xEAE2EC)], glows: [
            .init(color: .init(hex: 0xF3D9C9), x: 0.8, y: 0.2, radius: 0.6),
            .init(color: .init(hex: 0xD9E3F3), x: 0.1, y: 0.9, radius: 0.6)]),
        .init(id: "Lilac", base: [.init(hex: 0xE7C6F0), .init(hex: 0xF6D5E5)], glows: [
            .init(color: .init(hex: 0xB59BF5), x: 0.2, y: 0.8, radius: 0.6),
            .init(color: .init(hex: 0xFFE3F1), x: 0.85, y: 0.15, radius: 0.5)]),
        .init(id: "Ember", base: [.init(hex: 0x1F6E5C), .init(hex: 0xD9412B)], glows: [
            .init(color: .init(hex: 0xF2B035), x: 0.75, y: 0.25, radius: 0.5),
            .init(color: .init(hex: 0x2B2F6B), x: 0.15, y: 0.9, radius: 0.55)]),
        .init(id: "Ocean", base: [.init(hex: 0x6FA8F7), .init(hex: 0x3D5AF1)], glows: [
            .init(color: .init(hex: 0xA6F0FF), x: 0.15, y: 0.15, radius: 0.6),
            .init(color: .init(hex: 0x9C6CF2), x: 0.9, y: 0.9, radius: 0.5)]),
        .init(id: "Lagoon", base: [.init(hex: 0x2EC5CE), .init(hex: 0x6EE2F5)], glows: [
            .init(color: .init(hex: 0x1F8FE0), x: 0.85, y: 0.85, radius: 0.6),
            .init(color: .init(hex: 0xC9FFF2), x: 0.1, y: 0.1, radius: 0.5)]),
        .init(id: "Cloud", base: [.init(hex: 0xEEF1FF), .init(hex: 0xD5DAF7)], glows: [
            .init(color: .init(hex: 0xFFFFFF), x: 0.3, y: 0.3, radius: 0.6),
            .init(color: .init(hex: 0xC7B8F5), x: 0.9, y: 0.8, radius: 0.5)]),
    ]

    public static let solidColors: [RGBA] = [
        .init(hex: 0xFFFFFF), .init(hex: 0xF5C542), .init(hex: 0x8BCB3A), .init(hex: 0x2E9E5B), .init(hex: 0x1E9E8F),
        .init(hex: 0x4CC3D9), .init(hex: 0x2F5BEA), .init(hex: 0x1F2A44), .init(hex: 0x7B3FE4),
    ]

    public enum Background: Sendable, Equatable {
        case gradient(GradientPreset)
        case solid(RGBA)
        case image(SendableImage)
        public static func == (l: Background, r: Background) -> Bool {
            switch (l, r) {
            case (.gradient(let a), .gradient(let b)): a == b
            case (.solid(let a), .solid(let b)): a == b
            case (.image(let a), .image(let b)): a.cgImage === b.cgImage
            default: false
            }
        }
    }

    public enum Ratio: String, CaseIterable, Sendable, Identifiable {
        case auto = "Auto", square = "1:1", wide = "16:9", portrait = "4:5"
        public var id: String { rawValue }
        var value: Double? {
            switch self { case .auto: nil; case .square: 1; case .wide: 16.0 / 9; case .portrait: 4.0 / 5 }
        }
    }

    public struct BackgroundSettings: Sendable, Equatable {
        public var background: Background = .gradient(ImageTools.gradients[0])
        public var padding: Double = 160
        public var corners: Double = 48
        public var shadow: Double = 24
        public var ratio: Ratio = .auto
        public init() {}
    }

    /// Places the image on a background with padding, rounded corners and a drop shadow.
    /// `scale` lets previews render a smaller copy with identical proportions.
    public static func addBackground(_ image: CGImage, _ s: BackgroundSettings, scale: Double = 1) -> CGImage? {
        let iw = Double(image.width) * scale, ih = Double(image.height) * scale
        let pad = s.padding * scale
        var W = iw + pad * 2, H = ih + pad * 2
        if let r = s.ratio.value {
            if W / H > r { H = W / r } else { W = H * r }
        }
        let w = max(1, Int(W.rounded())), h = max(1, Int(H.rounded()))
        guard let ctx = ImageKit.makeContext(width: w, height: h) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        drawBackground(s.background, in: ctx, rect: full)

        let rect = CGRect(x: (Double(w) - iw) / 2, y: (Double(h) - ih) / 2, width: iw, height: ih)
        let radius = min(s.corners * scale, min(iw, ih) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if s.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -s.shadow * scale * 0.4), blur: s.shadow * scale * 1.5,
                          color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    public static func drawBackground(_ bg: Background, in ctx: CGContext, rect: CGRect) {
        switch bg {
        case .solid(let c):
            ctx.setFillColor(c.cgColor); ctx.fill(rect)
        case .image(let img):
            // Aspect-fill.
            let iw = CGFloat(img.cgImage.width), ih = CGFloat(img.cgImage.height)
            let s = max(rect.width / iw, rect.height / ih)
            let dw = iw * s, dh = ih * s
            ctx.saveGState(); ctx.clip(to: rect)
            ctx.draw(img.cgImage, in: CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh))
            ctx.restoreGState()
        case .gradient(let g):
            let colors = g.base.map(\.cgColor) as CFArray
            if let lin = CGGradient(colorsSpace: ImageKit.sRGB, colors: colors, locations: nil) {
                ctx.drawLinearGradient(lin, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
            }
            let longest = max(rect.width, rect.height)
            for glow in g.glows {
                var clear = glow.color; clear.a = 0
                guard let rad = CGGradient(colorsSpace: ImageKit.sRGB, colors: [glow.color.cgColor, clear.cgColor] as CFArray,
                                           locations: [0, 1]) else { continue }
                // Glow coords are top-left based; CG is bottom-left.
                let c = CGPoint(x: rect.minX + glow.x * rect.width, y: rect.maxY - glow.y * rect.height)
                ctx.drawRadialGradient(rad, startCenter: c, startRadius: 0, endCenter: c, endRadius: glow.radius * longest, options: [])
            }
        }
    }

    // MARK: Annotations

    public enum ShapeKind: String, Sendable, CaseIterable { case pen, highlighter, arrow, rectangle, ellipse, text }

    public struct Annotation: Sendable, Identifiable, Equatable {
        public var id = UUID()
        public var kind: ShapeKind
        public var points: [CGPoint]          // image pixels, top-left origin
        public var color: RGBA
        public var lineWidth: Double
        public var text: String = ""
        public init(kind: ShapeKind, points: [CGPoint], color: RGBA, lineWidth: Double, text: String = "") {
            self.kind = kind; self.points = points; self.color = color; self.lineWidth = lineWidth; self.text = text
        }
    }

    /// Draws annotations into a context whose coordinates are image pixels with a top-left origin.
    public static func draw(_ items: [Annotation], in ctx: CGContext) {
        for a in items {
            guard let first = a.points.first else { continue }
            let last = a.points.last ?? first
            ctx.saveGState()
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.setLineWidth(a.lineWidth)
            var color = a.color
            if a.kind == .highlighter { color.a = 0.4; ctx.setLineWidth(a.lineWidth * 3); ctx.setLineCap(.butt) }
            ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor)
            switch a.kind {
            case .pen, .highlighter:
                ctx.move(to: first)
                for p in a.points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            case .rectangle:
                ctx.stroke(rect(first, last))
            case .ellipse:
                ctx.strokeEllipse(in: rect(first, last))
            case .arrow:
                ctx.move(to: first); ctx.addLine(to: last); ctx.strokePath()
                let angle = atan2(last.y - first.y, last.x - first.x)
                let head = max(14, a.lineWidth * 4)
                ctx.move(to: last)
                ctx.addLine(to: CGPoint(x: last.x - head * cos(angle - .pi / 7), y: last.y - head * sin(angle - .pi / 7)))
                ctx.addLine(to: CGPoint(x: last.x - head * cos(angle + .pi / 7), y: last.y - head * sin(angle + .pi / 7)))
                ctx.closePath(); ctx.fillPath()
            case .text:
                drawText(a.text, at: first, size: max(12, a.lineWidth * 6), color: a.color.cgColor, in: ctx)
            }
            ctx.restoreGState()
        }
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func drawText(_ text: String, at p: CGPoint, size: Double, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        // Context is flipped (y down); flip text back so it reads upright.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: p.x, y: p.y + size)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    public static func render(_ image: CGImage, annotations: [Annotation]) -> CGImage? {
        guard let ctx = flippedContext(for: image) else { return nil }
        draw(annotations, in: ctx)
        return ctx.makeImage()
    }

    /// A context with the image drawn in and coordinates flipped to top-left origin.
    static func flippedContext(for image: CGImage) -> CGContext? {
        guard let ctx = ImageKit.makeContext(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    // MARK: Redact

    public enum RedactStyle: String, CaseIterable, Sendable, Identifiable {
        case box = "Black box", pixelate = "Pixelate", blur = "Blur"
        public var id: String { rawValue }
    }

    public static func redact(_ image: CGImage, rects: [CGRect], style: RedactStyle) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var source: CGImage?
        switch style {
        case .box: source = nil
        case .pixelate:
            let ci = CIImage(cgImage: image).clampedToExtent()
            let f = CIFilter(name: "CIPixellate")!
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(max(12, Double(max(image.width, image.height)) / 60), forKey: kCIInputScaleKey)
            source = f.outputImage.flatMap { ciContext.createCGImage($0.cropped(to: bounds), from: bounds) }
        case .blur:
            let ci = CIImage(cgImage: image).clampedToExtent()
            let f = CIFilter(name: "CIGaussianBlur")!
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(max(18, Double(max(image.width, image.height)) / 40), forKey: kCIInputRadiusKey)
            source = f.outputImage.flatMap { ciContext.createCGImage($0.cropped(to: bounds), from: bounds) }
        }
        guard let ctx = ImageKit.makeContext(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: bounds)
        for r in rects {
            // Convert top-left rect to CG's bottom-left space.
            let cg = CGRect(x: r.minX, y: CGFloat(image.height) - r.maxY, width: r.width, height: r.height).intersection(bounds)
            guard !cg.isNull else { continue }
            if let source {
                ctx.saveGState(); ctx.clip(to: cg); ctx.draw(source, in: bounds); ctx.restoreGState()
            } else {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(cg)
            }
        }
        return ctx.makeImage()
    }
}

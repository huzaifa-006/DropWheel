import SwiftUI
import UniformTypeIdentifiers
import DropWheelCore

/// Fitted preview of a CGImage with an optional overlay in view coordinates.
struct FittedImage<Overlay: View>: View {
    let image: CGImage
    var logicalSize: CGSize? = nil
    @ViewBuilder var overlay: (ImageFit) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let fit = ImageFit(imageSize: logicalSize ?? image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: fit.rect.width, height: fit.rect.height)
                    .offset(x: fit.rect.minX, y: fit.rect.minY)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                overlay(fit)
            }
        }
        .background(Color.black.opacity(0.06))
    }
}

extension FittedImage where Overlay == EmptyView {
    init(image: CGImage) { self.init(image: image, overlay: { _ in EmptyView() }) }
}

// MARK: - Edit (adjustments)

struct AdjustEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void
    private let small: SendableImage
    @State private var a = ImageTools.Adjustments()
    @State private var preview: CGImage?
    @State private var thumbs: [ImageTools.Look: CGImage] = [:]
    @State private var working = false
    @State private var message: String?

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url; self.image = image; self.close = close
        small = SendableImage(ImageKit.scaled(image, maxPixel: 1400))
    }

    var body: some View {
        VStack(spacing: 0) {
            FittedImage(image: preview ?? small.cgImage)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ImageTools.Look.allCases) { look in
                        Button { a.look = look } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if let t = thumbs[look] { Image(decorative: t, scale: 1).resizable().scaledToFill() }
                                    else { Color.white.opacity(0.3) }
                                }
                                .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(a.look == look ? Theme.accent : .clear, lineWidth: 3))
                                Text(look.rawValue).font(.caption2)
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16).padding(.top, 12)
            }
            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 6) {
                        LabeledSlider(title: "Exposure", value: $a.exposure, range: -2...2, format: { String(format: "%+.1f", $0) })
                        LabeledSlider(title: "Brightness", value: $a.brightness, range: -0.5...0.5, format: pct)
                        LabeledSlider(title: "Contrast", value: $a.contrast, range: 0.5...1.5, format: { pct($0 - 1) })
                        LabeledSlider(title: "Saturation", value: $a.saturation, range: 0...2, format: { pct($0 - 1) })
                    }
                    VStack(spacing: 6) {
                        LabeledSlider(title: "Warmth", value: $a.warmth, range: -1...1, format: pct)
                        LabeledSlider(title: "Shadows", value: $a.shadows, range: -1...1, format: pct)
                        LabeledSlider(title: "Sharpness", value: $a.sharpness, range: 0...2, format: { pct($0 / 2) })
                        LabeledSlider(title: "Vignette", value: $a.vignette, range: 0...2, format: { pct($0 / 2) })
                    }
                }
                HStack(spacing: 8) {
                    Button { a.rotation -= 1 } label: { Label("Rotate Left", systemImage: "rotate.left") }
                    Button { a.rotation += 1 } label: { Label("Rotate Right", systemImage: "rotate.right") }
                    Button { a.flipH.toggle() } label: { Label("Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Button { a.flipV.toggle() } label: { Label("Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    Spacer()
                }
                .buttonStyle(SoftButton())
                .padding(.top, 4)
            }
            .padding(16)
            EditorFooter(resetEnabled: !a.isIdentity, reset: { a = .init() }, primary: "Save", working: working, message: message) {
                Task { await save() }
            }
        }
        .task(id: a) {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let adj = a, src = small
            let out = await Task.detached { SendableImage(ImageTools.adjust(src.cgImage, adj)) }.value
            if !Task.isCancelled { preview = out.cgImage }
        }
        .task {
            let tiny = SendableImage(ImageKit.scaled(small.cgImage, maxPixel: 160))
            for look in ImageTools.Look.allCases {
                var adj = ImageTools.Adjustments(); adj.look = look
                let t = await Task.detached { SendableImage(ImageTools.adjust(tiny.cgImage, adj)) }.value
                thumbs[look] = t.cgImage
            }
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%+d%%", Int((v * 100).rounded())) }

    private func save() async {
        working = true; defer { working = false }
        do {
            let adj = a, full = SendableImage(image)
            let out = await Task.detached(priority: .userInitiated) { SendableImage(ImageTools.adjust(full.cgImage, adj)) }.value
            let dest = try await saveImage(out.cgImage, source: url, suffix: "Edited")
            finish([dest], message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Annotate

struct AnnotateEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void
    private let preview: CGImage
    @State private var items: [ImageTools.Annotation] = []
    @State private var redo: [ImageTools.Annotation] = []
    @State private var tool: ImageTools.ShapeKind = .arrow
    @State private var color = ImageTools.RGBA(hex: 0xFF3B30)
    @State private var width: Double = 6
    @State private var text = "Note"
    @State private var drawing: ImageTools.Annotation?
    @State private var working = false
    @State private var message: String?

    static let colors: [ImageTools.RGBA] = [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x007AFF, 0xAF52DE, 0x000000, 0xFFFFFF].map { .init(hex: $0) }

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url; self.image = image; self.close = close
        preview = ImageKit.scaled(image, maxPixel: 1600)
        // Stroke widths are in image pixels; start proportional to the image.
        _width = State(initialValue: max(3, Double(max(image.width, image.height)) / 250))
    }

    var body: some View {
        VStack(spacing: 0) {
            FittedImage(image: preview, logicalSize: image.size) { fit in
                Canvas { ctx, _ in
                    ctx.withCGContext { cg in
                        cg.translateBy(x: fit.rect.minX, y: fit.rect.minY)
                        cg.scaleBy(x: fit.scale, y: fit.scale)
                        ImageTools.draw(items + (drawing.map { [$0] } ?? []), in: cg)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let p = fit.toImage(v.location)
                        if drawing == nil {
                            drawing = .init(kind: tool, points: [fit.toImage(v.startLocation)], color: color, lineWidth: width, text: text)
                        }
                        if tool == .pen || tool == .highlighter { drawing?.points.append(p) }
                        else if tool != .text { drawing?.points = [drawing!.points[0], p] }
                    }
                    .onEnded { _ in
                        if let d = drawing, d.kind == .text ? !d.text.isEmpty : d.points.count > 1 { items.append(d); redo = [] }
                        drawing = nil
                    })
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach([(ImageTools.ShapeKind.pen, "pencil"), (.highlighter, "highlighter"), (.arrow, "arrow.up.right"),
                             (.rectangle, "rectangle"), (.ellipse, "circle"), (.text, "textformat")], id: \.0) { kind, symbol in
                        Button { tool = kind } label: {
                            Image(systemName: symbol).frame(width: 30, height: 26)
                                .foregroundStyle(tool == kind ? .white : Theme.ink)
                                .background(RoundedRectangle(cornerRadius: 6).fill(tool == kind ? Theme.accent : .white.opacity(0.3)))
                        }.buttonStyle(.plain).help(kind.rawValue.capitalized)
                    }
                    Divider().frame(height: 22)
                    ForEach(Self.colors, id: \.self) { c in
                        Circle().fill(Color(cgColor: c.cgColor)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(color == c ? Theme.accent : .black.opacity(0.15), lineWidth: color == c ? 3 : 1))
                            .onTapGesture { color = c }
                    }
                    Spacer()
                    Button { if let last = items.popLast() { redo.append(last) } } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(items.isEmpty).keyboardShortcut("z")
                    Button { if let r = redo.popLast() { items.append(r) } } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(redo.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
                }
                HStack {
                    LabeledSlider(title: "Size", value: $width, range: 1...max(40, Double(max(image.width, image.height)) / 60))
                    if tool == .text {
                        TextField("Text to place", text: $text).textFieldStyle(.roundedBorder).frame(width: 200)
                        Text("Click the image to place it").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            EditorFooter(resetEnabled: !items.isEmpty, reset: { items = []; redo = [] }, primary: "Save", primaryEnabled: !items.isEmpty,
                         working: working, message: message) { Task { await save() } }
        }
    }

    private func save() async {
        working = true; defer { working = false }
        guard let out = ImageTools.render(image, annotations: items) else { message = "Couldn't render."; return }
        do {
            let dest = try await saveImage(out, source: url, suffix: "Annotated")
            finish([dest], message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Add background

struct BackgroundEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void
    @State private var s = ImageTools.BackgroundSettings()
    @State private var preview: CGImage?
    @State private var customColor = Color.blue
    @State private var working = false
    @State private var message: String?

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url; self.image = image; self.close = close
        _s = State(initialValue: Self.defaults(for: image))
    }

    /// Defaults proportional to image size so small and huge images both look right.
    static func defaults(for image: CGImage) -> ImageTools.BackgroundSettings {
        var settings = ImageTools.BackgroundSettings()
        let longest = Double(max(image.width, image.height))
        settings.padding = (longest * 0.08).rounded()
        settings.corners = (longest * 0.03).rounded()
        settings.shadow = (longest * 0.012).rounded()
        return settings
    }

    private var maxSide: Double { Double(max(image.width, image.height)) }

    var body: some View {
        VStack(spacing: 0) {
            if let preview { FittedImage(image: preview) } else { Color.clear }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text("Background").frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(ImageTools.gradients) { g in
                                swatch(selected: s.background == .gradient(g)) {
                                    Image(decorative: gradientThumb(g), scale: 1).resizable()
                                }
                                .onTapGesture { s.background = .gradient(g) }
                                .help(g.id)
                            }
                            Button(action: pickImage) {
                                Image(systemName: "photo.badge.plus").frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.3)))
                            }.buttonStyle(.plain).help("Use an image")
                        }
                        HStack(spacing: 8) {
                            ForEach(ImageTools.solidColors, id: \.self) { c in
                                swatch(selected: s.background == .solid(c)) { Color(cgColor: c.cgColor) }
                                    .onTapGesture { s.background = .solid(c) }
                            }
                            ColorPicker("", selection: $customColor, supportsOpacity: false).labelsHidden()
                                .onChange(of: customColor) { _, c in
                                    if let rgb = NSColor(c).usingColorSpace(.sRGB) {
                                        s.background = .solid(.init(rgb.redComponent, rgb.greenComponent, rgb.blueComponent))
                                    }
                                }
                        }
                    }
                }
                LabeledSlider(title: "Padding", value: $s.padding, range: 0...maxSide * 0.5, unit: " px")
                LabeledSlider(title: "Corners", value: $s.corners, range: 0...maxSide * 0.25, unit: " px")
                LabeledSlider(title: "Shadow", value: $s.shadow, range: 0...maxSide * 0.06, unit: " px")
                HStack {
                    Text("Ratio").frame(width: 84, alignment: .leading)
                    Spacer()
                    ChipPicker(options: ImageTools.Ratio.allCases, selection: $s.ratio) { $0.rawValue }
                }
            }
            .padding(16)
            EditorFooter(reset: { s = Self.defaults(for: image) }, primary: "Save with Background",
                         working: working, message: message) { Task { await save() } }
        }
        .task(id: s) {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            let settings = s, src = SendableImage(image)
            // Preview at ~900px on the long edge.
            let scale = min(1, 900 / (Double(max(image.width, image.height)) + settings.padding * 2))
            let out = await Task.detached { ImageTools.addBackground(src.cgImage, settings, scale: scale).map(SendableImage.init) }.value
            if !Task.isCancelled, let out { preview = out.cgImage }
        }
    }

    private func swatch<V: View>(selected: Bool, @ViewBuilder content: () -> V) -> some View {
        content()
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.accent : .black.opacity(0.1), lineWidth: selected ? 3 : 1))
            .contentShape(Rectangle())
    }

    private func gradientThumb(_ g: ImageTools.GradientPreset) -> CGImage {
        let ctx = ImageKit.makeContext(width: 60, height: 60)!
        ImageTools.drawBackground(.gradient(g), in: ctx, rect: CGRect(x: 0, y: 0, width: 60, height: 60))
        return ctx.makeImage()!
    }

    private func pickImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url, let img = try? ImageKit.load(u) {
            s.background = .image(SendableImage(ImageKit.scaled(img, maxPixel: 4000)))
        }
    }

    private func save() async {
        working = true; defer { working = false }
        let settings = s, src = SendableImage(image)
        guard let out = await Task.detached(priority: .userInitiated, operation: {
            ImageTools.addBackground(src.cgImage, settings).map(SendableImage.init)
        }).value else { message = "Couldn't render."; return }
        do {
            let dest = try await saveImage(out.cgImage, source: url, suffix: "With Background", forceAlpha: true)
            finish([dest], message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Redact

struct RedactEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void
    private let small: SendableImage
    @State private var rects: [CGRect] = []
    @State private var drawingRect: CGRect?
    @State private var style: ImageTools.RedactStyle = .box
    @State private var preview: CGImage?
    @State private var detecting = false
    @State private var working = false
    @State private var message: String?

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url; self.image = image; self.close = close
        small = SendableImage(ImageKit.scaled(image, maxPixel: 1400))
    }

    var body: some View {
        VStack(spacing: 0) {
            FittedImage(image: preview ?? small.cgImage, logicalSize: image.size) { fit in
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle())
                    ForEach(Array(rects.enumerated()), id: \.offset) { i, r in
                        let v = fit.toView(r)
                        Rectangle().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                            .frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY)
                            .onTapGesture { rects.remove(at: i) }
                    }
                    if let d = drawingRect {
                        let v = fit.toView(d)
                        Rectangle().fill(.black.opacity(0.6)).frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY)
                    }
                }
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        let a = fit.toImage(v.startLocation), b = fit.toImage(v.location)
                        drawingRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    }
                    .onEnded { _ in
                        if let d = drawingRect, d.width > 3, d.height > 3 { rects.append(d) }
                        drawingRect = nil
                    })
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Find Sensitive Text") { detect(.sensitive) }
                    Button("Find All Text") { detect(.text) }
                    Button("Find Faces") { detect(.faces) }
                    if detecting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { _ = rects.popLast() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(rects.isEmpty)
                }
                .buttonStyle(SoftButton())
                HStack {
                    Text("Style").frame(width: 60, alignment: .leading)
                    ChipPicker(options: ImageTools.RedactStyle.allCases, selection: $style) { $0.rawValue }
                    Spacer()
                    Text("Drag to cover an area · click a box to remove it").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            EditorFooter(resetEnabled: !rects.isEmpty, reset: { rects = [] }, primary: "Save Redacted", primaryEnabled: !rects.isEmpty,
                         working: working, message: message) { Task { await save() } }
        }
        .task(id: RedactKey(rects: rects, style: style)) {
            let k = CGFloat(small.cgImage.width) / CGFloat(image.width)
            let scaled = rects.map { CGRect(x: $0.minX * k, y: $0.minY * k, width: $0.width * k, height: $0.height * k) }
            let st = style, src = small
            let out = await Task.detached { ImageTools.redact(src.cgImage, rects: scaled, style: st).map(SendableImage.init) }.value
            if !Task.isCancelled { preview = out?.cgImage }
        }
    }

    struct RedactKey: Equatable { let rects: [CGRect]; let style: ImageTools.RedactStyle }
    enum Detect { case sensitive, text, faces }

    private func detect(_ kind: Detect) {
        detecting = true
        let src = SendableImage(image)
        Task {
            let found: [CGRect] = await Task.detached {
                switch kind {
                case .faces: return (try? OCR.faces(in: src.cgImage)) ?? []
                case .text: return ((try? OCR.lines(in: src.cgImage)) ?? []).map(\.rect)
                case .sensitive: return ((try? OCR.lines(in: src.cgImage)) ?? []).filter { OCR.isSensitive($0.text) }.map(\.rect)
                }
            }.value
            // Pad boxes slightly so descenders are covered.
            let padded = found.map { $0.insetBy(dx: -$0.height * 0.15, dy: -$0.height * 0.15) }
            rects += padded.filter { !rects.contains($0) }
            message = found.isEmpty ? "Nothing found" : nil
            detecting = false
        }
    }

    private func save() async {
        working = true; defer { working = false }
        let r = rects, st = style, src = SendableImage(image)
        guard let out = await Task.detached(operation: { ImageTools.redact(src.cgImage, rects: r, style: st).map(SendableImage.init) }).value else {
            message = "Couldn't render."; return
        }
        do {
            let dest = try await saveImage(out.cgImage, source: url, suffix: "Redacted")
            finish([dest], message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

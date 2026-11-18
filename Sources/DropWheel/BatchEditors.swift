import SwiftUI
import UniformTypeIdentifiers
import DropWheelCore
import PDFKit

// MARK: - Resize (one or many images)

struct ResizeEditor: View {
    let urls: [URL]
    let close: () -> Void
    @State private var mode: ResizeMode = .longest
    @State private var value: Double = 1920
    @State private var sizes: [URL: CGSize] = [:]
    @State private var working = false
    @State private var message: String?

    private let presets: [Double] = [3840, 2560, 1920, 1280, 1080, 800, 512]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Resize by").frame(width: 84, alignment: .leading)
                    ChipPicker(options: ResizeMode.allCases, selection: $mode) { $0.rawValue }
                    Spacer()
                }
                HStack {
                    Text(mode == .percent ? "Scale" : "Size").frame(width: 84, alignment: .leading)
                    TextField("", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                    Text(mode == .percent ? "%" : "px").foregroundStyle(.secondary)
                    Spacer()
                    if mode != .percent {
                        ForEach(presets.prefix(5), id: \.self) { p in
                            Button("\(Int(p))") { value = p }.buttonStyle(SoftButton())
                        }
                    }
                }
                Divider().opacity(0.4)
                Text(urls.count == 1 ? "Result" : "Results for \(urls.count) images").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(urls, id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let s = sizes[url] {
                                    let t = ImageTools.resizedSize(s, mode: mode, value: value)
                                    Text("\(Int(s.width))×\(Int(s.height))").foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.caption)
                                    Text("\(Int(t.width))×\(Int(t.height))").fontWeight(.semibold)
                                        .foregroundStyle(t.width > s.width ? .orange : Theme.ink)
                                }
                            }.font(.callout).monospacedDigit()
                        }
                    }
                }
            }
            .padding(16)
            EditorFooter(reset: { mode = .longest; value = 1920 }, primary: urls.count > 1 ? "Resize \(urls.count)" : "Resize",
                         primaryEnabled: value > 0, working: working, message: message) { Task { await save() } }
        }
        .onChange(of: mode) { _, m in value = m == .percent ? 50 : 1920 }
        .task {
            for url in urls {
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                   let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
                    let o = p[kCGImagePropertyOrientation] as? Int ?? 1
                    sizes[url] = o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
                }
            }
        }
    }

    private func save() async {
        working = true; defer { working = false }
        var outs: [URL] = []
        let m = mode, v = value
        do {
            for url in urls {
                let format = ImageKit.saveFormat(for: url)
                let dest = AppSettings.output.outputURL(for: url, suffix: "Resized", ext: format.fileExtension)
                try await Task.detached(priority: .userInitiated) {
                    try ImageKit.write(ImageTools.resize(try ImageKit.load(url), mode: m, value: v), to: dest, as: format, quality: 0.92)
                }.value
                outs.append(dest)
            }
            AppSettings.didSave(outs)
            finish(outs, message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Rename (many files)

struct RenameEditor: View {
    let urls: [URL]
    let close: () -> Void
    @State private var current: [URL]
    @State private var pattern = "{name}-{n}"
    @State private var start = 1
    @State private var padding = 3
    @State private var undo: [Renamer.Item]?
    @State private var message: String?

    init(urls: [URL], close: @escaping () -> Void) {
        self.urls = urls; self.close = close
        _current = State(initialValue: urls)
    }

    private var plan: [Renamer.Item] { Renamer.plan(current, pattern: pattern, start: start, padding: padding) }

    var body: some View {
        let plan = plan
        let problems = Renamer.problems(plan)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Pattern").frame(width: 70, alignment: .leading)
                    TextField("e.g. Trip-{n}", text: $pattern).textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 6) {
                    Text("Insert").frame(width: 70, alignment: .leading)
                    ForEach(["{name}", "{n}", "{date}"], id: \.self) { t in
                        Button(t) { pattern += t }.buttonStyle(SoftButton())
                    }
                    Spacer()
                    Stepper("Start at \(start)", value: $start, in: 0...99_999)
                    Stepper("Digits \(padding)", value: $padding, in: 1...6)
                }
                .font(.callout)
                Divider().opacity(0.4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(plan) { item in
                            HStack {
                                Text(item.from.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right").font(.caption)
                                Text(item.to.lastPathComponent).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.callout)
                        }
                    }
                }
                ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                Text("Files are renamed where they are. The extension is always kept.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            VStack(spacing: 0) {
                Divider().opacity(0.4)
                HStack {
                    if let undo {
                        Button("Undo Rename") {
                            do {
                                try Renamer.apply(undo)
                                current = undo.map(\.to)
                                self.undo = nil
                                message = "Restored the original names"
                            } catch { message = error.localizedDescription }
                        }.buttonStyle(SoftButton())
                    }
                    Spacer()
                    if let message { Text(message).font(.callout).foregroundStyle(message.hasPrefix("✓") || message.hasPrefix("Restored") ? .green : .red) }
                    Button(undo == nil ? "Rename \(urls.count) Files" : "Done") {
                        if undo != nil { close(); return }
                        do {
                            let back = try Renamer.apply(plan)
                            undo = back
                            current = plan.map(\.to)
                            message = "✓ Renamed \(back.count) files"
                            AppSettings.recent = current + AppSettings.recent
                        } catch { message = error.localizedDescription }
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(undo == nil && !problems.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }.padding(14)
            }
        }
    }
}

// MARK: - PDF page organizer

struct PDFPagesEditor: View {
    let url: URL
    let close: () -> Void
    struct Page: Identifiable, Equatable {
        let id = UUID()
        let index: Int
        var rotation = 0
        let thumb: SendableImage
        static func == (a: Page, b: Page) -> Bool { a.id == b.id && a.rotation == b.rotation }
    }
    @State private var pages: [Page] = []
    @State private var selection: Set<UUID> = []
    @State private var dragging: UUID?
    @State private var message: String?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { rotate(-90) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                Button { rotate(90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                Button { move(-1) } label: { Label("Earlier", systemImage: "arrow.left") }
                Button { move(1) } label: { Label("Later", systemImage: "arrow.right") }
                Button(role: .destructive) { pages.removeAll { selection.contains($0.id) }; selection = [] } label: {
                    Label("Delete", systemImage: "trash")
                }
                Spacer()
                Button(selection.count == pages.count ? "Select None" : "Select All") {
                    selection = selection.count == pages.count ? [] : Set(pages.map(\.id))
                }
            }
            .buttonStyle(SoftButton())
            .disabled(pages.isEmpty)
            .padding(12)
            ScrollView {
                if let loadError { Text(loadError).foregroundStyle(.red).padding() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 14) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { pos, page in
                        VStack(spacing: 6) {
                            Image(decorative: page.thumb.cgImage, scale: 1).resizable().scaledToFit()
                                .rotationEffect(.degrees(Double(page.rotation)))
                                .frame(width: 130, height: 150)
                                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                            Text("\(pos + 1)").font(.caption.bold())
                                .foregroundStyle(selection.contains(page.id) ? .white : Theme.ink)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(selection.contains(page.id) ? Theme.accent : .white.opacity(0.4)))
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(selection.contains(page.id) ? Theme.accent : .clear, lineWidth: 3))
                        .opacity(dragging == page.id ? 0.4 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                                if selection.contains(page.id) { selection.remove(page.id) } else { selection.insert(page.id) }
                            } else { selection = selection == [page.id] ? [] : [page.id] }
                        }
                        .onDrag { dragging = page.id; return NSItemProvider(object: page.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: PageDrop(target: page.id, pages: $pages, dragging: $dragging))
                    }
                }
                .padding(14)
            }
            .background(Color.black.opacity(0.05))
            VStack(spacing: 0) {
                Divider().opacity(0.4)
                HStack {
                    Text("\(pages.count) pages · click to select, ⌘-click for more, drag to reorder").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let message { Text(message).font(.callout).foregroundStyle(message.hasPrefix("✓") ? .green : .red) }
                    Button("Extract Selected") { save(pages.filter { selection.contains($0.id) }, suffix: "Extract") }
                        .buttonStyle(SoftButton()).disabled(selection.isEmpty)
                    Button("Save PDF") { save(pages, suffix: "Edited") }.buttonStyle(PrimaryButton()).disabled(pages.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }.padding(14)
            }
        }
        .task {
            do {
                let u = url
                let thumbs = try await Task.detached { try PDFTools.thumbnails(u) }.value
                pages = thumbs.enumerated().map { Page(index: $0.offset, thumb: $0.element) }
            } catch { loadError = error.localizedDescription }
        }
    }

    private func rotate(_ d: Int) {
        for i in pages.indices where selection.contains(pages[i].id) || selection.isEmpty { pages[i].rotation += d }
    }

    private func move(_ delta: Int) {
        var order = pages
        let indices = order.indices.filter { selection.contains(order[$0].id) }
        for i in (delta > 0 ? indices.reversed() : indices) {
            let j = i + delta
            guard order.indices.contains(j), !selection.contains(order[j].id) else { continue }
            order.swapAt(i, j)
        }
        withAnimation { pages = order }
    }

    private func save(_ list: [Page], suffix: String) {
        do {
            let dest = AppSettings.output.outputURL(for: url, suffix: suffix, ext: "pdf")
            try PDFTools.rebuild(url, pages: list.map { .init(index: $0.index, extraRotation: $0.rotation) }, to: dest)
            AppSettings.didSave([dest])
            finish([dest], message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

struct PageDrop: DropDelegate {
    let target: UUID
    @Binding var pages: [PDFPagesEditor.Page]
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target, let from = pages.firstIndex(where: { $0.id == d }),
              let to = pages.firstIndex(where: { $0.id == target }) else { return }
        withAnimation { pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

// MARK: - Watermark

struct WatermarkEditor: View {
    let urls: [URL]
    let close: () -> Void
    @State private var s = PDFTools.WatermarkSettings()
    @State private var color = Color.red
    @State private var page: SendableImage?
    @State private var working = false
    @State private var message: String?

    struct Key: Equatable { let s: PDFTools.WatermarkSettings; let loaded: Bool }

    var body: some View {
        VStack(spacing: 0) {
            if let page { FittedImage(image: preview(page.cgImage)) } else { Color.clear }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Text").frame(width: 84, alignment: .leading)
                    TextField("Watermark", text: $s.text).textFieldStyle(.roundedBorder)
                    ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                }
                HStack {
                    Text("Position").frame(width: 84, alignment: .leading)
                    ChipPicker(options: PDFTools.WatermarkPosition.allCases, selection: $s.position) { $0.rawValue }
                    Spacer()
                }
                LabeledSlider(title: "Size", value: $s.fontSize, range: 12...160, unit: " pt")
                LabeledSlider(title: "Opacity", value: $s.opacity, range: 0.05...1, format: { "\(Int($0 * 100))%" })
                if urls.count > 1 { Text("Applies to all \(urls.count) PDFs").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16)
            EditorFooter(reset: { s = .init(); color = .red }, primary: "Add Watermark",
                         primaryEnabled: !s.text.trimmingCharacters(in: .whitespaces).isEmpty, working: working, message: message) {
                Task { await save() }
            }
        }
        .onChange(of: color) { _, c in
            if let rgb = NSColor(c).usingColorSpace(.sRGB) { s.color = .init(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) }
        }
        .task {
            let u = urls[0]
            page = await Task.detached { () -> SendableImage? in
                guard let p = PDFDocument(url: u)?.page(at: 0) else { return nil }
                return DocumentKit.render(p, dpi: 110).map(SendableImage.init)
            }.value
        }
    }

    /// Draws the watermark over the rendered first page, matching the PDF output.
    private func preview(_ img: CGImage) -> CGImage {
        guard let ctx = ImageKit.makeContext(width: img.width, height: img.height) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let k = 110.0 / 72
        ctx.scaleBy(x: k, y: k)
        PDFTools.drawWatermark(s, in: ctx, size: CGSize(width: Double(img.width) / k, height: Double(img.height) / k))
        return ctx.makeImage() ?? img
    }

    private func save() async {
        working = true; defer { working = false }
        var outs: [URL] = []
        let settings = s
        do {
            for url in urls {
                let dest = AppSettings.output.outputURL(for: url, suffix: "Watermarked", ext: "pdf")
                try await Task.detached { try PDFTools.watermark(url, settings, to: dest) }.value
                outs.append(dest)
            }
            AppSettings.didSave(outs)
            finish(outs, message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}


import SwiftUI
import DropWheelCore

// MARK: - Compress (images)

struct CompressEditor: View {
    let urls: [URL]
    let close: () -> Void
    @State private var quality = 0.7
    @State private var maxPixel = 0
    @State private var format: OutputFormat?   // nil = keep original
    @State private var estimate: Int64?
    @State private var preview: CGImage?
    @State private var original: CGImage?
    @State private var working = false
    @State private var message: String?

    private var first: URL { urls[0] }
    private let sizes = [0, 4096, 2560, 1920, 1280, 800]

    struct Key: Equatable { let q: Double; let m: Int; let f: OutputFormat? }

    private func settings(for url: URL) -> ImageTools.CompressSettings {
        let own = OutputFormat.matching(url)
        let f = format ?? (own.flatMap { [.jpg, .heic, .png, .tiff, .webp].contains($0) ? $0 : nil } ?? .jpg)
        return .init(quality: quality, maxPixel: maxPixel == 0 ? nil : maxPixel, format: f)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let img = preview ?? original { FittedImage(image: img) } else { Color.clear }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Format").frame(width: 84, alignment: .leading)
                    Picker("", selection: $format) {
                        Text("Same as original").tag(OutputFormat?.none)
                        Text("JPEG").tag(OutputFormat?.some(.jpg))
                        Text("HEIC (smallest)").tag(OutputFormat?.some(.heic))
                        Text("PNG (lossless)").tag(OutputFormat?.some(.png))
                    }.labelsHidden().frame(width: 200)
                    Spacer()
                }
                LabeledSlider(title: "Quality", value: $quality, range: 0.1...1, format: { "\(Int(($0 * 100).rounded()))%" })
                    .disabled(settings(for: first).format == .png)
                HStack {
                    Text("Max size").frame(width: 84, alignment: .leading)
                    ChipPicker(options: sizes, selection: $maxPixel) { $0 == 0 ? "Original" : "\($0)px" }
                    Spacer()
                }
                HStack(spacing: 6) {
                    Text(formattedSize(fileSize(first))).font(.title3.weight(.semibold))
                    Image(systemName: "arrow.right")
                    if let estimate {
                        Text(formattedSize(estimate)).font(.title3.weight(.semibold)).foregroundStyle(Theme.accentDeep)
                        let saved = 1 - Double(estimate) / Double(max(1, fileSize(first)))
                        Text(saved >= 0 ? "−\(Int(saved * 100))%" : "+\(Int(-saved * 100))% (larger)")
                            .font(.callout).foregroundStyle(saved >= 0 ? .green : .orange)
                    } else { ProgressView().controlSize(.small) }
                    Spacer()
                    if urls.count > 1 { Text("Applies to all \(urls.count) images").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(16)
            EditorFooter(reset: { quality = 0.7; maxPixel = 0; format = nil }, primary: urls.count > 1 ? "Compress \(urls.count)" : "Compress",
                         working: working, message: message) { Task { await save() } }
        }
        .task { original = try? ImageKit.load(first) }
        .task(id: Key(q: quality, m: maxPixel, f: format)) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let original else { return }
            estimate = nil
            let s = settings(for: first), src = SendableImage(original)
            let result = await Task.detached { () -> (Int64, SendableImage?)? in
                guard let d = try? ImageTools.compress(src.cgImage, s) else { return nil }
                return (Int64(d.count), (try? ImageKit.load(data: d)).map { SendableImage(ImageKit.scaled($0, maxPixel: 1400)) })
            }.value
            if !Task.isCancelled, let result { estimate = result.0; preview = result.1?.cgImage }
        }
    }

    private func save() async {
        working = true; defer { working = false }
        var outs: [URL] = []
        do {
            for url in urls {
                let s = settings(for: url)
                let dest = AppSettings.output.outputURL(for: url, suffix: "Compressed", ext: s.format.fileExtension)
                try await Task.detached(priority: .userInitiated) {
                    try ImageTools.compress(try ImageKit.load(url), s).write(to: dest, options: .atomic)
                }.value
                outs.append(dest)
            }
            AppSettings.didSave(outs)
            finish(outs, message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Metadata (images)

struct MetadataEditor: View {
    let urls: [URL]
    let close: () -> Void
    @State private var entries: [ImageKit.MetadataEntry] = []
    @State private var search = ""
    @State private var working = false
    @State private var message: String?

    private var first: URL { urls[0] }
    private var groups: [(String, [ImageKit.MetadataEntry])] {
        let filtered = search.isEmpty ? entries : entries.filter {
            $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search)
        }
        var order: [String] = []
        var dict: [String: [ImageKit.MetadataEntry]] = [:]
        for e in filtered {
            if dict[e.group] == nil { order.append(e.group) }
            dict[e.group, default: []].append(e)
        }
        return order.map { ($0, dict[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.path)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading) {
                    Text(first.lastPathComponent).font(.headline)
                    Text(urls.count > 1 ? "+ \(urls.count - 1) more" : formattedSize(fileSize(first))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if urls.contains(where: ImageKit.hasLocation) {
                    Label("Has location", systemImage: "location.fill").font(.caption).foregroundStyle(.orange)
                }
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            .padding(14)
            List {
                ForEach(groups, id: \.0) { group, items in
                    Section(group) {
                        ForEach(items) { e in
                            HStack(alignment: .top) {
                                Text(e.key).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
                                Text(e.value).textSelection(.enabled)
                            }.font(.callout)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            VStack(spacing: 0) {
                Divider().opacity(0.4)
                HStack {
                    if let message { Text(message).font(.callout).foregroundStyle(message.hasPrefix("✓") ? .green : .red) }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Remove Location") { Task { await strip(locationOnly: true) } }.buttonStyle(SoftButton())
                    Button("Remove All Metadata") { Task { await strip(locationOnly: false) } }.buttonStyle(PrimaryButton())
                }.padding(14)
            }
        }
        .task { entries = ImageKit.metadata(first) }
    }

    private func strip(locationOnly: Bool) async {
        working = true; defer { working = false }
        var outs: [URL] = []
        do {
            for url in urls {
                let dest = AppSettings.output.outputURL(for: url, suffix: locationOnly ? "No Location" : "Clean", ext: url.pathExtension)
                try await Task.detached { try ImageKit.stripMetadata(url, to: dest, locationOnly: locationOnly) }.value
                outs.append(dest)
            }
            AppSettings.didSave(outs)
            finish(outs, message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

// MARK: - PDF tools

struct PDFCompressEditor: View {
    let urls: [URL]
    let close: () -> Void
    @State private var level: PDFTools.CompressLevel = .balanced
    @State private var estimates: [PDFTools.CompressLevel: Int64] = [:]
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(urls[0].lastPathComponent) · \(formattedSize(fileSize(urls[0])))").font(.headline)
                    .padding(.bottom, 6)
                ForEach(PDFTools.CompressLevel.allCases) { l in
                    Button { level = l } label: {
                        HStack {
                            Image(systemName: level == l ? "largecircle.fill.circle" : "circle").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.rawValue).font(.body.weight(.semibold))
                                Text(l.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let e = estimates[l] { Text("≈ \(formattedSize(e))").monospacedDigit() } else { ProgressView().controlSize(.small) }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(level == l ? 0.45 : 0.2)))
                    }.buttonStyle(.plain)
                }
                if urls.count > 1 { Text("Applies to all \(urls.count) PDFs").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            .padding(16)
            EditorFooter(primary: "Compress", working: working, message: message) { Task { await save() } }
        }
        .task {
            let u = urls[0]
            for l in PDFTools.CompressLevel.allCases {
                if let d = try? await Task.detached(operation: { try PDFTools.compress(u, level: l) }).value { estimates[l] = Int64(d.count) }
            }
        }
    }

    private func save() async {
        working = true; defer { working = false }
        var outs: [URL] = []
        let l = level
        do {
            for url in urls {
                let dest = AppSettings.output.outputURL(for: url, suffix: "Compressed", ext: "pdf")
                try await Task.detached { try PDFTools.compress(url, level: l).write(to: dest, options: .atomic) }.value
                outs.append(dest)
            }
            AppSettings.didSave(outs)
            finish(outs, message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

struct PDFMetadataEditor: View {
    let url: URL
    let close: () -> Void
    @State private var values: [String: String] = [:]
    @State private var info: [String: String] = [:]
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Document") {
                    ForEach(PDFTools.editableKeys, id: \.1) { _, label in
                        TextField(label, text: Binding(get: { values[label] ?? "" }, set: { values[label] = $0 }))
                    }
                }
                Section("Info") {
                    ForEach(["Pages", "Size", "Created", "Modified"], id: \.self) { k in
                        if let v = info[k] { LabeledContent(k, value: v) }
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            EditorFooter(reset: { values = [:] }, primary: "Save", message: message) {
                do {
                    let dest = AppSettings.output.outputURL(for: url, suffix: "Edited", ext: "pdf")
                    try PDFTools.writeMetadata(url, values: values, to: dest)
                    AppSettings.didSave([dest])
                    finish([dest], message: $message, close: close)
                } catch { message = error.localizedDescription }
            }
        }
        .task {
            let m = (try? PDFTools.metadata(url)) ?? [:]
            info = m
            values = m.filter { k, _ in PDFTools.editableKeys.contains { $0.1 == k } }
        }
    }
}

struct PDFProtectEditor: View {
    let url: URL
    let close: () -> Void
    @State private var password = ""
    @State private var confirm = ""
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Anyone opening the copy will need this password.", systemImage: "lock.doc")
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                SecureField("Confirm password", text: $confirm).textFieldStyle(.roundedBorder)
                if !confirm.isEmpty && confirm != password { Text("Passwords don't match").font(.caption).foregroundStyle(.red) }
                Text("The original file is left unchanged.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            EditorFooter(primary: "Protect", primaryEnabled: !password.isEmpty && password == confirm, message: message) {
                do {
                    let dest = AppSettings.output.outputURL(for: url, suffix: "Protected", ext: "pdf")
                    try PDFTools.protect(url, password: password, to: dest)
                    AppSettings.didSave([dest])
                    finish([dest], message: $message, close: close)
                } catch { message = error.localizedDescription }
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let openSettings: () -> Void
    let tryIt: () -> Void
    let close: () -> Void
    @State private var demo: WheelModel = {
        let m = WheelModel()
        m.files = [URL(fileURLWithPath: "/tmp/Example.jpg")]
        m.visible = true
        m.hoveredIndex = 1
        return m
    }()

    var body: some View {
        EditorChrome(title: "Welcome to DropWheel", close: close) {
            VStack(spacing: 14) {
                WheelView(model: demo).scaleEffect(0.55).frame(width: 260, height: 250).allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 10) {
                    step("1", "Start dragging any file — an image, PDF, Word doc or text file.")
                    step("2", "The wheel pops up beside it. Drop on a segment to convert.")
                    step("3", "Hover the centre to flip to Tools: crop, compress, edit, annotate, add background, redact, metadata.")
                    step("4", "Results are saved next to the original. Press ⌥⌘D to open the wheel anytime.")
                }
                .padding(.horizontal, 30)
                Spacer()
                HStack {
                    Button("Settings…", action: openSettings).buttonStyle(SoftButton())
                    Spacer()
                    Button("Try It", action: tryIt).buttonStyle(PrimaryButton())
                }.padding(16)
            }
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(.caption.bold()).foregroundStyle(.white).frame(width: 20, height: 20).background(Circle().fill(Theme.accent))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

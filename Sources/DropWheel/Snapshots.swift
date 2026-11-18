import SwiftUI
import DropWheelCore

/// `DropWheel --snapshot <folder> <sample-image> <sample-pdf>` renders the wheel and every editor to PNGs and
/// checks wheel hit-testing. Used for visual QA without driving the UI by hand.
@MainActor
enum Snapshots {
    static func run(folder: URL, sample: URL, pdf: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bg = LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        var failures = 0

        func render<V: View>(_ name: String, _ view: V, size: CGSize) {
            let r = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
            r.scale = 1
            guard let cg = r.cgImage else { print("✗ \(name) didn't render"); failures += 1; return }
            try? ImageKit.write(cg, to: folder.appendingPathComponent("\(name).png"), as: .png)
            print("✓ \(name).png")
        }

        func wheel(_ files: [URL], page: WheelPage = .convert, hover: Int? = nil, status: WheelStatus = .idle) -> WheelModel {
            let m = WheelModel()
            m.files = files; m.page = page; m.hoveredIndex = hover; m.status = status; m.visible = true
            return m
        }

        let img = try! ImageKit.load(sample)
        render("wheel-image-convert", ZStack { bg; WheelView(model: wheel([sample], hover: 2)) }, size: CGSize(width: 440, height: 440))
        render("wheel-image-tools", ZStack { bg; WheelView(model: wheel([sample], page: .tools, hover: 5)) }, size: CGSize(width: 440, height: 440))
        render("wheel-pdf", ZStack { bg; WheelView(model: wheel([pdf], hover: 0)) }, size: CGSize(width: 440, height: 440))
        render("wheel-working", ZStack { bg; WheelView(model: wheel([sample], status: .working("Working…"))) }, size: CGSize(width: 440, height: 440))
        render("wheel-empty", ZStack { bg; WheelView(model: wheel([])) }, size: CGSize(width: 440, height: 440))

        let close = {}
        let editors: [(String, AnyView, Tool)] = [
            ("crop", AnyView(CropEditor(url: sample, image: img, close: close)), .crop),
            ("background", AnyView(BackgroundEditor(url: sample, image: img, close: close)), .addBackground),
            ("edit", AnyView(AdjustEditor(url: sample, image: img, close: close)), .edit),
            ("annotate", AnyView(AnnotateEditor(url: sample, image: img, close: close)), .annotate),
            ("redact", AnyView(RedactEditor(url: sample, image: img, close: close)), .redact),
            ("compress", AnyView(CompressEditor(urls: [sample], close: close)), .compress),
            ("metadata", AnyView(MetadataEditor(urls: [sample], close: close)), .metadata),
            ("pdf-compress", AnyView(PDFCompressEditor(urls: [pdf], close: close)), .pdfCompress),
            ("pdf-metadata", AnyView(PDFMetadataEditor(url: pdf, close: close)), .pdfMetadata),
            ("pdf-protect", AnyView(PDFProtectEditor(url: pdf, close: close)), .pdfProtect),
        ]
        for (name, view, tool) in editors {
            render("editor-\(name)", EditorChrome(title: tool.label.capitalized, close: close) { view }.background(Color(white: 0.9)), size: tool.windowSize)
        }
        render("welcome", WelcomeView(openSettings: {}, tryIt: {}, close: {}).background(Color(white: 0.9)), size: CGSize(width: 520, height: 560))

        // Hit testing: the top of the ring is item 0, clockwise from there; the centre flips pages.
        let m = wheel([sample])
        let c = WheelModel.size / 2, mid = (WheelModel.innerRadius + WheelModel.outerRadius) / 2
        let n = m.items.count
        for i in 0..<n {
            let a = Double(i) * 2 * .pi / Double(n)
            let p = CGPoint(x: c + mid * sin(a), y: c - mid * cos(a))
            if m.hit(p) != .segment(i) { print("✗ hit test for segment \(i) (\(m.items[i].label)) got \(m.hit(p))"); failures += 1 }
        }
        if m.hit(CGPoint(x: c, y: c)) != .center { print("✗ centre hit"); failures += 1 }
        if m.hit(CGPoint(x: 2, y: 2)) != .outside { print("✗ outside hit"); failures += 1 }
        var performed: WheelAction?
        m.onPerform = { a, _ in performed = a }
        m.activate(at: CGPoint(x: c, y: c - mid), files: [sample])
        if performed != m.items.first?.action { print("✗ drop on top segment didn't perform"); failures += 1 }
        m.busy = false; m.status = .idle
        m.activate(at: CGPoint(x: c, y: c))
        if m.page != .tools { print("✗ clicking the centre didn't flip to Tools"); failures += 1 }
        print("Wheel: convert [\(wheel([sample]).items.map(\.label).joined(separator: ", "))], tools [\(m.items.map(\.label).joined(separator: ", "))]")
        print(failures == 0 ? "All snapshot checks passed" : "\(failures) snapshot checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}

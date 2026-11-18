import SwiftUI
import DropWheelCore

enum CropAspect: String, CaseIterable {
    case free = "Free", square = "1:1", wide = "16:9", tall = "9:16", classic = "4:3", portrait = "3:4"
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .wide: 16 / 9
        case .tall: 9 / 16
        case .classic: 4 / 3
        case .portrait: 3 / 4
        }
    }
}

struct CropEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void
    private let preview: CGImage

    @State private var crop: CGRect
    @State private var aspect: CropAspect = .free
    @State private var dragStart: (rect: CGRect, mode: Mode)?
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var working = false
    @State private var message: String?

    enum Mode { case move, tl, t, tr, r, br, b, bl, l }

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url; self.image = image; self.close = close
        preview = ImageKit.scaled(image, maxPixel: 1600)
        _crop = State(initialValue: CGRect(origin: .zero, size: image.size))
    }

    private var bounds: CGRect { CGRect(origin: .zero, size: image.size) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let fit = ImageFit(imageSize: image.size, in: geo.size)
                let r = fit.toView(crop)
                ZStack(alignment: .topLeading) {
                    Image(decorative: preview, scale: 1).resizable()
                        .frame(width: fit.rect.width, height: fit.rect.height)
                        .offset(x: fit.rect.minX, y: fit.rect.minY)
                    // Dim everything outside the crop.
                    Path { p in p.addRect(fit.rect); p.addRect(r) }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    Rectangle().strokeBorder(Theme.accent, lineWidth: 2)
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    ForEach(handlePoints(r), id: \.0) { _, p in
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 12, height: 12)
                            .position(p)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in drag(v, fit: fit) }
                    .onEnded { _ in dragStart = nil; syncText() })
            }
            .background(Color.black.opacity(0.06))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Aspect ratio").frame(width: 100, alignment: .leading)
                    ChipPicker(options: CropAspect.allCases, selection: $aspect) { $0.rawValue }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("W")
                    TextField("", text: $widthText).frame(width: 80).textFieldStyle(.roundedBorder).onSubmit(applyText)
                    Text("H")
                    TextField("", text: $heightText).frame(width: 80).textFieldStyle(.roundedBorder).onSubmit(applyText)
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                    Text("Original \(image.width) × \(image.height)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)

            EditorFooter(reset: { crop = bounds; aspect = .free; syncText() }, primary: "Apply", working: working, message: message) {
                Task { await save() }
            }
        }
        .onAppear(perform: syncText)
        .onChange(of: aspect) { _, a in
            guard let ratio = a.ratio else { return }
            var w = image.size.width, h = w / ratio
            if h > image.size.height { h = image.size.height; w = h * ratio }
            crop = CGRect(x: (image.size.width - w) / 2, y: (image.size.height - h) / 2, width: w, height: h).integral
            syncText()
        }
    }

    private func handlePoints(_ r: CGRect) -> [(Int, CGPoint)] {
        [(0, CGPoint(x: r.minX, y: r.minY)), (1, CGPoint(x: r.midX, y: r.minY)), (2, CGPoint(x: r.maxX, y: r.minY)),
         (3, CGPoint(x: r.maxX, y: r.midY)), (4, CGPoint(x: r.maxX, y: r.maxY)), (5, CGPoint(x: r.midX, y: r.maxY)),
         (6, CGPoint(x: r.minX, y: r.maxY)), (7, CGPoint(x: r.minX, y: r.midY))]
    }

    private func mode(at p: CGPoint, _ r: CGRect) -> Mode? {
        let t: CGFloat = 16
        let nearL = abs(p.x - r.minX) < t, nearR = abs(p.x - r.maxX) < t
        let nearT = abs(p.y - r.minY) < t, nearB = abs(p.y - r.maxY) < t
        let inX = p.x > r.minX - t && p.x < r.maxX + t, inY = p.y > r.minY - t && p.y < r.maxY + t
        switch (nearL, nearR, nearT, nearB) {
        case (true, _, true, _): return .tl
        case (_, true, true, _): return .tr
        case (true, _, _, true): return .bl
        case (_, true, _, true): return .br
        default: break
        }
        if nearT && inX { return .t }
        if nearB && inX { return .b }
        if nearL && inY { return .l }
        if nearR && inY { return .r }
        return r.contains(p) ? .move : nil
    }

    private func drag(_ v: DragGesture.Value, fit: ImageFit) {
        if dragStart == nil {
            guard let m = mode(at: v.startLocation, fit.toView(crop)) else { return }
            dragStart = (crop, m)
        }
        guard let (start, m) = dragStart else { return }
        let dx = v.translation.width / fit.scale, dy = v.translation.height / fit.scale
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        switch m {
        case .move:
            let nx = min(max(0, start.minX + dx), bounds.width - start.width)
            let ny = min(max(0, start.minY + dy), bounds.height - start.height)
            crop = CGRect(x: nx, y: ny, width: start.width, height: start.height).integral
            syncText(); return
        case .tl: minX += dx; minY += dy
        case .t: minY += dy
        case .tr: maxX += dx; minY += dy
        case .r: maxX += dx
        case .br: maxX += dx; maxY += dy
        case .b: maxY += dy
        case .bl: minX += dx; maxY += dy
        case .l: minX += dx
        }
        let minSize: CGFloat = 16
        minX = max(0, min(minX, maxX - minSize)); minY = max(0, min(minY, maxY - minSize))
        maxX = min(bounds.width, max(maxX, minX + minSize)); maxY = min(bounds.height, max(maxY, minY + minSize))
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let ratio = aspect.ratio {
            switch m {
            case .l, .r: r.size.height = r.width / ratio; r.origin.y = start.midY - r.height / 2
            case .t, .b: r.size.width = r.height * ratio; r.origin.x = start.midX - r.width / 2
            default:
                r.size.height = r.width / ratio
                if [.tl, .tr].contains(m) { r.origin.y = start.maxY - r.height }
            }
            r = fitInside(r, ratio: ratio)
        }
        crop = r.integral
        syncText()
    }

    private func fitInside(_ r: CGRect, ratio: CGFloat) -> CGRect {
        var r = r
        if r.width > bounds.width { r.size.width = bounds.width; r.size.height = r.width / ratio }
        if r.height > bounds.height { r.size.height = bounds.height; r.size.width = r.height * ratio }
        r.origin.x = min(max(0, r.minX), bounds.width - r.width)
        r.origin.y = min(max(0, r.minY), bounds.height - r.height)
        return r
    }

    private func syncText() {
        widthText = "\(Int(crop.width))"; heightText = "\(Int(crop.height))"
    }

    private func applyText() {
        guard var w = Double(widthText), var h = Double(heightText) else { syncText(); return }
        if let ratio = aspect.ratio {
            if Int(w) != Int(crop.width) { h = w / ratio } else { w = h * ratio }
        }
        w = min(max(16, w), bounds.width); h = min(max(16, h), bounds.height)
        crop = fitInside(CGRect(x: crop.midX - w / 2, y: crop.midY - h / 2, width: w, height: h), ratio: w / h).integral
        syncText()
    }

    private func save() async {
        working = true; defer { working = false }
        do {
            let out = try ImageTools.crop(image, to: crop)
            let dest = try await saveImage(out, source: url, suffix: "Cropped")
            finish([dest], message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

import SwiftUI
import DropWheelCore

enum Tool: String {
    case compress, metadata, edit, annotate, addBackground, crop, redact
    case pdfCompress, pdfRotate, pdfSplit, pdfMetadata, pdfProtect

    var label: String {
        switch self {
        case .compress, .pdfCompress: "COMPRESS"
        case .metadata, .pdfMetadata: "METADATA"
        case .edit: "EDIT"
        case .annotate: "ANNOTATE"
        case .addBackground: "ADD BG"
        case .crop: "CROP"
        case .redact: "REDACT"
        case .pdfRotate: "ROTATE"
        case .pdfSplit: "SPLIT"
        case .pdfProtect: "PROTECT"
        }
    }

    var symbol: String {
        switch self {
        case .compress, .pdfCompress: "arrow.down.right.and.arrow.up.left"
        case .metadata, .pdfMetadata: "tag"
        case .edit: "slider.horizontal.3"
        case .annotate: "pencil.tip.crop.circle"
        case .addBackground: "photo"
        case .crop: "crop"
        case .redact: "eye.slash"
        case .pdfRotate: "rotate.right"
        case .pdfSplit: "square.split.2x1"
        case .pdfProtect: "lock"
        }
    }
}

enum WheelAction: Equatable {
    case convert(OutputFormat)
    case combineImages
    case mergePDFs
    case tool(Tool)
}

struct WheelItem: Identifiable, Equatable {
    let action: WheelAction
    var id: String { label }
    var label: String {
        switch action {
        case .convert(let f): f.label
        case .combineImages: "1 PDF"
        case .mergePDFs: "MERGE"
        case .tool(let t): t.label
        }
    }
    var symbol: String? {
        switch action {
        case .convert: nil
        case .combineImages: "doc.on.doc"
        case .mergePDFs: "arrow.triangle.merge"
        case .tool(let t): t.symbol
        }
    }
}

enum WheelPage { case convert, tools }

enum WheelStatus: Equatable {
    case idle, working(String), done(String), failed(String)
}

/// State of the floating wheel. Geometry is in the panel's top-left coordinate space.
@MainActor @Observable
final class WheelModel {
    static let size: CGFloat = 440
    static let outerRadius: CGFloat = 205
    static let innerRadius: CGFloat = 96
    static let hubRadius: CGFloat = 84

    var files: [URL] = [] { didSet { page = .convert; hoveredIndex = nil } }
    var page: WheelPage = .convert
    var hoveredIndex: Int?
    var hoveringCenter = false
    var status: WheelStatus = .idle
    var visible = false
    /// True while a drop or click is being handled, so the wheel isn't hidden mid-task.
    var busy = false

    var onPerform: ((WheelAction, [URL]) -> Void)?
    var onChooseFiles: (() -> Void)?

    private var dwellTask: Task<Void, Never>?

    var kinds: Set<FileKind> { Set(files.map(FileKind.of)) }

    var convertItems: [WheelItem] {
        guard let first = files.first else { return [] }
        var items: [WheelItem] = []
        let images = files.filter { FileKind.of($0) == .image }.count
        let pdfs = files.filter { FileKind.of($0) == .pdf }.count
        if images > 1 { items.append(.init(action: .combineImages)) }
        if pdfs > 1 { items.append(.init(action: .mergePDFs)) }
        // Formats every dropped file can become.
        var common = OutputFormat.targets(for: first)
        for f in files.dropFirst() {
            let t = Set(OutputFormat.targets(for: f))
            common = common.filter { t.contains($0) || OutputFormat.matching(f) == $0 }
        }
        items += common.map { WheelItem(action: .convert($0)) }
        return items
    }

    var toolItems: [WheelItem] {
        let k = kinds
        let multi = files.count > 1
        let tools: [Tool]
        if k == [.image] {
            tools = multi ? [.compress, .metadata] : [.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact]
        } else if k == [.pdf] {
            tools = multi ? [.pdfCompress, .pdfRotate] : [.pdfCompress, .pdfRotate, .pdfSplit, .pdfMetadata, .pdfProtect]
        } else { tools = [] }
        return tools.map { WheelItem(action: .tool($0)) }
    }

    var hasTools: Bool { !toolItems.isEmpty }
    var items: [WheelItem] { page == .tools && hasTools ? toolItems : convertItems }

    var centerText: String {
        switch status {
        case .working(let s): return s
        case .done(let s): return s
        case .failed(let s): return s
        case .idle: break
        }
        if files.isEmpty { return "Drop or click" }
        if let i = hoveredIndex, i < items.count { return items[i].label }
        if hoveringCenter && hasTools { return page == .convert ? "TOOLS" : "CONVERT" }
        let total = files.reduce(Int64(0)) { $0 + fileSize($1) }
        return files.count > 1 ? "\(files.count) files" : formattedSize(total)
    }

    // MARK: Hit testing

    enum Hit: Equatable { case center, segment(Int), outside }

    func hit(_ p: CGPoint) -> Hit {
        let c = Self.size / 2
        let dx = p.x - c, dy = p.y - c
        let r = hypot(dx, dy)
        if r <= Self.hubRadius { return .center }
        guard r >= Self.innerRadius - 6, r <= Self.outerRadius + 6, !items.isEmpty else { return .outside }
        // Angle clockwise from 12 o'clock; segment 0 is centred at the top.
        var a = Double(atan2(dx, -dy))
        if a < 0 { a += 2 * .pi }
        let step = 2 * Double.pi / Double(items.count)
        let idx = Int(((a + step / 2) / step).rounded(.down)) % items.count
        return .segment(idx)
    }

    func hover(_ p: CGPoint?) {
        guard status == .idle else { return }
        let h = p.map(hit) ?? .outside
        var newIndex: Int? = nil
        if case .segment(let i) = h { newIndex = i }
        let onCenter = h == .center
        if newIndex != hoveredIndex || onCenter != hoveringCenter {
            withAnimation(.spring(duration: 0.18)) {
                hoveredIndex = newIndex
                hoveringCenter = onCenter
            }
        }
        if onCenter && hasTools {
            if dwellTask == nil {
                dwellTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let self, self.hoveringCenter else { return }
                    self.togglePage()
                }
            }
        } else {
            dwellTask?.cancel(); dwellTask = nil
        }
    }

    func togglePage() {
        guard hasTools else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
            page = page == .convert ? .tools : .convert
            hoveredIndex = nil
        }
    }

    /// Performs the item under `p` (drop or click). Returns false if nothing is there.
    @discardableResult
    func activate(at p: CGPoint, files dropped: [URL]? = nil) -> Bool {
        if let dropped, !dropped.isEmpty, dropped != files { files = dropped }
        switch hit(p) {
        case .segment(let i) where i < items.count && !files.isEmpty:
            busy = true
            onPerform?(items[i].action, files)
            return true
        case .center:
            if dropped != nil { return false }
            if files.isEmpty || !hasTools { onChooseFiles?() } else { togglePage() }
            return true
        default:
            if files.isEmpty && dropped == nil { onChooseFiles?(); return true }
            return false
        }
    }

    func reset() {
        dwellTask?.cancel(); dwellTask = nil
        status = .idle; busy = false; hoveredIndex = nil; hoveringCenter = false; page = .convert
    }
}

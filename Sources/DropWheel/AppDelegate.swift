import AppKit
import SwiftUI
import Carbon.HIToolbox
import UniformTypeIdentifiers
import DropWheelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = WheelModel()
    lazy var panel = WheelPanel(model: model)
    private var statusItem: NSStatusItem!
    private var monitors: [Any] = []
    private var lastDragChange = NSPasteboard(name: .drag).changeCount
    private var dragActive = false
    private var hideTask: Task<Void, Never>?
    private var windows: [NSWindow] = []
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        model.onPerform = { [weak self] action, files in self?.perform(action, files) }
        model.onChooseFiles = { [weak self] in self?.chooseFiles() }
        startDragWatcher()
        registerHotKey()
        if !AppSettings.hasOnboarded {
            AppSettings.hasOnboarded = true
            showWelcome()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle.fill", accessibilityDescription: "DropWheel")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Show Wheel", #selector(showWheelFromMenu), key: "d", mods: [.command, .option]))
        menu.addItem(item("Open Files…", #selector(chooseFiles), key: "o"))
        menu.addItem(.separator())
        let recentItem = NSMenuItem(title: "Recent Results", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let recent = AppSettings.recent.filter { FileManager.default.fileExists(atPath: $0.path) }
        if recent.isEmpty { sub.addItem(NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")) }
        for url in recent {
            let i = item(url.lastPathComponent, #selector(revealRecent(_:)))
            i.representedObject = url
            i.image = NSWorkspace.shared.icon(forFile: url.path)
            i.image?.size = NSSize(width: 16, height: 16)
            sub.addItem(i)
        }
        recentItem.submenu = sub
        menu.addItem(recentItem)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Welcome & Help", #selector(showWelcome)))
        menu.addItem(.separator())
        menu.addItem(item("Quit DropWheel", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return i
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: Drag detection

    /// Watches system-wide drags: when a drag carrying files starts, the wheel pops up beside it.
    /// Mouse-event monitors don't need Accessibility permission.
    private func startDragWatcher() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp], handler: { event in
            let type = event.type
            MainActor.assumeIsolated { self.handleGlobal(type) }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { _ in
            MainActor.assumeIsolated { self.clickedOutside() }
        }) { monitors.append(m) }
    }

    private func handleGlobal(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDragged:
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != lastDragChange else {
                // Drag already known; with the Option trigger, show as soon as ⌥ is pressed.
                if dragActive, !model.visible, AppSettings.trigger == .option, NSEvent.modifierFlags.contains(.option) {
                    showWheel(files: dragFiles(pb), nearCursor: true)
                }
                return
            }
            lastDragChange = pb.changeCount
            let files = dragFiles(pb)
            guard !files.isEmpty, files.contains(where: { FileKind.of($0) != .unsupported }) else { return }
            dragActive = true
            switch AppSettings.trigger {
            case .always: showWheel(files: files, nearCursor: true)
            case .option: if NSEvent.modifierFlags.contains(.option) { showWheel(files: files, nearCursor: true) }
            case .never: break
            }
        case .leftMouseUp:
            guard dragActive else { return }
            dragActive = false
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, !self.model.busy else { return }
                self.hideWheel()
            }
        default: break
        }
    }

    private func dragFiles(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func clickedOutside() {
        guard model.visible, !dragActive, !model.busy else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) { hideWheel() }
    }

    // MARK: Wheel

    @objc private func showWheelFromMenu() { showWheel(files: [], nearCursor: false) }

    func showWheel(files: [URL], nearCursor: Bool) {
        hideTask?.cancel()
        model.reset()
        model.files = files
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let s = WheelModel.size
        var center: CGPoint
        if nearCursor && AppSettings.placement == .cursor {
            center = CGPoint(x: mouse.x + s / 2 + 50, y: mouse.y)
            if center.x + s / 2 > vf.maxX { center.x = mouse.x - s / 2 - 50 }
        } else {
            center = CGPoint(x: vf.midX, y: vf.midY)
        }
        center.x = min(max(center.x, vf.minX + s / 2), vf.maxX - s / 2)
        center.y = min(max(center.y, vf.minY + s / 2), vf.maxY - s / 2)
        panel.setFrame(NSRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s), display: true)
        panel.orderFrontRegardless()
        if !nearCursor { NSApp.activate(); panel.makeKey() }
        model.visible = true
    }

    func hideWheel() {
        hideTask?.cancel()
        guard model.visible else { return }
        model.visible = false
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            if !self.model.visible { self.panel.orderOut(nil); self.model.reset() }
        }
    }

    @objc func chooseFiles() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.message = "Choose files for the wheel"
        NSApp.activate()
        let wasVisible = model.visible
        if wasVisible { panel.orderOut(nil) }
        guard open.runModal() == .OK, !open.urls.isEmpty else {
            if wasVisible { hideWheel() }
            return
        }
        showWheel(files: open.urls, nearCursor: false)
    }

    // MARK: Actions

    private func perform(_ action: WheelAction, _ files: [URL]) {
        let options = AppSettings.output
        switch action {
        case .tool(let tool) where needsWindow(tool):
            hideWheel()
            openEditor(tool, files: files)
        default:
            model.status = .working(action == .tool(.removeBackground) ? "Cutting out…" : "Working…")
            Task {
                do {
                    let outputs = try await run(action, files, options)
                    AppSettings.didSave(outputs)
                    model.status = .done(outputs.count == 1 ? "Saved" : "Saved \(outputs.count)")
                    try? await Task.sleep(for: .milliseconds(900))
                } catch {
                    model.status = .failed(error.localizedDescription)
                    try? await Task.sleep(for: .milliseconds(2600))
                }
                model.busy = false
                hideWheel()
            }
        }
    }

    private func needsWindow(_ tool: Tool) -> Bool {
        ![.pdfRotate, .pdfSplit, .removeBackground, .mute].contains(tool)
    }

    private func run(_ action: WheelAction, _ files: [URL], _ options: OutputOptions) async throws -> [URL] {
        switch action {
        case .convert(let format): return try await Converter.convert(files, to: format, options: options)
        case .combineImages: return [try await Converter.combineImagesToPDF(files, options: options)]
        case .mergePDFs: return [try Converter.mergePDFs(files, options: options)]
        case .tool(.pdfRotate):
            return try files.map { url in
                let dest = options.outputURL(for: url, suffix: "Rotated", ext: "pdf")
                try PDFTools.rotate(url, by: 90, to: dest)
                return dest
            }
        case .tool(.pdfSplit): return try files.map { try PDFTools.split($0, options: options) }
        case .tool(.removeBackground):
            var outs: [URL] = []
            for url in files {
                let dest = options.outputURL(for: url, suffix: "No Background", ext: "png")
                try await Task.detached(priority: .userInitiated) {
                    let cut = try ImageTools.removeBackground(try ImageKit.load(url))
                    try ImageKit.write(cut, to: dest, as: .png)
                }.value
                outs.append(dest)
            }
            return outs
        case .tool(.mute):
            var outs: [URL] = []
            for url in files {
                let ext = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) ? url.pathExtension : "mov"
                let dest = options.outputURL(for: url, suffix: "Muted", ext: ext)
                try await MediaKit.mute(url, to: dest)
                outs.append(dest)
            }
            return outs
        case .tool: return []
        }
    }

    // MARK: Windows

    func openEditor(_ tool: Tool, files: [URL]) {
        guard let first = files.first else { return }
        let close: () -> Void = { [weak self] in self?.closeKeyEditor() }
        let view: AnyView
        let title: String
        do {
            switch tool {
            case .crop: title = "Crop Image"; view = AnyView(CropEditor(url: first, image: try ImageKit.load(first), close: close))
            case .compress: title = "Compress"; view = AnyView(CompressEditor(urls: files, close: close))
            case .edit: title = "Edit"; view = AnyView(AdjustEditor(url: first, image: try ImageKit.load(first), close: close))
            case .annotate: title = "Annotate"; view = AnyView(AnnotateEditor(url: first, image: try ImageKit.load(first), close: close))
            case .addBackground: title = "Add BG"; view = AnyView(BackgroundEditor(url: first, image: try ImageKit.load(first), close: close))
            case .redact: title = "Redact"; view = AnyView(RedactEditor(url: first, image: try ImageKit.load(first), close: close))
            case .metadata: title = "Metadata"; view = AnyView(MetadataEditor(urls: files, close: close))
            case .pdfCompress: title = "Compress PDF"; view = AnyView(PDFCompressEditor(urls: files, close: close))
            case .pdfMetadata: title = "PDF Metadata"; view = AnyView(PDFMetadataEditor(url: first, close: close))
            case .pdfProtect: title = "Protect PDF"; view = AnyView(PDFProtectEditor(url: first, close: close))
            case .resize: title = "Resize"; view = AnyView(ResizeEditor(urls: files, close: close))
            case .rename: title = "Rename \(files.count) Files"; view = AnyView(RenameEditor(urls: files, close: close))
            case .pdfPages: title = "Pages"; view = AnyView(PDFPagesEditor(url: first, close: close))
            case .pdfWatermark: title = "Watermark"; view = AnyView(WatermarkEditor(urls: files, close: close))
            case .videoCompress: title = "Compress Video"; view = AnyView(VideoCompressEditor(urls: files, close: close))
            case .trim: title = "Trim"; view = AnyView(TrimEditor(url: first, close: close))
            case .pdfRotate, .pdfSplit, .removeBackground, .mute: return
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        present(EditorChrome(title: title, close: close) { view }, size: tool.windowSize)
    }

    private func closeKeyEditor() {
        if let w = NSApp.keyWindow, windows.contains(w) { w.close() }
    }

    func present<V: View>(_ view: V, size: CGSize, resizable: Bool = true) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: resizable ? [.titled, .closable, .fullSizeContentView, .miniaturizable, .resizable]
                                                : [.titled, .closable, .fullSizeContentView, .miniaturizable],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { w.standardWindowButton($0)?.isHidden = true }
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.contentMinSize = NSSize(width: 420, height: 420)
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] note in
            let closed = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windows.removeAll { $0 === closed } }
        }
        windows.append(w)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if let w = windows.first(where: { $0.identifier?.rawValue == "settings" }) { NSApp.activate(); w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "DropWheel Settings"
        w.identifier = NSUserInterfaceItemIdentifier("settings")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center()
        windows.append(w)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    @objc func showWelcome() {
        present(WelcomeView(openSettings: { [weak self] in self?.showSettings() },
                            tryIt: { [weak self] in self?.closeKeyEditor(); self?.showWheel(files: [], nearCursor: false) },
                            close: { [weak self] in self?.closeKeyEditor() }),
                size: CGSize(width: 520, height: 560), resizable: false)
    }

    // MARK: Hot key (⌥⌘D) — Carbon hot keys need no permissions.

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let d = NSApp.delegate as? AppDelegate else { return }
                    if d.model.visible { d.hideWheel() } else { d.showWheel(files: [], nearCursor: false) }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4457_484C), id: 1) // 'DWHL'
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}

extension Tool {
    var windowSize: CGSize {
        switch self {
        case .metadata, .pdfMetadata: CGSize(width: 560, height: 640)
        case .pdfProtect: CGSize(width: 440, height: 420)
        case .pdfCompress: CGSize(width: 480, height: 460)
        case .resize, .videoCompress: CGSize(width: 520, height: 520)
        case .rename: CGSize(width: 620, height: 600)
        case .pdfPages: CGSize(width: 820, height: 720)
        case .pdfWatermark: CGSize(width: 640, height: 720)
        case .trim: CGSize(width: 720, height: 640)
        case .compress: CGSize(width: 620, height: 680)
        default: CGSize(width: 760, height: 780)
        }
    }
}

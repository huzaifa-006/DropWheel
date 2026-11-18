import AppKit
import SwiftUI

/// Borderless floating panel that never steals focus from the app you're dragging from.
final class WheelPanel: NSPanel {
    let model: WheelModel
    private var keyMonitor: Any?

    init(model: WheelModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: WheelModel.size, height: WheelModel.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        acceptsMouseMovedEvents = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: WheelModel.size, height: WheelModel.size))
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        // The interaction layer sits on top so it receives drags and clicks; SwiftUI only draws.
        let drop = WheelDropView(model: model)
        drop.frame = container.bounds
        drop.autoresizingMask = [.width, .height]
        container.addSubview(drop)
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { (NSApp.delegate as? AppDelegate)?.hideWheel() } // Esc
        else if event.keyCode == 49 { model.togglePage() }                       // Space
        else { super.keyDown(with: event) }
    }
}

final class WheelDropView: NSView {
    let model: WheelModel

    init(model: WheelModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true } // match SwiftUI's top-left coordinates

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func point(_ sender: NSDraggingInfo) -> CGPoint { convert(sender.draggingLocation, from: nil) }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let dropped = urls(sender)
        if model.files.isEmpty || Set(dropped) != Set(model.files) { model.files = dropped }
        model.hover(point(sender))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        model.hover(point(sender))
        if case .segment = model.hit(point(sender)) { return .copy }
        return .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { model.hover(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        model.activate(at: point(sender), files: urls(sender))
    }

    override func mouseMoved(with event: NSEvent) { model.hover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { model.hover(nil) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !model.activate(at: p), case .outside = model.hit(p) {
            (NSApp.delegate as? AppDelegate)?.hideWheel()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks outside the disc pass through to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let c = WheelModel.size / 2
        return hypot(p.x - c, p.y - c) <= WheelModel.outerRadius + 8 ? self : nil
    }
}

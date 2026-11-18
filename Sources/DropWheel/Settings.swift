import SwiftUI
import ServiceManagement
import DropWheelCore

enum TriggerMode: String, CaseIterable, Identifiable {
    case always, option, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: "Whenever I drag files"
        case .option: "Only while holding ⌥ Option"
        case .never: "Never — use the shortcut or menu"
        }
    }
}

enum WheelPlacement: String, CaseIterable, Identifiable {
    case cursor, center
    var id: String { rawValue }
    var label: String { self == .cursor ? "Next to the cursor" : "Centre of the screen" }
}

/// UserDefaults-backed settings. Keys are shared with @AppStorage in SettingsView.
enum AppSettings {
    static var d: UserDefaults { .standard }
    static var trigger: TriggerMode { TriggerMode(rawValue: d.string(forKey: "trigger") ?? "") ?? .always }
    static var placement: WheelPlacement { WheelPlacement(rawValue: d.string(forKey: "placement") ?? "") ?? .cursor }
    static var revealAfterSave: Bool { d.bool(forKey: "revealAfterSave") }
    static var playSound: Bool { d.object(forKey: "playSound") as? Bool ?? true }
    static var hasOnboarded: Bool {
        get { d.bool(forKey: "hasOnboarded") }
        set { d.set(newValue, forKey: "hasOnboarded") }
    }
    static var output: OutputOptions {
        OutputOptions(
            location: OutputOptions.Location(rawValue: d.string(forKey: "location") ?? "") ?? .sameFolder,
            jpegQuality: d.object(forKey: "quality") as? Double ?? 0.9,
            pdfRenderDPI: d.object(forKey: "dpi") as? Double ?? 300)
    }

    static var recent: [URL] {
        get { (d.stringArray(forKey: "recent") ?? []).map { URL(fileURLWithPath: $0) } }
        set { d.set(Array(newValue.prefix(10)).map(\.path), forKey: "recent") }
    }

    @MainActor static func didSave(_ urls: [URL]) {
        recent = urls + recent.filter { !urls.contains($0) }
        if playSound { NSSound(named: "Glass")?.play() }
        if revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

struct SettingsView: View {
    @AppStorage("trigger") private var trigger = TriggerMode.always.rawValue
    @AppStorage("placement") private var placement = WheelPlacement.cursor.rawValue
    @AppStorage("location") private var location = OutputOptions.Location.sameFolder.rawValue
    @AppStorage("revealAfterSave") private var reveal = false
    @AppStorage("playSound") private var sound = true
    @AppStorage("quality") private var quality = 0.9
    @AppStorage("dpi") private var dpi = 300.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Wheel") {
                Picker("Show the wheel", selection: $trigger) {
                    ForEach(TriggerMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Position", selection: $placement) {
                    ForEach(WheelPlacement.allCases) { Text($0.label).tag($0.rawValue) }
                }
                LabeledContent("Shortcut", value: "⌥⌘D shows the wheel anytime")
                LabeledContent("Tip", value: "Hover the centre to switch Convert ↔ Tools")
            }
            Section("Saving") {
                Picker("Save results to", selection: $location) {
                    Text("Same folder as the original").tag(OutputOptions.Location.sameFolder.rawValue)
                    Text("Desktop").tag(OutputOptions.Location.desktop.rawValue)
                    Text("Downloads").tag(OutputOptions.Location.downloads.rawValue)
                }
                Toggle("Reveal in Finder after saving", isOn: $reveal)
                Toggle("Play a sound when done", isOn: $sound)
            }
            Section("Quality") {
                LabeledContent("JPEG / HEIC quality") {
                    HStack {
                        Slider(value: $quality, in: 0.3...1, step: 0.05)
                        Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("PDF → image resolution", selection: $dpi) {
                    Text("150 dpi").tag(150.0); Text("300 dpi").tag(300.0); Text("600 dpi").tag(600.0)
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "Move DropWheel to Applications first. (\(error.localizedDescription))"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }
}

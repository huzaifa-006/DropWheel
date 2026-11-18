import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), args.count > i + 3 {
    _ = NSApplication.shared
    Snapshots.run(folder: URL(fileURLWithPath: args[i + 1]), sample: URL(fileURLWithPath: args[i + 2]),
                  pdf: URL(fileURLWithPath: args[i + 3]), video: args.count > i + 4 ? URL(fileURLWithPath: args[i + 4]) : nil)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar app, no Dock icon
app.run()

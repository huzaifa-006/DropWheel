import SwiftUI
import DropWheelCore

/// Window frame shared by every tool: warm glass background, X button, centred title.
struct EditorChrome<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.white.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider().opacity(0.4)
            content()
        }
        .foregroundStyle(Theme.ink)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Theme.warmGradient.opacity(0.55)
            }
            .ignoresSafeArea()
        }
        .tint(Theme.accent)
    }
}

/// Footer with Reset on the left and the primary action on the right.
struct EditorFooter: View {
    var resetEnabled = true
    var reset: (() -> Void)?
    let primary: String
    var primaryEnabled = true
    var working = false
    var message: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack {
                if let reset {
                    Button("Reset", action: reset).buttonStyle(SoftButton()).disabled(!resetEnabled)
                }
                Spacer()
                if let message {
                    Text(message).font(.callout).foregroundStyle(message.hasPrefix("✓") ? .green : .red).lineLimit(2)
                }
                if working { ProgressView().controlSize(.small) }
                Button(primary, action: action)
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!primaryEnabled || working)
            }
            .padding(14)
        }
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct SoftButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(configuration.isPressed ? 0.5 : 0.3)))
    }
}

/// Segmented chips like "Free | 1:1 | 16:9" in the video.
struct ChipPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    Text(label(o)).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(selection == o ? .white : Theme.ink)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selection == o ? Theme.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.3)))
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = ""
    var format: (Double) -> String = { "\(Int($0.rounded()))" }

    var body: some View {
        HStack {
            Text(title).frame(width: 84, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value) + unit).monospacedDigit().font(.callout).frame(width: 64, alignment: .trailing)
        }
    }
}

/// Maps between a fitted on-screen image and its pixel coordinates.
struct ImageFit {
    let imageSize: CGSize
    let rect: CGRect
    var scale: CGFloat { rect.width / imageSize.width }

    init(imageSize: CGSize, in container: CGSize, padding: CGFloat = 20) {
        self.imageSize = imageSize
        let avail = CGSize(width: max(1, container.width - padding * 2), height: max(1, container.height - padding * 2))
        let s = min(avail.width / imageSize.width, avail.height / imageSize.height)
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        rect = CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / scale, y: (p.y - rect.minY) / scale)
    }
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale) }
    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: rect.minX + r.minX * scale, y: rect.minY + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }
}

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }
}

/// Saves a CGImage next to the source using the user's output settings, off the main thread.
@MainActor
func saveImage(_ image: CGImage, source: URL, suffix: String, forceAlpha: Bool = false) async throws -> URL {
    let options = AppSettings.output
    let format = ImageKit.saveFormat(for: source, needsAlpha: forceAlpha)
    let dest = options.outputURL(for: source, suffix: suffix, ext: format.fileExtension)
    let boxed = SendableImage(image)
    try await Task.detached(priority: .userInitiated) {
        try ImageKit.write(boxed.cgImage, to: dest, as: format, quality: max(options.jpegQuality, 0.92))
    }.value
    AppSettings.didSave([dest])
    return dest
}

/// Shows "✓ Saved name" then closes the window.
@MainActor
func finish(_ urls: [URL], message: Binding<String?>, close: @escaping () -> Void) {
    message.wrappedValue = "✓ Saved \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")"
    Task {
        try? await Task.sleep(for: .milliseconds(900))
        close()
    }
}

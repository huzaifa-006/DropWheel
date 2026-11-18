import SwiftUI
import AVKit
import DropWheelCore

// MARK: - Compress video

struct VideoCompressEditor: View {
    let urls: [URL]
    let close: () -> Void
    @State private var quality: MediaKit.VideoQuality = .p1080
    @State private var estimates: [MediaKit.VideoQuality: Int64] = [:]
    @State private var progress: Double?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(urls[0].lastPathComponent) · \(formattedSize(fileSize(urls[0])))").font(.headline).padding(.bottom, 4)
                ForEach(MediaKit.VideoQuality.allCases) { q in
                    Button { quality = q } label: {
                        HStack {
                            Image(systemName: quality == q ? "largecircle.fill.circle" : "circle").foregroundStyle(Theme.accent)
                            Text(q.rawValue).font(.body.weight(.semibold))
                            Spacer()
                            if let e = estimates[q] { Text("≈ \(formattedSize(e))").monospacedDigit().foregroundStyle(.secondary) }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(quality == q ? 0.45 : 0.2)))
                    }.buttonStyle(.plain)
                }
                Text("Videos smaller than the chosen size keep their resolution. Output is MP4.").font(.caption).foregroundStyle(.secondary)
                if urls.count > 1 { Text("Applies to all \(urls.count) videos").font(.caption).foregroundStyle(.secondary) }
                if let progress { ProgressView(value: progress).tint(Theme.accent) }
                Spacer()
            }
            .padding(16)
            EditorFooter(primary: "Compress", working: progress != nil, message: message) { Task { await save() } }
        }
        .task {
            for q in MediaKit.VideoQuality.allCases {
                if let e = await MediaKit.estimatedSize(urls[0], quality: q), e > 0 { estimates[q] = e }
            }
        }
    }

    private func save() async {
        progress = 0; defer { progress = nil }
        var outs: [URL] = []
        let n = Double(urls.count)
        do {
            for (i, url) in urls.enumerated() {
                let dest = AppSettings.output.outputURL(for: url, suffix: "Compressed", ext: "mp4")
                try await MediaKit.compress(url, quality: quality, to: dest) { p in
                    Task { @MainActor in progress = (Double(i) + p) / n }
                }
                outs.append(dest)
            }
            AppSettings.didSave(outs)
            finish(outs, message: $message, close: close)
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Trim (video or audio)

struct TrimEditor: View {
    let url: URL
    let close: () -> Void
    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var isVideo = true
    @State private var working = false
    @State private var message: String?

    init(url: URL, close: @escaping () -> Void) {
        self.url = url; self.close = close
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VideoPlayer(player: player)
                if !isVideo {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 54)).foregroundStyle(Theme.accent)
                        Text(url.lastPathComponent).font(.headline)
                    }.allowsHitTesting(false)
                }
            }
            .background(Color.black.opacity(isVideo ? 1 : 0.05))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Start").frame(width: 50, alignment: .leading)
                    Slider(value: $start, in: 0...max(duration, 0.01)) { editing in if !editing { seek(start) } }
                    Text(time(start)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    Button("Set to Playhead") { start = min(current, end - 0.1) }.buttonStyle(SoftButton())
                }
                HStack {
                    Text("End").frame(width: 50, alignment: .leading)
                    Slider(value: $end, in: 0...max(duration, 0.01)) { editing in if !editing { seek(end) } }
                    Text(time(end)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    Button("Set to Playhead") { end = max(current, start + 0.1) }.buttonStyle(SoftButton())
                }
                HStack {
                    Text("Keeps \(time(max(0, end - start))) of \(time(duration))").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if isVideo { Button("Save Current Frame") { Task { await saveFrame() } }.buttonStyle(SoftButton()) }
                }
            }
            .padding(16)
            EditorFooter(reset: { start = 0; end = duration }, primary: "Save Trimmed", primaryEnabled: end - start > 0.1,
                         working: working, message: message) { Task { await save() } }
        }
        .onChange(of: start) { _, v in if end < v + 0.1 { end = min(duration, v + 0.1) } }
        .onChange(of: end) { _, v in if start > v - 0.1 { start = max(0, v - 0.1) } }
        .task {
            duration = (try? await MediaKit.duration(url)) ?? 0
            end = duration
            isVideo = await MediaKit.hasVideo(url)
        }
        .onDisappear { player.pause() }
    }

    private var current: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }

    private func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func time(_ t: Double) -> String {
        let total = max(0, t)
        return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
    }

    private func save() async {
        working = true; defer { working = false }
        player.pause()
        let ext = ["mov", "mp4", "m4v", "m4a"].contains(url.pathExtension.lowercased()) ? url.pathExtension : (isVideo ? "mov" : "m4a")
        let dest = AppSettings.output.outputURL(for: url, suffix: "Trimmed", ext: ext)
        do {
            try await MediaKit.trim(url, start: start, end: end, to: dest)
            AppSettings.didSave([dest])
            finish([dest], message: $message, close: close)
        } catch { message = error.localizedDescription }
    }

    private func saveFrame() async {
        do {
            let img = try await MediaKit.frame(url, at: current)
            let dest = AppSettings.output.outputURL(for: url, suffix: "Frame", ext: "png")
            try ImageKit.write(img, to: dest, as: .png)
            AppSettings.didSave([dest])
            message = "✓ Saved \(dest.lastPathComponent)"
        } catch { message = error.localizedDescription }
    }
}

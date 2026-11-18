import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// AVAssetExportSession is thread-safe for reading progress but not marked Sendable.
final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ s: AVAssetExportSession) { session = s }
}

/// Video and audio conversion built on AVFoundation.
public enum MediaKit {
    public enum VideoQuality: String, CaseIterable, Sendable, Identifiable {
        case hevc1080 = "1080p HEVC (smallest)", p1080 = "1080p", p720 = "720p", p540 = "540p", p480 = "480p"
        public var id: String { rawValue }
        var preset: String {
            switch self {
            case .hevc1080: AVAssetExportPresetHEVC1920x1080
            case .p1080: AVAssetExportPreset1920x1080
            case .p720: AVAssetExportPreset1280x720
            case .p540: AVAssetExportPreset960x540
            case .p480: AVAssetExportPreset640x480
            }
        }
    }

    public static func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    public static func hasAudio(_ url: URL) async -> Bool {
        ((try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
    }

    public static func hasVideo(_ url: URL) async -> Bool {
        ((try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)) ?? []).isEmpty == false
    }

    static func fileType(for ext: String) -> AVFileType {
        switch ext.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        case "m4a": .m4a
        case "wav": .wav
        default: .mov
        }
    }

    /// Runs an export session. `progress` is called with 0...1 while it runs.
    static func export(_ asset: AVAsset, preset: String, to dest: URL, timeRange: CMTimeRange? = nil,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw DropWheelError("This file can't be exported with that setting.")
        }
        let type = fileType(for: dest.pathExtension)
        guard session.supportedFileTypes.contains(type) else {
            throw DropWheelError("Can't write .\(dest.pathExtension) from this file.")
        }
        if let timeRange { session.timeRange = timeRange }
        let box = SessionBox(session)
        let s = session
        let ticker = Task {
            while !Task.isCancelled {
                progress?(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { ticker.cancel() }
        try? FileManager.default.removeItem(at: dest)
        if #available(macOS 15, *) {
            try await s.export(to: dest, as: type)
        } else {
            s.outputURL = dest
            s.outputFileType = type
            await s.export()
            if let error = s.error { throw error }
            guard s.status == .completed else { throw DropWheelError("Export didn't finish.") }
        }
        progress?(1)
    }

    /// Re-encodes a video to a smaller size. Output is MP4.
    public static func compress(_ url: URL, quality: VideoQuality, to dest: URL,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await export(AVURLAsset(url: url), preset: quality.preset, to: dest, progress: progress)
    }

    public static func estimatedSize(_ url: URL, quality: VideoQuality) async -> Int64? {
        guard let s = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: quality.preset) else { return nil }
        s.outputFileType = .mp4
        let box = SessionBox(s)
        return try? await box.session.estimatedOutputFileLengthInBytes
    }

    /// MOV ↔ MP4 and video → M4A (audio track) conversion.
    public static func convert(_ url: URL, to dest: URL) async throws {
        let ext = dest.pathExtension.lowercased()
        let asset = AVURLAsset(url: url)
        switch ext {
        case "m4a":
            guard await hasAudio(url) else { throw DropWheelError("This file has no audio.") }
            try await export(asset, preset: AVAssetExportPresetAppleM4A, to: dest)
        case "wav":
            try await toWAV(url, dest)
        default:
            // Re-wrap without re-encoding when possible; otherwise re-encode at full quality.
            do { try await export(asset, preset: AVAssetExportPresetPassthrough, to: dest) }
            catch { try await export(asset, preset: AVAssetExportPresetHighestQuality, to: dest) }
        }
    }

    static func toWAV(_ url: URL, _ dest: URL) async throws {
        // AVAudioFile can't read video containers, so pull the audio out to M4A first.
        var source = url
        var temp: URL?
        if await hasVideo(url) {
            let t = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            try await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, to: t)
            source = t; temp = t
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: dest)
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { throw DropWheelError("Audio buffer failed.") }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    /// Cuts out a section. Uses passthrough so it's fast and lossless (cuts land on the nearest keyframe).
    public static func trim(_ url: URL, start: Double, end: Double, to dest: URL) async throws {
        guard end > start else { throw DropWheelError("The end must be after the start.") }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        let asset = AVURLAsset(url: url)
        do { try await export(asset, preset: AVAssetExportPresetPassthrough, to: dest, timeRange: range) }
        catch {
            let preset = await hasVideo(url) ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
            try await export(asset, preset: preset, to: dest, timeRange: range)
        }
    }

    /// Removes the audio track(s) from a video.
    public static func mute(_ url: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: url)
        let comp = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw DropWheelError("This file has no video.") }
        for track in videoTracks {
            let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try t?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            t?.preferredTransform = try await track.load(.preferredTransform)
        }
        try await export(comp, preset: AVAssetExportPresetPassthrough, to: dest)
    }

    /// One frame as an image.
    public static func frame(_ url: URL, at seconds: Double, maxPixel: Int? = nil) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        if let maxPixel { gen.maximumSize = CGSize(width: maxPixel, height: maxPixel) }
        return try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Animated GIF from a video. Long videos use their first `maxSeconds`.
    public static func gif(_ url: URL, to dest: URL, fps: Double = 10, maxWidth: Int = 480, maxSeconds: Double = 15,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard await hasVideo(url) else { throw DropWheelError("This file has no video.") }
        let total = min(try await duration(url), maxSeconds)
        let count = max(1, Int(total * fps))
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        guard let dst = CGImageDestinationCreateWithURL(dest as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw DropWheelError("Couldn't create the GIF.")
        }
        CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let img = try await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600)).image
            CGImageDestinationAddImage(dst, img, frameProps)
            progress?(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dst) else { throw DropWheelError("Couldn't finish the GIF.") }
    }
}

import AVFoundation
import CoreVideo
import DropWheelCore

/// Writes a 1-second 440 Hz sine wave WAV.
func makeWAV(_ url: URL, seconds: Double = 3) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let frames = AVAudioFrameCount(44_100 * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    let p = buf.floatChannelData![0]
    for i in 0..<Int(frames) { p[i] = Float(sin(2 * .pi * 440 * Double(i) / 44_100) * 0.3) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buf)
}

/// Writes a silent H.264 .mov with a moving square, `seconds` long at 30 fps.
func makeSilentVideo(_ url: URL, seconds: Int = 3, width: Int = 320, height: Int = 240) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for f in 0..<(seconds * 30) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: ImageKit.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: f * 3 % width, y: 80, width: 60, height: 60))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    if let e = writer.error { throw e }
}

/// A video with both a picture and an audio track.
func makeVideoWithAudio(_ url: URL, work: URL) async throws {
    let silent = work.appendingPathComponent("silent.mov"), wav = work.appendingPathComponent("tone.wav")
    try await makeSilentVideo(silent)
    try makeWAV(wav)
    let comp = AVMutableComposition()
    let v = AVURLAsset(url: silent), a = AVURLAsset(url: wav)
    let dur = try await v.load(.duration)
    let range = CMTimeRange(start: .zero, duration: dur)
    try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(range, of: try await v.loadTracks(withMediaType: .video)[0], at: .zero)
    try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(range, of: try await a.loadTracks(withMediaType: .audio)[0], at: .zero)
    let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
    try? FileManager.default.removeItem(at: url)
    s.outputURL = url; s.outputFileType = .mov
    await s.export()
    if let e = s.error { throw e }
}

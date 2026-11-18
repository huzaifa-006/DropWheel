import Foundation
import CoreGraphics

/// A self-contained lossless WebP (VP8L) encoder.
///
/// macOS can read WebP but cannot write it, so DropWheel ships its own encoder. It uses the
/// subtract-green and predictor transforms plus LZ77 back-references to the pixel on the left or
/// above, which keeps screenshots and documents small. Output is validated by ImageIO in the self-test.
public enum WebPEncoder {
    public static func encode(_ image: CGImage) throws -> Data {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16384, h <= 16384 else {
            throw DropWheelError("WebP images can be at most 16384×16384 pixels.")
        }
        var argb = try pixels(image)
        let alphaUsed = argb.contains { $0 >> 24 != 0xff }

        var bw = BitWriter()
        bw.write(0x2f, 8)                     // VP8L signature
        bw.write(UInt32(w - 1), 14)
        bw.write(UInt32(h - 1), 14)
        bw.write(alphaUsed ? 1 : 0, 1)
        bw.write(0, 3)                         // version

        // Transform 1: subtract green.
        bw.write(1, 1); bw.write(2, 2)
        for i in argb.indices { argb[i] = subtractGreen(argb[i]) }

        // Transform 2: predictor, one mode per 32×32 block.
        let bits = 5
        bw.write(1, 1); bw.write(0, 2); bw.write(UInt32(bits - 2), 3)
        let (modes, residuals) = predict(argb, width: w, height: h, bits: bits)
        writeEntropyImage(&bw, pixels: modes.map { 0xff00_0000 | (UInt32($0) << 8) }, width: (w + 31) >> 5,
                          isMain: false, useBackrefs: false)

        bw.write(0, 1)                          // no more transforms
        writeEntropyImage(&bw, pixels: residuals, width: w, isMain: true, useBackrefs: true)

        var payload = bw.finish()
        let chunkSize = payload.count
        if payload.count % 2 == 1 { payload.append(0) }
        var out = Data()
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(le32(UInt32(4 + 8 + payload.count)))
        out.append(contentsOf: Array("WEBP".utf8))
        out.append(contentsOf: Array("VP8L".utf8))
        out.append(le32(UInt32(chunkSize)))
        out.append(contentsOf: payload)
        return out
    }

    // MARK: Pixels and transforms

    static func pixels(_ image: CGImage) throws -> [UInt32] {
        let w = image.width, h = image.height
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        let ok = raw.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: ImageKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw DropWheelError("Couldn't read pixels for WebP encoding.") }
        var out = [UInt32](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let a = UInt32(raw[i * 4 + 3])
            if a == 0 { continue }
            var r = UInt32(raw[i * 4]), g = UInt32(raw[i * 4 + 1]), b = UInt32(raw[i * 4 + 2])
            if a < 255 {
                r = min(255, (r * 255 + a / 2) / a); g = min(255, (g * 255 + a / 2) / a); b = min(255, (b * 255 + a / 2) / a)
            }
            out[i] = (a << 24) | (r << 16) | (g << 8) | b
        }
        return out
    }

    @inline(__always) static func subtractGreen(_ p: UInt32) -> UInt32 {
        let g = (p >> 8) & 0xff
        let r = (((p >> 16) & 0xff) &- g) & 0xff
        let b = ((p & 0xff) &- g) & 0xff
        return (p & 0xff00_ff00) | (r << 16) | b
    }

    @inline(__always) static func sub(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let alpha = (((a >> 24) &- (b >> 24)) & 0xff) << 24
        let red = ((((a >> 16) & 0xff) &- ((b >> 16) & 0xff)) & 0xff) << 16
        let green = ((((a >> 8) & 0xff) &- ((b >> 8) & 0xff)) & 0xff) << 8
        let blue = ((a & 0xff) &- (b & 0xff)) & 0xff
        return alpha | red | green | blue
    }

    @inline(__always) static func average2(_ a: UInt32, _ b: UInt32) -> UInt32 {
        (((a ^ b) & 0xfefe_fefe) >> 1) &+ (a & b)
    }

    @inline(__always) static func clampAddSubtractFull(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for shift in stride(from: 0, through: 24, by: 8) {
            let v = Int((a >> UInt32(shift)) & 0xff) + Int((b >> UInt32(shift)) & 0xff) - Int((c >> UInt32(shift)) & 0xff)
            out |= UInt32(min(255, max(0, v))) << UInt32(shift)
        }
        return out
    }

    @inline(__always) static func prediction(mode: Int, l: UInt32, t: UInt32, tl: UInt32) -> UInt32 {
        switch mode {
        case 1: l
        case 2: t
        case 7: average2(l, t)
        case 12: clampAddSubtractFull(l, t, tl)
        default: 0xff00_0000
        }
    }

    @inline(__always) static func cost(_ r: UInt32) -> Int {
        var c = 0
        for shift in stride(from: 0, through: 24, by: 8) {
            let v = Int((r >> UInt32(shift)) & 0xff)
            c += min(v, 256 - v)
        }
        return c
    }

    static func predict(_ px: [UInt32], width w: Int, height h: Int, bits: Int) -> (modes: [UInt8], residuals: [UInt32]) {
        let bs = 1 << bits
        let tilesX = (w + bs - 1) >> bits, tilesY = (h + bs - 1) >> bits
        var modes = [UInt8](repeating: 1, count: tilesX * tilesY)
        let candidates = [1, 2, 7, 12]
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                var best = 1, bestCost = Int.max
                for m in candidates {
                    var c = 0
                    for y in (ty * bs)..<min(h, ty * bs + bs) where y > 0 {
                        for x in (tx * bs)..<min(w, tx * bs + bs) where x > 0 {
                            let i = y * w + x
                            c += cost(sub(px[i], prediction(mode: m, l: px[i - 1], t: px[i - w], tl: px[i - w - 1])))
                        }
                    }
                    if c < bestCost { bestCost = c; best = m }
                }
                modes[ty * tilesX + tx] = UInt8(best)
            }
        }
        var res = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let pred: UInt32
                if x == 0 && y == 0 { pred = 0xff00_0000 }
                else if y == 0 { pred = px[i - 1] }
                else if x == 0 { pred = px[i - w] }
                else {
                    let m = Int(modes[(y >> bits) * tilesX + (x >> bits)])
                    pred = prediction(mode: m, l: px[i - 1], t: px[i - w], tl: px[i - w - 1])
                }
                res[i] = sub(px[i], pred)
            }
        }
        return (modes, res)
    }

    // MARK: Entropy coding

    enum Token { case literal(UInt32); case copy(length: Int, distanceCode: Int) }

    /// LZ77 prefix coding shared by lengths and distances: returns (prefix symbol, extra bit count, extra value).
    @inline(__always) static func prefixEncode(_ value: Int) -> (Int, Int, Int) {
        let d = value - 1
        if d < 4 { return (d, 0, 0) }
        let hb = Int.bitWidth - 1 - d.leadingZeroBitCount
        let second = (d >> (hb - 1)) & 1
        let extraBits = hb - 1
        return (2 * hb + second, extraBits, d & ((1 << extraBits) - 1))
    }

    static func writeEntropyImage(_ bw: inout BitWriter, pixels: [UInt32], width: Int, isMain: Bool, useBackrefs: Bool) {
        var tokens: [Token] = []
        tokens.reserveCapacity(pixels.count / 2)
        let n = pixels.count
        var i = 0
        while i < n {
            var bestLen = 0, bestCode = 0
            if useBackrefs {
                for (dist, code) in [(1, 2), (width, 1)] where i >= dist {
                    var k = 0
                    while i + k < n && k < 4096 && pixels[i + k] == pixels[i + k - dist] { k += 1 }
                    if k > bestLen { bestLen = k; bestCode = code }
                }
            }
            if bestLen >= 3 {
                tokens.append(.copy(length: bestLen, distanceCode: bestCode))
                i += bestLen
            } else {
                tokens.append(.literal(pixels[i]))
                i += 1
            }
        }

        var green = [Int](repeating: 0, count: 256 + 24), red = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256), alpha = [Int](repeating: 0, count: 256)
        var dist = [Int](repeating: 0, count: 40)
        for t in tokens {
            switch t {
            case .literal(let p):
                green[Int((p >> 8) & 0xff)] += 1; red[Int((p >> 16) & 0xff)] += 1
                blue[Int(p & 0xff)] += 1; alpha[Int(p >> 24)] += 1
            case .copy(let len, let dc):
                green[256 + prefixEncode(len).0] += 1
                dist[prefixEncode(dc).0] += 1
            }
        }

        bw.write(0, 1)                       // no colour cache
        if isMain { bw.write(0, 1) }         // single prefix-code group
        let gc = writeHuffman(&bw, green), rc = writeHuffman(&bw, red), bc = writeHuffman(&bw, blue)
        let ac = writeHuffman(&bw, alpha), dcode = writeHuffman(&bw, dist)

        for t in tokens {
            switch t {
            case .literal(let p):
                gc.put(&bw, Int((p >> 8) & 0xff)); rc.put(&bw, Int((p >> 16) & 0xff))
                bc.put(&bw, Int(p & 0xff)); ac.put(&bw, Int(p >> 24))
            case .copy(let len, let dc):
                let (ls, lb, lv) = prefixEncode(len)
                gc.put(&bw, 256 + ls); if lb > 0 { bw.write(UInt32(lv), lb) }
                let (ds, db, dv) = prefixEncode(dc)
                dcode.put(&bw, ds); if db > 0 { bw.write(UInt32(dv), db) }
            }
        }
    }

    struct HuffmanCode {
        var lengths: [Int]
        var codes: [UInt32]   // already bit-reversed for LSB-first writing
        func put(_ bw: inout BitWriter, _ symbol: Int) {
            let len = lengths[symbol]
            if len > 0 { bw.write(codes[symbol], len) }
        }
    }

    /// Writes a prefix code to the stream and returns it for encoding symbols.
    static func writeHuffman(_ bw: inout BitWriter, _ freqs: [Int]) -> HuffmanCode {
        let size = freqs.count
        let used = freqs.indices.filter { freqs[$0] > 0 }
        let none = HuffmanCode(lengths: [Int](repeating: 0, count: size), codes: [UInt32](repeating: 0, count: size))

        // "Simple" codes: one or two symbols below 256. One symbol costs zero bits per use.
        if used.count <= 1 && (used.first ?? 0) < 256 {
            let s = used.first ?? 0
            bw.write(1, 1); bw.write(0, 1)
            if s < 2 { bw.write(0, 1); bw.write(UInt32(s), 1) } else { bw.write(1, 1); bw.write(UInt32(s), 8) }
            return none
        }
        if used.count == 2 && used[1] < 256 {
            bw.write(1, 1); bw.write(1, 1)
            bw.write(1, 1); bw.write(UInt32(used[0]), 8)
            bw.write(UInt32(used[1]), 8)
            var lengths = [Int](repeating: 0, count: size)
            lengths[used[0]] = 1; lengths[used[1]] = 1
            return HuffmanCode(lengths: lengths, codes: canonicalCodes(lengths))
        }

        var f = freqs
        if used.count == 1 { f[used[0] == 0 ? 1 : 0] = 1 }
        let lengths = codeLengths(f, maxLength: 15)
        bw.write(0, 1) // normal code
        writeCodeLengths(&bw, lengths)
        return HuffmanCode(lengths: lengths, codes: canonicalCodes(lengths))
    }

    static let codeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    static func writeCodeLengths(_ bw: inout BitWriter, _ lengths: [Int]) {
        var tokens: [(sym: Int, extra: Int, bits: Int)] = []
        var i = 0
        while i < lengths.count {
            if lengths[i] == 0 {
                var z = 0
                while i + z < lengths.count && lengths[i + z] == 0 { z += 1 }
                var left = z
                while left >= 11 { let t = min(left, 138); tokens.append((18, t - 11, 7)); left -= t }
                if left >= 3 { tokens.append((17, left - 3, 3)); left = 0 }
                for _ in 0..<left { tokens.append((0, 0, 0)) }
                i += z
            } else {
                tokens.append((lengths[i], 0, 0)); i += 1
            }
        }
        var freqs = [Int](repeating: 0, count: 19)
        for t in tokens { freqs[t.sym] += 1 }
        let usedCount = freqs.filter { $0 > 0 }.count
        if usedCount == 1 { freqs[freqs[0] > 0 ? 1 : 0] = 1 }
        let clLengths = codeLengths(freqs, maxLength: 7)
        let clCodes = canonicalCodes(clLengths)
        var count = 19
        while count > 4 && clLengths[codeLengthOrder[count - 1]] == 0 { count -= 1 }
        bw.write(UInt32(count - 4), 4)
        for k in 0..<count { bw.write(UInt32(clLengths[codeLengthOrder[k]]), 3) }
        bw.write(0, 1) // max_symbol = alphabet size
        for t in tokens {
            bw.write(clCodes[t.sym], clLengths[t.sym])
            if t.bits > 0 { bw.write(UInt32(t.extra), t.bits) }
        }
    }

    /// Huffman code lengths, limited to `maxLength` by flattening frequencies until the tree fits.
    static func codeLengths(_ freqs: [Int], maxLength: Int) -> [Int] {
        var f = freqs
        while true {
            let lengths = huffmanLengths(f)
            if (lengths.max() ?? 0) <= maxLength { return lengths }
            f = f.map { $0 > 0 ? max(1, $0 >> 1) : 0 }
        }
    }

    static func huffmanLengths(_ freqs: [Int]) -> [Int] {
        var weights: [Int] = [], parent: [Int] = []
        var active: [Int] = []
        var leafOf: [Int: Int] = [:]
        for (s, f) in freqs.enumerated() where f > 0 {
            leafOf[weights.count] = s
            active.append(weights.count); weights.append(f); parent.append(-1)
        }
        var lengths = [Int](repeating: 0, count: freqs.count)
        if active.count == 1 { lengths[leafOf[0]!] = 1; return lengths }
        while active.count > 1 {
            active.sort { weights[$0] > weights[$1] }
            let a = active.removeLast(), b = active.removeLast()
            let node = weights.count
            weights.append(weights[a] + weights[b]); parent.append(-1)
            parent[a] = node; parent[b] = node
            active.append(node)
        }
        for (leaf, sym) in leafOf {
            var d = 0, n = leaf
            while parent[n] != -1 { n = parent[n]; d += 1 }
            lengths[sym] = d
        }
        return lengths
    }

    static func canonicalCodes(_ lengths: [Int]) -> [UInt32] {
        let maxLen = lengths.max() ?? 0
        var blCount = [Int](repeating: 0, count: maxLen + 1)
        for l in lengths where l > 0 { blCount[l] += 1 }
        var next = [Int](repeating: 0, count: maxLen + 2)
        var code = 0
        if maxLen > 0 {
            for bits in 1...maxLen {
                code = (code + blCount[bits - 1]) << 1
                next[bits] = code
            }
        }
        var codes = [UInt32](repeating: 0, count: lengths.count)
        for (s, l) in lengths.enumerated() where l > 0 {
            codes[s] = reverse(UInt32(next[l]), l)
            next[l] += 1
        }
        return codes
    }

    @inline(__always) static func reverse(_ v: UInt32, _ n: Int) -> UInt32 {
        var r: UInt32 = 0, x = v
        for _ in 0..<n { r = (r << 1) | (x & 1); x >>= 1 }
        return r
    }

    static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
    }
}

struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var acc: UInt64 = 0
    private var count = 0

    mutating func write(_ value: UInt32, _ bits: Int) {
        guard bits > 0 else { return }
        let mask: UInt64 = bits >= 32 ? 0xffff_ffff : (UInt64(1) << UInt64(bits)) - 1
        acc |= (UInt64(value) & mask) << UInt64(count)
        count += bits
        while count >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: acc))
            acc >>= 8
            count -= 8
        }
    }

    mutating func finish() -> [UInt8] {
        if count > 0 { bytes.append(UInt8(truncatingIfNeeded: acc)); acc = 0; count = 0 }
        return bytes
    }
}

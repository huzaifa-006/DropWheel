// Draws the app icon (orange squircle with a white drop wheel) at 1024px.
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset = 100.0
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(path); ctx.clip()
let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
    NSColor(srgbRed: 1.0, green: 0.78, blue: 0.30, alpha: 1).cgColor,
    NSColor(srgbRed: 1.0, green: 0.42, blue: 0.20, alpha: 1).cgColor,
    NSColor(srgbRed: 0.86, green: 0.36, blue: 0.62, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let c = CGPoint(x: size / 2, y: size / 2)
let ro = 300.0, ri = 150.0, n = 6
for i in 0..<n {
    let step = 2 * Double.pi / Double(n)
    let a0 = Double(i) * step + 0.07 + .pi / 2 - step / 2, a1 = Double(i + 1) * step - 0.07 + .pi / 2 - step / 2
    let p = CGMutablePath()
    p.addArc(center: c, radius: ro, startAngle: a0, endAngle: a1, clockwise: false)
    p.addArc(center: c, radius: ri, startAngle: a1, endAngle: a0, clockwise: true)
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(NSColor.white.withAlphaComponent(i == 0 ? 1 : 0.72).cgColor)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(i == 0 ? 1 : 0.72).cgColor)
    ctx.setLineWidth(28); ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
}
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: c.x - 92, y: c.y - 92, width: 184, height: 184))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

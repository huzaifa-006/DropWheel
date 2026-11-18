import SwiftUI
import AppKit

enum Theme {
    static let accent = Color(red: 1.0, green: 0.36, blue: 0.10)
    static let accentDeep = Color(red: 0.93, green: 0.22, blue: 0.05)
    static let peach = Color(red: 1.0, green: 0.86, blue: 0.72)
    static let ink = Color(red: 0.22, green: 0.13, blue: 0.08)
    static let warmGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.72, blue: 0.35), Color(red: 1.0, green: 0.55, blue: 0.38), Color(red: 0.98, green: 0.68, blue: 0.62)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// An annular sector with rounded corners (inset, then stroked with a round join of the same colour).
struct RingSegment: Shape {
    var start: Angle, end: Angle
    var inner: CGFloat, outer: CGFloat
    var gap: CGFloat = 7
    var corner: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let ri = inner + corner, ro = outer - corner
        let half = gap / 2 + corner
        // Convert the straight-edge gap into an angle at each radius so edges stay parallel.
        let ai = Double(half / ri), ao = Double(half / ro)
        let s = start.radians - .pi / 2, e = end.radians - .pi / 2
        var p = Path()
        p.addArc(center: c, radius: ro, startAngle: .radians(s + ao), endAngle: .radians(e - ao), clockwise: false)
        p.addArc(center: c, radius: ri, startAngle: .radians(e - ai), endAngle: .radians(s + ai), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct RoundedRingSegment: View {
    let shape: RingSegment
    let fill: AnyShapeStyle
    var opacity: Double = 1
    var body: some View {
        ZStack {
            shape.fill(fill)
            shape.stroke(fill, style: StrokeStyle(lineWidth: shape.corner * 2, lineJoin: .round))
        }
        // Flatten fill + stroke first so translucency doesn't double up where they overlap.
        .compositingGroup()
        .opacity(opacity)
    }
}

struct WheelView: View {
    @Bindable var model: WheelModel

    var body: some View {
        let items = model.items
        let n = max(items.count, 4)
        let step = 360.0 / Double(n)
        ZStack {
            // Glass disc
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(Theme.warmGradient.opacity(0.45)))
                .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.5))
                .frame(width: WheelModel.outerRadius * 2 + 16, height: WheelModel.outerRadius * 2 + 16)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)

            ForEach(0..<n, id: \.self) { i in
                let start = Angle.degrees(Double(i) * step - step / 2)
                let end = Angle.degrees(Double(i) * step + step / 2)
                let item = i < items.count ? items[i] : nil
                let hovered = model.hoveredIndex == i && item != nil
                RoundedRingSegment(
                    shape: RingSegment(start: start, end: end, inner: WheelModel.innerRadius, outer: WheelModel.outerRadius),
                    fill: hovered
                        ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Theme.peach),
                    opacity: hovered ? 1 : (item == nil ? 0.35 : 0.85))
                    .shadow(color: hovered ? Theme.accent.opacity(0.5) : .clear, radius: 10)
                if let item {
                    label(item, hovered: hovered)
                        .position(position(angle: Double(i) * step, radius: (WheelModel.innerRadius + WheelModel.outerRadius) / 2))
                }
            }

            hub
        }
        .frame(width: WheelModel.size, height: WheelModel.size)
        .scaleEffect(model.visible ? 1 : 0.6)
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(duration: 0.32, bounce: 0.3), value: model.visible)
        .animation(.spring(duration: 0.3), value: model.page)
    }

    private func position(angle deg: Double, radius: CGFloat) -> CGPoint {
        let a = (deg - 90) * .pi / 180
        let c = WheelModel.size / 2
        return CGPoint(x: c + radius * cos(a), y: c + radius * sin(a))
    }

    @ViewBuilder private func label(_ item: WheelItem, hovered: Bool) -> some View {
        let color = hovered ? Color.white : Theme.ink
        if let symbol = item.symbol {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                Text(item.label).font(.system(size: 11, weight: .bold)).tracking(0.6)
            }
            .foregroundStyle(color)
        } else {
            Text(item.label).font(.system(size: 17, weight: .heavy)).foregroundStyle(color)
        }
    }

    private var hub: some View {
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(model.hoveringCenter ? 0.55 : 0.35))
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                .frame(width: WheelModel.hubRadius * 2, height: WheelModel.hubRadius * 2)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    switch model.status {
                    case .working: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    case .idle: EmptyView()
                    }
                    Text(model.centerText)
                        .font(.system(size: isLongStatus ? 11 : 15, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: 140)
                .background(Capsule().fill(Theme.peach.opacity(0.95)))
                if model.hasTools && model.status == .idle {
                    HStack(spacing: 5) {
                        Circle().frame(width: 6, height: 6).opacity(model.page == .convert ? 0.9 : 0.3)
                        Circle().frame(width: 6, height: 6).opacity(model.page == .tools ? 0.9 : 0.3)
                    }
                    .foregroundStyle(.white)
                }
            }
        }
    }

    private var isLongStatus: Bool { model.centerText.count > 14 }
}

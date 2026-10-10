import SwiftUI
import AppKit
import TokenCore

/// Frosted glass panel used for every card in the popover.
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 8, y: 3)
    }
}

struct Stat: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct BarFill: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule().fill(color)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

/// Input / output / cache-write / cache-read proportions as one bar.
struct StackedTokenBar: View {
    let totals: TokenTotals

    var body: some View {
        let parts: [(Int, Color)] = [
            (totals.input, Palette.input),
            (totals.output, Palette.output),
            (totals.cacheWrite, Palette.cacheWrite),
            (totals.cacheRead, Palette.cacheRead.opacity(0.6))
        ]
        let sum = max(totals.total, 1)
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { item in
                    if item.element.0 > 0 {
                        Rectangle()
                            .fill(item.element.1)
                            .frame(width: max(2, geo.size.width * Double(item.element.0) / Double(sum)))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .clipShape(Capsule())
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption2)
    }
}

/// Battery-widget style progress ring.
struct Ring<Center: View>: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 6
    let center: Center

    init(fraction: Double, color: Color, lineWidth: CGFloat = 6, @ViewBuilder center: () -> Center) {
        self.fraction = fraction
        self.color = color
        self.lineWidth = lineWidth
        self.center = center()
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(lineWidth / 2)
    }
}

/// Credo's tachometer mark, drawn with SwiftUI shapes.
struct TachometerLogo: View {
    var size: CGFloat = 22
    var needle: Color = .primary

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 24
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var arc = Path()
            arc.addArc(center: pt(12, 16.5), radius: 8.5 * s, startAngle: .degrees(180), endAngle: .degrees(315), clockwise: false)
            ctx.stroke(arc, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 2.4 * s, lineCap: .round))
            var red = Path()
            red.addArc(center: pt(12, 16.5), radius: 8.5 * s, startAngle: .degrees(318), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(red, with: .color(Color(red: 0.70, green: 0.15, blue: 0.12)), style: StrokeStyle(lineWidth: 2.4 * s, lineCap: .round))
            var hand = Path()
            hand.move(to: pt(12, 16.5))
            hand.addLine(to: pt(16.2, 11.9))
            ctx.stroke(hand, with: .color(needle), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: 10.1 * s, y: 14.6 * s, width: 3.8 * s, height: 3.8 * s)), with: .color(needle))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Soft colour glows behind the glass cards so the frosting has something to show through.
struct GlowBackground: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle().fill(Palette.accent).frame(width: 260, height: 260)
                    .position(x: 30, y: 120)
                Circle().fill(Palette.input).frame(width: 260, height: 260)
                    .position(x: geo.size.width - 20, y: geo.size.height * 0.5)
                Circle().fill(Palette.cacheWrite).frame(width: 240, height: 240)
                    .position(x: 60, y: geo.size.height - 60)
            }
            .opacity(0.22)
            .blur(radius: 60)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

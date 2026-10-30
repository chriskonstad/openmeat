import SwiftUI

/// Brand palette, taken from the app icon (`scripts/make_app_icon.swift`): warm charcoal,
/// a heat gradient (amber → ember → red) and cream. Used for brand surfaces like the Live
/// Activity — not for probe series, which use `ProbePalette`.
enum Brand {
    static let charcoal = Color(red: 0x1b / 255, green: 0x15 / 255, blue: 0x13 / 255)
    static let charcoalWarm = Color(red: 0x2a / 255, green: 0x1d / 255, blue: 0x18 / 255)
    static let amber = Color(red: 0xed / 255, green: 0xa1 / 255, blue: 0x00 / 255)
    static let ember = Color(red: 0xeb / 255, green: 0x68 / 255, blue: 0x34 / 255)
    static let red = Color(red: 0xe3 / 255, green: 0x49 / 255, blue: 0x48 / 255)
    static let cream = Color(red: 0xff / 255, green: 0xfa / 255, blue: 0xf3 / 255)
    static let creamSecondary = cream.opacity(0.62)

    static let heat = LinearGradient(colors: [amber, ember, red], startPoint: .leading, endPoint: .trailing)
}

/// The icon's motif at small sizes: a heating curve landing on a dashed target, with a probe tip.
struct BrandMark: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let targetY = h * 0.22
            var dash = Path()
            dash.move(to: CGPoint(x: 0, y: targetY))
            dash.addLine(to: CGPoint(x: w, y: targetY))
            context.stroke(dash, with: .color(Brand.cream.opacity(0.7)), style: StrokeStyle(lineWidth: h * 0.07, lineCap: .round, dash: [h * 0.01, h * 0.16]))

            let k = 2.2, y0 = h * 0.86
            let asymptote = (targetY - y0 * exp(-k)) / (1 - exp(-k))
            var curve = Path()
            for i in 0...40 {
                let u = Double(i) / 40
                let p = CGPoint(x: w * 0.04 + w * 0.8 * u, y: asymptote - (asymptote - y0) * exp(-k * u))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            context.stroke(curve, with: .linearGradient(Gradient(colors: [Brand.amber, Brand.ember, Brand.red]),
                                                        startPoint: CGPoint(x: 0, y: h), endPoint: CGPoint(x: w, y: 0)),
                           style: StrokeStyle(lineWidth: h * 0.16, lineCap: .round, lineJoin: .round))
            let tip = CGPoint(x: w * 0.84, y: targetY)
            context.fill(Path(ellipseIn: CGRect(x: tip.x - h * 0.13, y: tip.y - h * 0.13, width: h * 0.26, height: h * 0.26)),
                         with: .color(Brand.cream))
        }
        .accessibilityHidden(true)
    }
}

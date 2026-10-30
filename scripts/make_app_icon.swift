// Renders the OpenMEAT app icon (1024×1024 PNG): a cooking curve rising toward a target line.
// Usage: swift scripts/make_app_icon.swift OpenMEAT/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import CoreGraphics

let size = 1024.0
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, alpha: alpha)
}

// Background: charcoal with a faint warm glow from the bottom (iOS applies the corner mask).
let bg = CGGradient(colorsSpace: space, colors: [color(0x2a1d18), color(0x121213)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: size / 2, y: 0), end: CGPoint(x: size / 2, y: size), options: [])
let glow = CGGradient(colorsSpace: space, colors: [color(0xeb6834, 0.28), color(0xeb6834, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size * 0.5, y: -size * 0.1), startRadius: 0,
                       endCenter: CGPoint(x: size * 0.5, y: -size * 0.1), endRadius: size * 0.95, options: [])

// Subtle grid, like the chart.
ctx.setStrokeColor(color(0xffffff, 0.06))
ctx.setLineWidth(4)
for i in 1...3 {
    let y = size * (0.2 + 0.2 * Double(i))
    ctx.move(to: CGPoint(x: size * 0.14, y: y)); ctx.addLine(to: CGPoint(x: size * 0.86, y: y))
}
ctx.strokePath()

// Target line (dashed).
let targetY = size * 0.72
ctx.setStrokeColor(color(0xf0efec, 0.75))
ctx.setLineWidth(14)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [2, 36])
ctx.move(to: CGPoint(x: size * 0.14, y: targetY)); ctx.addLine(to: CGPoint(x: size * 0.86, y: targetY))
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// Newton heating curve T(t) = Ta − (Ta − T0)·e^(−kt) from bottom-left toward the target.
let x0 = size * 0.16, x1 = size * 0.78
let y0 = size * 0.22
let k = 2.2
// Choose the asymptote so the curve lands exactly on the target line at its end.
let yAmbient = (targetY - y0 * exp(-k)) / (1 - exp(-k))
func point(_ u: Double) -> CGPoint {
    CGPoint(x: x0 + (x1 - x0) * u, y: yAmbient - (yAmbient - y0) * exp(-k * u))
}
let curve = CGMutablePath()
curve.move(to: point(0))
for i in 1...200 { curve.addLine(to: point(Double(i) / 200)) }

ctx.saveGState()
ctx.addPath(curve)
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
let heat = CGGradient(colorsSpace: space, colors: [color(0xeda100), color(0xeb6834), color(0xe34948)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(heat, start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: targetY),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Probe tip: a bright dot at the end of the curve with a soft halo.
let tip = point(1)
let halo = CGGradient(colorsSpace: space, colors: [color(0xffffff, 0.35), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: tip, startRadius: 0, endCenter: tip, endRadius: 110, options: [])
ctx.setFillColor(color(0xfffaf3))
ctx.fillEllipse(in: CGRect(x: tip.x - 44, y: tip.y - 44, width: 88, height: 88))
ctx.setFillColor(color(0xe34948))
ctx.fillEllipse(in: CGRect(x: tip.x - 20, y: tip.y - 20, width: 40, height: 40))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")

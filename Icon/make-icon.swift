// Draws the app icon: an amber guitar pick over tablature lines.
// Usage: swift Icon/make-icon.swift <output.png>   (1024×1024)
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
func gradient(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)! }

// macOS icon grid: 824pt rounded square centred in the 1024 canvas, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0.1, 0.1, 0.13))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.drawLinearGradient(gradient([color(0.20, 0.21, 0.27), color(0.08, 0.08, 0.11)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Fret numbers sitting on the strings, tab-style: (text, x, string index from the bottom).
let stringYs = (0..<6).map { 300 + CGFloat($0) * 85 }
let font = NSFont.monospacedSystemFont(ofSize: 74, weight: .bold)
let numbers: [(String, CGFloat, Int)] = [("0", 175, 5), ("3", 245, 4), ("2", 190, 1), ("5", 800, 0), ("7", 850, 4)]
let labels = numbers.map { text, x, string -> (CTLine, CGRect, Int) in
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: NSColor(srgbRed: 0.93, green: 0.94, blue: 0.97, alpha: 1)]))
    ctx.textPosition = .zero // image bounds are reported relative to the current text position
    let bounds = CTLineGetImageBounds(line, ctx)
    let y = stringYs[string]
    let frame = CGRect(x: x, y: y - bounds.height / 2, width: bounds.width, height: bounds.height)
    return (line, frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY), string)
}

// Six strings, thicker toward the bottom like real strings, broken where a number sits.
for (i, y) in stringYs.enumerated() {
    ctx.setStrokeColor(color(0.85, 0.87, 0.92, 0.55))
    ctx.setLineWidth(5 + CGFloat(5 - i) * 1.2)
    var x: CGFloat = 100
    for (_, frame, string) in labels.sorted(by: { $0.1.minX < $1.1.minX }) where string == i {
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: frame.minX - 14, y: y))
        x = frame.maxX + 14
    }
    ctx.move(to: CGPoint(x: x, y: y))
    ctx.addLine(to: CGPoint(x: 924, y: y))
    ctx.strokePath()
}
for (line, frame, _) in labels {
    ctx.textPosition = frame.origin
    CTLineDraw(line, ctx)
}

// The pick: rounded-triangle 351 shape, tip down, tilted a little.
let w: CGFloat = 470, h: CGFloat = 560
let pick = CGMutablePath()
pick.move(to: CGPoint(x: 0, y: -0.5 * h))
pick.addCurve(to: CGPoint(x: 0.5 * w, y: 0.2 * h), control1: CGPoint(x: 0.14 * w, y: -0.5 * h), control2: CGPoint(x: 0.5 * w, y: -0.12 * h))
pick.addCurve(to: CGPoint(x: 0, y: 0.5 * h), control1: CGPoint(x: 0.5 * w, y: 0.44 * h), control2: CGPoint(x: 0.3 * w, y: 0.5 * h))
pick.addCurve(to: CGPoint(x: -0.5 * w, y: 0.2 * h), control1: CGPoint(x: -0.3 * w, y: 0.5 * h), control2: CGPoint(x: -0.5 * w, y: 0.44 * h))
pick.addCurve(to: CGPoint(x: 0, y: -0.5 * h), control1: CGPoint(x: -0.5 * w, y: -0.12 * h), control2: CGPoint(x: -0.14 * w, y: -0.5 * h))
pick.closeSubpath()

ctx.translateBy(x: 520, y: 500)
ctx.rotate(by: -0.2)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 10, height: -22), blur: 36, color: color(0, 0, 0, 0.55))
ctx.addPath(pick)
ctx.setFillColor(color(0.95, 0.55, 0.15))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(pick)
ctx.clip()
ctx.drawLinearGradient(gradient([color(1.0, 0.76, 0.30), color(0.96, 0.52, 0.12), color(0.80, 0.33, 0.06)]),
                       start: CGPoint(x: -0.3 * w, y: 0.5 * h), end: CGPoint(x: 0.3 * w, y: -0.5 * h), options: [])
// Glossy highlight across the top.
ctx.drawRadialGradient(gradient([color(1, 1, 1, 0.45), color(1, 1, 1, 0)]),
                       startCenter: CGPoint(x: -0.12 * w, y: 0.3 * h), startRadius: 0,
                       endCenter: CGPoint(x: -0.12 * w, y: 0.3 * h), endRadius: 0.42 * w, options: [])
ctx.restoreGState()

ctx.addPath(pick)
ctx.setStrokeColor(color(0.55, 0.22, 0.03, 0.6))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

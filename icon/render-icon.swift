// Renders the app icon to a 1024px PNG: swift icon/render-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: rgb, colors: stops.map { color($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

// macOS icon grid: 824pt body inset 100pt, continuous-corner radius ~185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(shape); ctx.setFillColor(color(0x15171A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// Background: deep graphite gradient
ctx.drawLinearGradient(gradient([(0x2A2D33, 1, 0), (0x0E0F12, 1, 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Faint grid (console screen feel)
ctx.setStrokeColor(color(0xFFFFFF, 0.035)); ctx.setLineWidth(2)
var g: CGFloat = 100
while g < 924 { ctx.move(to: CGPoint(x: g, y: 100)); ctx.addLine(to: CGPoint(x: g, y: 924))
    ctx.move(to: CGPoint(x: 100, y: g)); ctx.addLine(to: CGPoint(x: 924, y: g)); g += 64 }
ctx.strokePath()

// Beam cone from the fixture down to the stage
let lens = CGPoint(x: 512, y: 700)
let beam = CGMutablePath()
beam.move(to: CGPoint(x: lens.x - 34, y: lens.y))
beam.addLine(to: CGPoint(x: lens.x + 34, y: lens.y))
beam.addLine(to: CGPoint(x: 512 + 260, y: 300))
beam.addLine(to: CGPoint(x: 512 - 260, y: 300))
beam.closeSubpath()
ctx.saveGState()
ctx.addPath(beam); ctx.clip()
ctx.drawLinearGradient(gradient([(0xFFC765, 0.85, 0), (0xF2A93B, 0.35, 0.55), (0xF2A93B, 0.0, 1)]),
                       start: lens, end: CGPoint(x: 512, y: 280), options: [])
ctx.restoreGState()

// Pool of light on the stage
ctx.saveGState()
ctx.translateBy(x: 512, y: 300); ctx.scaleBy(x: 1, y: 0.22)
ctx.drawRadialGradient(gradient([(0xFFD27A, 0.95, 0), (0xF2A93B, 0.55, 0.45), (0xF2A93B, 0, 1)]),
                       startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 300, options: [])
ctx.restoreGState()

// Yoke (behind the head)
ctx.setStrokeColor(color(0x4A4F58)); ctx.setLineWidth(22); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 512 - 115, y: 750)); ctx.addLine(to: CGPoint(x: 512 - 115, y: 845))
ctx.addLine(to: CGPoint(x: 512 + 115, y: 845)); ctx.addLine(to: CGPoint(x: 512 + 115, y: 750))
ctx.strokePath()
ctx.setFillColor(color(0x4A4F58))
ctx.fill(CGRect(x: 512 - 60, y: 845, width: 120, height: 30))

// Fixture head
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.5))
let head = CGPath(roundedRect: CGRect(x: 512 - 92, y: 690, width: 184, height: 120),
                  cornerWidth: 34, cornerHeight: 34, transform: nil)
ctx.addPath(head); ctx.setFillColor(color(0x3A3E46)); ctx.fillPath()
ctx.restoreGState()
// Lens glow
ctx.drawRadialGradient(gradient([(0xFFF1CF, 1, 0), (0xFFC765, 1, 0.45), (0xF2A93B, 0, 1)]),
                       startCenter: CGPoint(x: 512, y: 700), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 700), endRadius: 70, options: [])

// Fader strip along the bottom
for (i, level) in [0.55, 0.8, 0.35, 0.65].enumerated() {
    let x = 512 + (CGFloat(i) - 1.5) * 120
    ctx.setStrokeColor(color(0x000000, 0.55)); ctx.setLineWidth(14)
    ctx.move(to: CGPoint(x: x, y: 150)); ctx.addLine(to: CGPoint(x: x, y: 240)); ctx.strokePath()
    let y = 150 + 90 * CGFloat(level)
    let cap = CGPath(roundedRect: CGRect(x: x - 34, y: y - 12, width: 68, height: 24),
                     cornerWidth: 8, cornerHeight: 8, transform: nil)
    ctx.addPath(cap); ctx.setFillColor(color(i == 1 ? 0xF2A93B : 0xC9CDD3)); ctx.fillPath()
}

// Top sheen
ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.10, 0), (0xFFFFFF, 0, 1)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

// Hairline edge
ctx.addPath(shape); ctx.setStrokeColor(color(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")

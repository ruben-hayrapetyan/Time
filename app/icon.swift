// Draws the app icon (enamel safe door with a brass time-lock dial) to a 1024px PNG.
// Usage: swift icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let enamel = NSColor(srgbRed: 0.114, green: 0.227, blue: 0.196, alpha: 1)
let enamelDeep = NSColor(srgbRed: 0.071, green: 0.153, blue: 0.122, alpha: 1)
let brass = NSColor(srgbRed: 0.725, green: 0.561, blue: 0.243, alpha: 1)
let steel = NSColor(srgbRed: 0.663, green: 0.71, blue: 0.686, alpha: 1)

// Squircle-ish background with the standard macOS icon inset.
let inset: CGFloat = 100
let bgRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
NSGradient(starting: enamel, ending: enamelDeep)!.draw(in: bg, angle: -90)

let c = NSPoint(x: size / 2, y: size / 2)

// Tick ring.
for i in 0..<60 {
    let a = CGFloat(i) / 60 * 2 * .pi
    let major = i % 5 == 0
    let r1: CGFloat = 330, r2: CGFloat = major ? 292 : 310
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x + r1 * sin(a), y: c.y + r1 * cos(a)))
    p.line(to: NSPoint(x: c.x + r2 * sin(a), y: c.y + r2 * cos(a)))
    p.lineWidth = major ? 12 : 5
    (major ? steel : steel.withAlphaComponent(0.55)).setStroke()
    p.stroke()
}

// Track and brass arc (about three quarters of the time left).
let track = NSBezierPath()
track.appendArc(withCenter: c, radius: 250, startAngle: 0, endAngle: 360)
track.lineWidth = 46
enamelDeep.withAlphaComponent(0.9).setStroke()
track.stroke()
let arc = NSBezierPath()
arc.appendArc(withCenter: c, radius: 250, startAngle: 90, endAngle: 90 - 270, clockwise: true)
arc.lineWidth = 46
brass.setStroke()
arc.stroke()

// Bolt across the middle, engaged into its keeper.
ctx.saveGState()
let bolt = NSBezierPath(roundedRect: NSRect(x: c.x - 150, y: c.y - 28, width: 260, height: 56), xRadius: 10, yRadius: 10)
brass.setFill()
bolt.fill()
let keeper = NSBezierPath()
keeper.move(to: NSPoint(x: c.x + 95, y: c.y + 62))
keeper.line(to: NSPoint(x: c.x + 160, y: c.y + 62))
keeper.line(to: NSPoint(x: c.x + 160, y: c.y - 62))
keeper.line(to: NSPoint(x: c.x + 95, y: c.y - 62))
keeper.lineWidth = 22
keeper.lineJoinStyle = .round
steel.setStroke()
keeper.stroke()
ctx.restoreGState()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

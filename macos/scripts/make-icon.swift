import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Usage: make-icon.swift OUTPUT.png") }
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let rect = NSRect(x: 60, y: 60, width: 904, height: 904)
let shape = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
NSGradient(starting: NSColor(red: 1, green: 0.55, blue: 0.66, alpha: 1), ending: NSColor(red: 0.9, green: 0.19, blue: 0.38, alpha: 1))!.draw(in: shape, angle: -70)
NSColor.white.withAlphaComponent(0.38).setStroke(); shape.lineWidth = 3; shape.stroke()
let shine = NSBezierPath(roundedRect: NSRect(x: 90, y: 555, width: 844, height: 380), xRadius: 190, yRadius: 190)
NSGradient(starting: .white.withAlphaComponent(0.25), ending: .white.withAlphaComponent(0))!.draw(in: shine, angle: -90)
NSColor.white.setStroke()
let arrow = NSBezierPath(); arrow.lineWidth = 64; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 512, y: 736)); arrow.line(to: NSPoint(x: 512, y: 390))
arrow.move(to: NSPoint(x: 345, y: 548)); arrow.line(to: NSPoint(x: 512, y: 381)); arrow.line(to: NSPoint(x: 679, y: 548)); arrow.stroke()
let tray = NSBezierPath(); tray.lineWidth = 52; tray.lineCapStyle = .round; tray.lineJoinStyle = .round
tray.move(to: NSPoint(x: 307, y: 349)); tray.line(to: NSPoint(x: 307, y: 292)); tray.curve(to: NSPoint(x: 349, y: 250), controlPoint1: NSPoint(x: 307, y: 260), controlPoint2: NSPoint(x: 318, y: 250))
tray.line(to: NSPoint(x: 675, y: 250)); tray.curve(to: NSPoint(x: 717, y: 292), controlPoint1: NSPoint(x: 706, y: 250), controlPoint2: NSPoint(x: 717, y: 260)); tray.line(to: NSPoint(x: 717, y: 349)); tray.stroke()
image.unlockFocus()
let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

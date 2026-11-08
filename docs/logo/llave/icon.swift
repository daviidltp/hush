import AppKit
let size = CGFloat(1024)
let out = CommandLine.arguments[1]
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 20; shadow.shadowOffset = NSSize(width: 0, height: -8); shadow.set()
NSColor.black.setFill(); path.fill()
ctx.restoreGState()
NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.02, alpha: 1))!.draw(in: path, angle: -90)
NSColor(white: 1, alpha: 0.08).setStroke(); path.lineWidth = 3; path.stroke()
let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
let sym = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let tinted = NSImage(size: sym.size, flipped: false) { r in sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
ctx.saveGState()
ctx.translateBy(x: 497, y: 500); ctx.rotate(by: .pi / 4)
let w = sym.size.width * 1.15, h = sym.size.height * 1.15
tinted.draw(in: NSRect(x: -w/2, y: -h/2, width: w, height: h))
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.converting(to: .sRGB, renderingIntent: .default)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))

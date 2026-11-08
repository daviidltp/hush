import AppKit
let px = CGFloat(Double(CommandLine.arguments[2])!)
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let sym = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 200, weight: .semibold))!
let tinted = NSImage(size: sym.size, flipped: false) { r in sym.draw(in: r); NSColor.black.set(); r.fill(using: .sourceAtop); return true }
ctx.translateBy(x: px/2 - px*0.03, y: px/2 + px*0.02); ctx.rotate(by: .pi / 4)
let s = px * 1.3 / sym.size.width
let w = sym.size.width * s, h = sym.size.height * s
tinted.draw(in: NSRect(x: -w/2, y: -h/2, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

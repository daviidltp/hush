// Dibuja el icono de la app: cuadrado negro redondeado con un candado blanco.
import AppKit

let out = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for size in sizes {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1).setFill()
    path.fill()
    NSColor(white: 1, alpha: 0.14).setStroke()
    path.lineWidth = max(1, s / 256)
    path.stroke()
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.36, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = symbol.size
        symbol.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    for (name, scale) in [("icon_\(size)x\(size).png", 1), ("icon_\(size / 2)x\(size / 2)@2x.png", 2)] where size / scale >= 16 && (scale == 1 ? size <= 512 : true) {
        try! png.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}

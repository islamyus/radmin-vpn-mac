import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                     ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                     ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size)
    let box = NSRect(x: scale * 0.06, y: scale * 0.06, width: scale * 0.88, height: scale * 0.88)
    NSColor(red: 0.055, green: 0.085, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: box, xRadius: scale * 0.2, yRadius: scale * 0.2).fill()
    let config = NSImage.SymbolConfiguration(pointSize: scale * 0.48, weight: .medium)
        .applying(.init(paletteColors: [NSColor(red: 0.39, green: 0.89, blue: 0.71, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let rect = NSRect(x: (scale - symbol.size.width) / 2, y: (scale - symbol.size.height) / 2,
                          width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: rect)
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}

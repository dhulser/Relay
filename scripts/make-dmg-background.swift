import AppKit
import Foundation

// Renders the disk image's Finder background: a dark plate in the app's own
// palette, an arrow from Relay to Applications, and one line of instruction.
// Drawn at 1x and 2x so Finder shows it sharp on Retina displays.
//
// Usage: swift make-dmg-background.swift <outDir>
// Finder places icons by their centres in points from the window's top-left,
// so the arrow and captions here are laid out on that same grid: the app icon
// at (165, 185) and Applications at (495, 185), 128 pt icons, 660×400 window.

let width: CGFloat = 660
let height: CGFloat = 400
let appCenter = CGPoint(x: 165, y: 185)
let folderCenter = CGPoint(x: 495, y: 185)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // rep.size in points against a 2x pixel grid makes the context scale
    // itself; drawing stays in points.
    let ctx = NSGraphicsContext.current!.cgContext
    // Work in Finder's coordinates: origin top-left, y downwards.
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)

    // Charcoal plate, slightly lighter at the top, matching the caption plate.
    let base = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.175, green: 0.180, blue: 0.215, alpha: 1),
            CGColor(red: 0.115, green: 0.118, blue: 0.145, alpha: 1),
        ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: height), options: [])

    // A soft indigo glow behind the app icon, so the eye lands there first.
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.36, green: 0.39, blue: 0.83, alpha: 0.32),
            CGColor(red: 0.36, green: 0.39, blue: 0.83, alpha: 0.0),
        ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: appCenter, startRadius: 0,
                           endCenter: appCenter, endRadius: 190, options: [])

    // Arrow: a line from the app to the folder with a chevron head.
    let indigo = CGColor(red: 0.55, green: 0.58, blue: 0.93, alpha: 0.95)
    ctx.setStrokeColor(indigo)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let y = appCenter.y
    let startX = appCenter.x + 92
    let endX = folderCenter.x - 96
    ctx.move(to: CGPoint(x: startX, y: y))
    ctx.addLine(to: CGPoint(x: endX, y: y))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: endX - 14, y: y - 12))
    ctx.addLine(to: CGPoint(x: endX, y: y))
    ctx.addLine(to: CGPoint(x: endX - 14, y: y + 12))
    ctx.strokePath()

    // Text is drawn unflipped, so undo the flip for it.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)

    func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centerY: CGFloat, x: CGFloat? = nil) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
            .paragraphStyle: style,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()
        let origin = CGPoint(x: (x ?? width / 2) - bounds.width / 2, y: height - centerY - bounds.height / 2)
        string.draw(at: origin)
    }

    draw("Drag Relay into Applications", size: 15, weight: .medium, alpha: 0.82, centerY: 318)
    draw("Then open it from the menu bar", size: 12.5, weight: .regular, alpha: 0.45, centerY: 342)

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let rep = render(scale: scale)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("rendered \(url.path)")
}

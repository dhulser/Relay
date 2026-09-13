import AppKit
import Foundation

// Renders Relay's app icon: the same waveform as the menu bar, on the rounded
// square macOS expects. Run via scripts/make-icon.sh.

let canvas: CGFloat = 1024
// Apple's icon grid: the rounded square occupies 824 of 1024, radius 185.
let plateInset: CGFloat = 100
let plateSize = canvas - plateInset * 2
let cornerRadius: CGFloat = 185

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let plate = CGRect(x: plateInset, y: plateInset, width: plateSize, height: plateSize)
    let platePath = CGPath(roundedRect: plate, cornerWidth: cornerRadius,
                           cornerHeight: cornerRadius, transform: nil)

    // Soft indigo, lighter at the top — the accent from RelayTheme.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.51, green: 0.54, blue: 0.93, alpha: 1),
            CGColor(red: 0.36, green: 0.38, blue: 0.78, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY),
                           options: [])
    ctx.restoreGState()

    // Waveform: rounded bars rising and falling, centred on the plate.
    let heights: [CGFloat] = [0.30, 0.56, 0.84, 1.0, 0.72, 0.44, 0.24]
    let barWidth: CGFloat = 54
    let gap: CGFloat = 34
    let maxHeight: CGFloat = 420
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = canvas / 2 - totalWidth / 2

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    for h in heights {
        let barHeight = maxHeight * h
        let rect = CGRect(x: x, y: canvas / 2 - barHeight / 2, width: barWidth, height: barHeight)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2,
                           cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let rep = render()
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let master = URL(fileURLWithPath: outDir).appendingPathComponent("icon-1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)
print("rendered \(master.path)")

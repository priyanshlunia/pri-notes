// Draws the Pri Notes app icon: a dark-mode Apple-Notes-style notepad (yellow header, perforation dots,
// near-black page) with a large light-grey italic Palatino "P" in the middle, and writes an .icns file.
//
//   swiftc -O -o /tmp/make_icon scripts/make_icon.swift && /tmp/make_icon Resources/AppIcon.icns
//   /tmp/make_icon preview.png --png        # just the 1024 px PNG, for looking at
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make_icon <out.icns | out.png --png>"); exit(2) }

/// Render the icon at `pixels` × `pixels` into a bitmap. All geometry is defined on a 1024 grid.
func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824 pt artwork centred on a 1024 canvas, ~185 pt corner radius.
    let shape = NSRect(x: 100, y: 100, width: 824, height: 824)
    let outline = NSBezierPath(roundedRect: shape, xRadius: 185, yRadius: 185)

    // Soft drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    outline.addClip()

    // Page: dark grey fading to near-black (colours sampled from the dark-mode Notes icon).
    NSGradient(starting: NSColor(srgbRed: 0.135, green: 0.135, blue: 0.130, alpha: 1),
               ending: NSColor(white: 0.071, alpha: 1))!
        .draw(in: shape, angle: -90)

    // Yellow header band (top ~24 % of the tile).
    let headerHeight: CGFloat = 200
    let header = NSRect(x: shape.minX, y: shape.maxY - headerHeight, width: shape.width, height: headerHeight)
    NSGradient(starting: NSColor(srgbRed: 0.949, green: 0.809, blue: 0.190, alpha: 1),
               ending: NSColor(srgbRed: 0.950, green: 0.786, blue: 0.000, alpha: 1))!
        .draw(in: header, angle: -90)

    // Perforation: a row of small grey dots just under the header.
    NSColor(srgbRed: 0.545, green: 0.532, blue: 0.487, alpha: 1).setFill()
    let dotY = header.minY - 34
    let dotCount = 17
    let dotSpacing = (shape.width - 90) / CGFloat(dotCount - 1)
    for i in 0..<dotCount {
        let x = shape.minX + 45 + CGFloat(i) * dotSpacing
        NSBezierPath(ovalIn: NSRect(x: x - 7, y: dotY - 7, width: 14, height: 14)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // The italic P, centred in the page area below the perforation.
    let font = NSFont(name: "Palatino-BoldItalic", size: 560) ?? NSFont.systemFont(ofSize: 560, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(white: 0.90, alpha: 1),
    ]
    // Centre the glyph's ink (not its advance box) so the slant doesn't push it off-centre.
    // CTLineGetImageBounds gives the ink rectangle relative to the baseline origin.
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "P", attributes: attrs))
    let ink = CTLineGetImageBounds(line, ctx)
    let page = NSRect(x: shape.minX, y: shape.minY, width: shape.width, height: dotY - 20 - shape.minY)
    ctx.textPosition = CGPoint(x: page.midX - ink.midX, y: page.midY - ink.midY)
    CTLineDraw(line, ctx)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: args[1])
if args.contains("--png") {
    try! renderIcon(pixels: 1024).representation(using: .png, properties: [:])!.write(to: out)
    exit(0)
}

// Build an .iconset with every size iconutil expects, then convert.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("PriNotes.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = renderIcon(pixels: base * scale).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
exit(task.terminationStatus)

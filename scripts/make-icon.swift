// Draws Lex's app icon in code, so it's crisp at every size and easy to change.
//
//   swift scripts/make-icon.swift sheet out.png          # the concepts side by side
//   swift scripts/make-icon.swift png <concept> out.png  # one concept at 1024 px
//   swift scripts/make-icon.swift icns <concept> out.icns
//
// Concepts: ink (an "L" with an orange period), correction (a word, a squiggle and the
// cursor), voice (a pen nib with sound waves).
import AppKit

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)  // macOS icon grid: 824 pt tile, 100 pt margin

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let orange = color(0xFF9F0A)

func squircle() -> CGPath {
    NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186).cgPath
}

/// The tile: drop shadow, vertical gradient, a soft highlight at the top.
func drawTile(_ ctx: CGContext, top: CGColor, bottom: CGColor, border: CGColor? = nil) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.32))
    ctx.addPath(squircle())
    ctx.setFillColor(bottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle())
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
    ctx.restoreGState()

    if let border {
        ctx.addPath(squircle())
        ctx.setStrokeColor(border)
        ctx.setLineWidth(3)
        ctx.strokePath()
    }
}

func drawInk(_ ctx: CGContext) {
    drawTile(ctx, top: color(0x6C5CFF), bottom: color(0x2B1E8F))
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(124)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 336, y: 708))
    ctx.addLine(to: CGPoint(x: 336, y: 318))
    ctx.addLine(to: CGPoint(x: 574, y: 318))
    ctx.strokePath()
    ctx.setFillColor(orange)
    ctx.fillEllipse(in: CGRect(x: 640, y: 256, width: 124, height: 124))
}

func drawCorrection(_ ctx: CGContext) {
    drawTile(ctx, top: color(0xFFFFFF), bottom: color(0xEAE5DC), border: color(0x000000, 0.08))
    // A word…
    ctx.setFillColor(color(0x2C2C2E))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 236, y: 486, width: 400, height: 96), cornerWidth: 48, cornerHeight: 48, transform: nil))
    ctx.fillPath()
    // …underlined as a mistake…
    ctx.setStrokeColor(orange)
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let wave = CGMutablePath()
    var x: CGFloat = 248
    wave.move(to: CGPoint(x: x, y: 404))
    while x < 624 {
        x += 4
        wave.addLine(to: CGPoint(x: x, y: 404 + 22 * sin((x - 248) / 64 * .pi)))
    }
    ctx.addPath(wave)
    ctx.strokePath()
    // …and the text cursor right after it.
    ctx.setFillColor(color(0x2F6BFF))
    ctx.fill(CGRect(x: 704, y: 300, width: 30, height: 360))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 664, y: 640, width: 110, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 664, y: 290, width: 110, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.fillPath()
}

func drawVoice(_ ctx: CGContext) {
    let top = color(0x14B8A6), bottom = color(0x1D4ED8)
    drawTile(ctx, top: top, bottom: bottom)
    // A fountain-pen nib, tip down-left.
    ctx.saveGState()
    ctx.translateBy(x: 452, y: 476)
    ctx.rotate(by: .pi / 4.5)
    let nib = CGMutablePath()
    nib.move(to: CGPoint(x: 0, y: -250))
    nib.addCurve(to: CGPoint(x: -140, y: 60), control1: CGPoint(x: -40, y: -170), control2: CGPoint(x: -140, y: -60))
    nib.addLine(to: CGPoint(x: -140, y: 200))
    nib.addLine(to: CGPoint(x: 140, y: 200))
    nib.addLine(to: CGPoint(x: 140, y: 60))
    nib.addCurve(to: CGPoint(x: 0, y: -250), control1: CGPoint(x: 140, y: -60), control2: CGPoint(x: 40, y: -170))
    nib.closeSubpath()
    ctx.addPath(nib)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    // The slit and the breather hole, in the tile's colour.
    ctx.setStrokeColor(color(0x1A7FC4))
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 0, y: -236))
    ctx.addLine(to: CGPoint(x: 0, y: 10))
    ctx.strokePath()
    ctx.setFillColor(color(0x1A7FC4))
    ctx.fillEllipse(in: CGRect(x: -34, y: 0, width: 68, height: 68))
    ctx.restoreGState()
    // Sound waves from the top of the nib.
    ctx.setLineCap(.round)
    ctx.setLineWidth(38)
    for (i, radius) in [CGFloat(96), 168, 240].enumerated() {
        ctx.setStrokeColor(color(0xFFFFFF, 1 - CGFloat(i) * 0.28))
        ctx.addArc(center: CGPoint(x: 560, y: 590), radius: radius, startAngle: -.pi / 9, endAngle: .pi / 2.3, clockwise: false)
        ctx.strokePath()
    }
}

let concepts: [(name: String, label: String, draw: (CGContext) -> Void)] = [
    ("ink", "A · Ink", drawInk),
    ("correction", "B · Correction", drawCorrection),
    ("voice", "C · Voice", drawVoice),
]

func render(_ draw: (CGContext) -> Void, size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(ctx)
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func concept(_ name: String) -> (CGContext) -> Void {
    guard let c = concepts.first(where: { $0.name == name }) else {
        FileHandle.standardError.write("unknown concept \(name); use \(concepts.map(\.name).joined(separator: ", "))\n".data(using: .utf8)!)
        exit(1)
    }
    return c.draw
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "sheet" where args.count == 3:
    // The concepts large, then at Dock, Finder and list sizes on light and dark backgrounds.
    let w = 1560, h = 820
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setFillColor(color(0xF5F5F7))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for (i, c) in concepts.enumerated() {
        let x = CGFloat(40 + i * 520)
        ctx.draw(render(c.draw, size: 880).cgImage!, in: CGRect(x: x, y: 330, width: 440, height: 440))
        ctx.setFillColor(color(0x1C1C1E))
        ctx.addPath(CGPath(roundedRect: CGRect(x: x + 250, y: 90, width: 190, height: 200), cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.fillPath()
        for (j, s) in [128, 64, 32].enumerated() {
            let cg = render(c.draw, size: s * 2).cgImage!
            ctx.draw(cg, in: CGRect(x: x + CGFloat(j == 0 ? 60 : 0) + (j == 0 ? 0 : 270 + CGFloat(j - 1) * 80), y: j == 0 ? 120 : 160, width: CGFloat(s), height: CGFloat(s)))
        }
        (c.label as NSString).draw(at: CGPoint(x: x + 60, y: 40), withAttributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black,
        ])
    }
    NSGraphicsContext.current = nil
    write(rep, to: args[2])
case "png" where args.count == 4:
    write(render(concept(args[2]), size: 1024), to: args[3])
case "icns" where args.count == 4:
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Lex-\(UUID().uuidString).iconset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        write(render(concept(args[2]), size: size), to: dir.appendingPathComponent("icon_\(size)x\(size).png").path)
        write(render(concept(args[2]), size: size * 2), to: dir.appendingPathComponent("icon_\(size)x\(size)@2x.png").path)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", dir.path, "-o", args[3]]
    try! p.run()
    p.waitUntilExit()
    try? FileManager.default.removeItem(at: dir)
    exit(p.terminationStatus)
default:
    print("usage: make-icon.swift sheet out.png | png <concept> out.png | icns <concept> out.icns")
    exit(1)
}

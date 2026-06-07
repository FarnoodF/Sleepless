// Sleepless app icon generator (native, AppKit-rendered).
//
// Renders a simple agent/robot having coffee on a continuous-curvature ("squircle")
// Liquid-Glass plate carrying the brand's indigo -> violet -> fuchsia gradient.
// The Dock/Finder icon can carry the full robot-with-coffee identity; the menu bar
// still uses a simplified monochrome template glyph so it stays legible at 16 px.
// Each iconset size is rendered directly from vector shapes (no raster downscaling).
//
// Build + run:  swiftc -O -framework AppKit make-icon.swift -o /tmp/mkicon && /tmp/mkicon [outDir]
// Then:         iconutil -c icns Sleepless.iconset -o Sleepless.icns
//
// Output directory = first CLI argument, else the current working directory.
// (No hardcoded paths, so it works from any clone — build.sh passes a temp dir.)
import AppKit

// ---- Brand palette (2026 redesign): indigo -> violet -> fuchsia diagonal gradient,
// lighter at the top-left so it harmonises with the system's icon lighting. The
// white cup reads cleanly on top; the violet mid-stop matches the popover accent.
let plateTop = NSColor(srgbRed: 124/255.0, green: 140/255.0, blue: 255/255.0, alpha: 1) // #7C8CFF light indigo
let plateMid = NSColor(srgbRed: 139/255.0, green:  92/255.0, blue: 246/255.0, alpha: 1) // #8B5CF6 violet
let plateBot = NSColor(srgbRed: 192/255.0, green:  38/255.0, blue: 211/255.0, alpha: 1) // #C026D3 fuchsia/magenta

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
let iconset = "\(outDir)/Sleepless.iconset"

// Continuous-curvature squircle path (superellipse, exponent ~5 ~= Apple plate).
func squirclePath(rect: CGRect, n: CGFloat = 5.0) -> CGPath {
    let p = CGMutablePath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2.0 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2.0 / n), st)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func renderIcon(_ S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Apple plate grid: ~824 plate on 1024 canvas (≈100px gutter), scaled to S.
    let gutter = S * (100.0 / 1024.0)
    let plate = CGRect(x: gutter, y: gutter, width: S - 2 * gutter, height: S - 2 * gutter)
    let path = squirclePath(rect: plate)

    // Plate fill: indigo -> violet -> fuchsia diagonal gradient (lighter top-left,
    // deeper bottom-right) so it agrees with the system icon lighting.
    cg.saveGState()
    cg.addPath(path); cg.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs,
        colors: [plateTop.cgColor, plateMid.cgColor, plateBot.cgColor] as CFArray,
        locations: [0, 0.5, 1])!
    cg.drawLinearGradient(grad,
        start: CGPoint(x: plate.minX, y: plate.maxY),   // top-left (light indigo)
        end:   CGPoint(x: plate.maxX, y: plate.minY),   // bottom-right (deep fuchsia)
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Soft top-left glass sheen (specular highlight, radial white), clipped to plate.
    let sheen = CGGradient(colorsSpace: cs,
        colors: [NSColor(white: 1, alpha: 0.32).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
        locations: [0, 1])!
    let gc = CGPoint(x: plate.minX + plate.width * 0.32, y: plate.maxY - plate.height * 0.26)
    cg.drawRadialGradient(sheen, startCenter: gc, startRadius: 0,
                          endCenter: gc, endRadius: plate.width * 0.66, options: [])

    // Faint white "lit from within" glow behind the cup for depth.
    let glow = CGGradient(colorsSpace: cs,
        colors: [NSColor(white: 1, alpha: 0.12).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
        locations: [0, 1])!
    let glowC = CGPoint(x: plate.midX, y: plate.midY)
    cg.drawRadialGradient(glow, startCenter: glowC, startRadius: 0,
                          endCenter: glowC, endRadius: plate.width * 0.44, options: [])

    cg.restoreGState()

    // Robot head: broad, friendly, and legible at Dock sizes.
    let head = CGRect(x: plate.midX - plate.width * 0.27,
                      y: plate.midY - plate.height * 0.10,
                      width: plate.width * 0.48,
                      height: plate.height * 0.34)
    let corner = plate.width * 0.075
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -S * 0.008), blur: S * 0.018,
                 color: NSColor(srgbRed: 0.24, green: 0.08, blue: 0.42, alpha: 0.50).cgColor)
    cg.addPath(CGPath(roundedRect: head, cornerWidth: corner, cornerHeight: corner, transform: nil))
    NSColor.white.setFill()
    cg.fillPath()
    cg.restoreGState()

    // Antenna + ears.
    NSColor.white.withAlphaComponent(0.94).setStroke()
    cg.setLineWidth(max(S * 0.012, 1.4))
    cg.setLineCap(.round)
    cg.move(to: CGPoint(x: head.midX, y: head.maxY))
    cg.addLine(to: CGPoint(x: head.midX, y: head.maxY + plate.height * 0.09))
    cg.strokePath()
    cg.addEllipse(in: CGRect(x: head.midX - plate.width * 0.025,
                             y: head.maxY + plate.height * 0.085,
                             width: plate.width * 0.05,
                             height: plate.width * 0.05))
    NSColor.white.setFill()
    cg.fillPath()
    for dx in [-0.295, 0.215] as [CGFloat] {
        let ear = CGRect(x: plate.midX + plate.width * dx,
                         y: head.midY - plate.height * 0.055,
                         width: plate.width * 0.06,
                         height: plate.height * 0.11)
        cg.addPath(CGPath(roundedRect: ear, cornerWidth: plate.width * 0.025, cornerHeight: plate.width * 0.025, transform: nil))
        cg.fillPath()
    }

    // Face details are punched in with the plate's dark violet tone.
    let face = NSColor(srgbRed: 62/255.0, green: 35/255.0, blue: 120/255.0, alpha: 1)
    face.setFill()
    for dx in [-0.10, 0.10] as [CGFloat] {
        cg.addEllipse(in: CGRect(x: head.midX + plate.width * dx - plate.width * 0.028,
                                 y: head.midY + plate.height * 0.035,
                                 width: plate.width * 0.056,
                                 height: plate.width * 0.056))
        cg.fillPath()
    }
    cg.setStrokeColor(face.cgColor)
    cg.setLineWidth(max(S * 0.010, 1.2))
    cg.move(to: CGPoint(x: head.midX - plate.width * 0.075, y: head.midY - plate.height * 0.055))
    cg.addQuadCurve(to: CGPoint(x: head.midX + plate.width * 0.075, y: head.midY - plate.height * 0.055),
                    control: CGPoint(x: head.midX, y: head.midY - plate.height * 0.095))
    cg.strokePath()

    // Coffee cup, intentionally simple: white mug with a violet handle and soft steam.
    let mug = CGRect(x: head.maxX - plate.width * 0.05,
                     y: head.minY - plate.height * 0.02,
                     width: plate.width * 0.20,
                     height: plate.height * 0.13)
    NSColor.white.setFill()
    cg.addPath(CGPath(roundedRect: mug, cornerWidth: plate.width * 0.025, cornerHeight: plate.width * 0.025, transform: nil))
    cg.fillPath()
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(max(S * 0.015, 1.6))
    let handle = CGRect(x: mug.maxX - plate.width * 0.015,
                        y: mug.midY - plate.height * 0.035,
                        width: plate.width * 0.075,
                        height: plate.height * 0.07)
    cg.strokeEllipse(in: handle)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
    cg.setLineWidth(max(S * 0.008, 1.0))
    for dx in [0.0, 0.055] as [CGFloat] {
        cg.move(to: CGPoint(x: mug.minX + plate.width * (0.055 + dx), y: mug.maxY + plate.height * 0.015))
        cg.addCurve(to: CGPoint(x: mug.minX + plate.width * (0.075 + dx), y: mug.maxY + plate.height * 0.105),
                    control1: CGPoint(x: mug.minX + plate.width * (0.02 + dx), y: mug.maxY + plate.height * 0.04),
                    control2: CGPoint(x: mug.minX + plate.width * (0.12 + dx), y: mug.maxY + plate.height * 0.07))
        cg.strokePath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
try? fm.removeItem(atPath: iconset)
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// 10 standard iconset entries (size, @2x?) -> render each directly from vector.
let specs: [(String, CGFloat)] = [
    ("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
    ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
    ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024),
]
for (name, px) in specs { write(renderIcon(px), "\(iconset)/\(name).png") }
write(renderIcon(1024), "\(outDir)/Sleepless-1024.png")
print("rendered iconset (\(specs.count) sizes) + Sleepless-1024.png")
